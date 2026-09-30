#!/usr/bin/env bash
# native/start.sh — 직접 설치 방식 기동. 여러 번 실행해도 안전하다 (떠 있는 것은 건너뜀).
#   파드를 다시 만들어 프로그램이 사라졌으면 먼저 다시 설치한다.
source "$(dirname "$0")/lib.sh"
load_env; native_env

say "0/6 라이선스 확인"
check_license

say "1/6 프로그램 확인"
if installed; then note "PostgreSQL·pgvector·Kong·decK 모두 있음"
else note "빠진 프로그램이 있어 설치합니다"; "$ROOT/native/install.sh"; fi

say "2/6 PostgreSQL"
PGD=$(pg_datadir)
if pg_ready; then note "이미 실행 중 ($PGD)"
else
  if [ ! -f "$PGD/PG_VERSION" ]; then
    # 슈퍼유저는 이 파드의 사용자만 쓰는 소켓으로만 접속(trust), TCP 접속은 비밀번호(scram)
    if ! "$PG_BIN/initdb" -D "$PGD" -U postgres -E UTF8 --locale=C.UTF-8 \
         --auth-local=trust --auth-host=scram-sha-256 \
         --pwfile=<(printf '%s\n' "$KONG_PG_PASSWORD") > "$LOGS/initdb.log" 2>&1; then
      tail -5 "$LOGS/initdb.log" | sed 's/^/  | /'
      if [ "$PGD" = "$DATA_DIR/pgdata" ]; then
        note "⚠ $DATA_DIR 에 DB 를 만들 수 없어 로컬 디스크로 대체합니다"
        rm -rf "$PGD"; PGD="$RUN_DIR/pgdata"
        "$PG_BIN/initdb" -D "$PGD" -U postgres -E UTF8 --locale=C.UTF-8 \
          --auth-local=trust --auth-host=scram-sha-256 \
          --pwfile=<(printf '%s\n' "$KONG_PG_PASSWORD") > "$LOGS/initdb.log" 2>&1 \
          || die "PostgreSQL 초기화 실패 ($LOGS/initdb.log)"
      else die "PostgreSQL 초기화 실패 ($LOGS/initdb.log)"; fi
    fi
    cat >> "$PGD/postgresql.conf" <<CONF

# ── kong-poc (native/start.sh) ──
listen_addresses = '127.0.0.1'
port = $PG_PORT
unix_socket_directories = '$RUN_DIR'
max_connections = 200
CONF
    note "초기화 완료 ($PGD)"
  fi
  # 파드를 다시 만들면 예전 pid 가 남아 있을 수 있다 — 그 번호를 다른 프로세스가 쓰고 있으면 기동이 막힌다
  if [ -f "$PGD/postmaster.pid" ]; then
    old=$(head -1 "$PGD/postmaster.pid")
    [ "$(cat "/proc/$old/comm" 2>/dev/null)" = postgres ] || rm -f "$PGD/postmaster.pid"
  fi
  "$PG_BIN/pg_ctl" -D "$PGD" -l "$LOGS/postgres.log" -w -t 60 start >/dev/null \
    || { tail -5 "$LOGS/postgres.log" | sed 's/^/  | /'; die "PostgreSQL 기동 실패 ($LOGS/postgres.log)"; }
  note "시작됨 ($PGD)"
fi
[ "$PGD" = "$RUN_DIR/pgdata" ] && note "⚠ DB 가 로컬 디스크에 있어 파드를 다시 만들면 사라집니다"
psql_su -d postgres -v pw="$KONG_PG_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE kong LOGIN PASSWORD %L', :'pw') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kong') \gexec
SELECT format('ALTER ROLE kong PASSWORD %L', :'pw') \gexec
SELECT 'CREATE DATABASE kong OWNER kong' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'kong') \gexec
SELECT 'CREATE DATABASE "kong-pgvector" OWNER kong' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'kong-pgvector') \gexec
SQL
psql_su -d kong-pgvector -c 'CREATE EXTENSION IF NOT EXISTS vector'
note "DB 준비됨 (kong · kong-pgvector + vector)"

say "3/6 Kong DB 마이그레이션"
kong_native_env
out=$(kong migrations bootstrap 2>&1) || true
if grep -qi "already bootstrapped" <<<"$out"; then
  kong migrations up >/dev/null 2>&1 || true; kong migrations finish >/dev/null 2>&1 || true
  note "기존 DB — 필요한 마이그레이션만 적용"
elif grep -qiE "complete|executed" <<<"$out"; then
  note "최초 초기화 완료 (관리자 계정 kong_admin 생성)"
else
  echo "$out" | tail -5; die "마이그레이션 실패"
fi

say "4/6 한국어 PII 가드"
if [ ! -f "$PKGS_DIR/pii-guard/app.py" ]; then note "소스가 없어 건너뜀 ($PKGS_DIR/pii-guard/app.py)"
elif pii_running; then note "이미 실행 중 (포트 $PII_PORT)"
else
  PORT=$PII_PORT LLM_ENABLED="${PII_LLM_ENABLED:-false}" LLM_URL="${PII_LLM_URL:-}" LLM_MODEL="${PII_LLM_MODEL:-}" \
    setsid nohup python3 "$PKGS_DIR/pii-guard/app.py" >> "$LOGS/pii-guard.log" 2>&1 < /dev/null &
  echo $! > "$RUN_DIR/pii.pid"
  for _ in $(seq 1 20); do curl -s -m 2 "http://127.0.0.1:$PII_PORT/healthz" >/dev/null && break; sleep 0.5; done
  pii_running && curl -s -m 2 "http://127.0.0.1:$PII_PORT/healthz" >/dev/null \
    || { tail -5 "$LOGS/pii-guard.log" | sed 's/^/  | /'; die "PII 가드 기동 실패 ($LOGS/pii-guard.log)"; }
  note "시작됨 (포트 $PII_PORT, 문맥 판정 LLM: ${PII_LLM_ENABLED:-false})"
fi

say "5/6 Kong Gateway"
if kong_up; then note "이미 실행 중"
else
  kong start -p "$KONG_PREFIX" > "$RUN_DIR/kong-start.log" 2>&1 \
    || { tail -8 "$RUN_DIR/kong-start.log" | sed 's/^/  | /'; die "Kong 기동 실패 ($LOGS/kong-error.log)"; }
  for _ in $(seq 1 30); do kong_up && break; sleep 1; done
  kong_up || die "Kong 이 준비되지 않습니다 ($LOGS/kong-error.log)"
  note "시작됨"
fi

say "6/6 설정"
dump=$(deck gateway dump -o - --select-tag kong-poc --kong-addr "http://127.0.0.1:$ADMIN_PORT" \
          --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD" 2>/dev/null) || true
if grep -q 'name: llm-chat' <<<"$dump"; then
  note "이미 적용돼 있음 (바꾼 뒤에는 native/apply-config.sh)"
else
  "$ROOT/native/apply-config.sh"
fi

cat <<MSG

──────────────────────────────────────────────
 Kong AI Gateway PoC 기동 완료 (직접 설치)
──────────────────────────────────────────────
 프록시        http://127.0.0.1:$PROXY_PORT   (파드 안) · http://<파드 IP>:$PROXY_PORT
 Kong Manager  $MANAGER_URL/
               kong_admin / .env 의 KONG_ADMIN_PASSWORD
 데이터·로그   $DATA_DIR
 전체 점검     native/verify.sh
──────────────────────────────────────────────
MSG
