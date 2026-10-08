#!/usr/bin/env bash
# start.sh — 직접 설치 방식 기동. 여러 번 실행해도 안전하다 (떠 있는 것은 건너뜀).
#   파드를 다시 만들어 프로그램이 사라졌으면 먼저 다시 설치한다.
#   설치·기동까지만 한다. 요구사항별 설정은 따로 bash apply-config.sh 로 적용한다.
source "$(dirname "$0")/lib.sh"
load_env; native_env

say "0/6 라이선스 확인"
license_state
case "$LIC_STATE" in
  valid) if [ "$LIC_DAYS" -le 30 ]; then note "⚠ 라이선스 만료 임박: $LIC_MSG"; else note "라이선스 $LIC_MSG"; fi ;;
  grace) note "⚠ 라이선스 $LIC_MSG" ;;
  *)     note "⚠ $LIC_MSG — Kong 이 읽기 전용으로 뜹니다 (설치·접속 시험은 가능, 설정 적용은 라이선스가 필요)" ;;
esac

say "1/6 프로그램 확인"
if installed; then note "PostgreSQL·pgvector·Kong·decK 모두 있음"
else note "빠진 프로그램이 있어 설치합니다"; "$ROOT/install.sh"; fi

say "2/6 PostgreSQL"
PGD=$(pg_datadir)
# DB 폴더는 그 주인만 쓸 수 있다 — 빌드한 새 환경이 다른 사용자로 돌면 DB 가 뜨지 않는다
if [ -f "$PGD/PG_VERSION" ] && [ "$(stat -c %u "$PGD")" != "$(id -u)" ]; then
  die "DB 폴더($PGD)의 주인은 uid $(stat -c %u "$PGD") 인데 이 환경은 uid $(id -u) ($(id -un)) 입니다.
  DB 를 만든 사용자와 같은 사용자로 실행해야 합니다."
fi
lock_take "$PGD"     # 다른 환경이 이 유지 폴더를 쓰는 중이면 여기서 멈춘다 (lib.sh)
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

# ── kong-poc (start.sh) ──
listen_addresses = '127.0.0.1'
port = $PG_PORT
unix_socket_directories = '$RUN_DIR'
max_connections = 200
CONF
    note "초기화 완료 ($PGD)"
  fi
  # 파드를 다시 만들면 예전 pid 가 남아 있을 수 있다 — 그 번호를 다른 프로세스가 쓰고 있으면 기동이 막힌다
  # (다른 환경이 쓰는 중이 아니라는 건 바로 위 lock_take 가 확인했다)
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
# 벡터 DB(kong-pgvector)는 파드 안(127.0.0.1)에서만, 비밀번호 없이 받는다 — Kong DB 는 그대로 비밀번호가 필요하다.
# Kong 3.16 의 의미 기반 가드(ai-semantic-prompt-guard)가 vault 로 넣은 DB 비밀번호를 읽지 못하기 때문
HBA="host kong-pgvector kong 127.0.0.1/32 trust"
if ! grep -qxF "$HBA" "$PGD/pg_hba.conf"; then
  sed -i "1i $HBA" "$PGD/pg_hba.conf"       # pg_hba 는 위에서부터 처음 맞는 줄을 쓴다
  "$PG_BIN/pg_ctl" -D "$PGD" reload >/dev/null
fi
note "DB 준비됨 (kong · kong-pgvector + vector)"

say "3/6 Kong DB 마이그레이션"
kong_env
out=$(kong migrations bootstrap 2>&1) || true
if grep -qi "already bootstrapped" <<<"$out"; then
  # Kong 버전이 바뀌었으면(설치 파일 교체) DB 구조를 새 버전에 맞춘다 — 바뀐 게 없으면 아무것도 하지 않는다
  up=$(kong migrations up 2>&1) || { echo "$up" | tail -5 | sed 's/^/  | /'; die "마이그레이션 실패"; }
  kong migrations finish >/dev/null 2>&1 || true
  if grep -qi "executed" <<<"$up"; then note "Kong 버전이 바뀌어 DB 를 새 버전에 맞췄습니다"
  else note "기존 DB — 바뀐 것 없음"; fi
elif grep -qiE "complete|executed" <<<"$out"; then
  note "최초 초기화 완료 (관리자 계정 kong_admin 생성)"
else
  echo "$out" | tail -5; die "마이그레이션 실패"
fi

say "4/6 보조 서비스 — 한국어 PII 가드 · 시험용 모의 서버"
start_py() {  # 이름 pid파일 포트 앱 [환경변수...]
  local name=$1 pidf=$2 port=$3 app=$4; shift 4
  if [ ! -f "$app" ]; then note "$name: 소스가 없어 건너뜀 ($app)"; return 0; fi
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then note "$name: 이미 실행 중 (포트 $port)"; return 0; fi
  env PORT="$port" "$@" setsid nohup python3 "$app" >> "$LOGS/$(basename "$pidf" .pid).log" 2>&1 < /dev/null &
  echo $! > "$pidf"
  for _ in $(seq 1 20); do curl -s -m 2 "http://127.0.0.1:$port/healthz" >/dev/null && break; sleep 0.5; done
  curl -s -m 2 "http://127.0.0.1:$port/healthz" >/dev/null \
    || { tail -5 "$LOGS/$(basename "$pidf" .pid).log" | sed 's/^/  | /'; die "$name 기동 실패"; }
  note "$name: 시작됨 (포트 $port)"
}
pii_env=(LLM_ENABLED="${PII_LLM_ENABLED:-false}" LLM_URL="${PII_LLM_URL:-}" LLM_MODEL="${PII_LLM_MODEL:-}")
[ -n "${PII_HARMFUL_WORDS:-}" ] && pii_env+=(HARMFUL_WORDS="$PII_HARMFUL_WORDS")
start_py "PII 가드" "$RUN_DIR/pii.pid" "$PII_PORT" "$PII_APP" "${pii_env[@]}"
start_py "모의 서버" "$RUN_DIR/mock.pid" "$MOCK_PORT" "$MOCK_APP"

say "5/6 Kong Gateway"
if kong_up; then note "이미 실행 중"
else
  kong_hosts || true                         # LLM 주소의 IP 에 붙인 이름 (lib.sh)
  kong start -p "$KONG_PREFIX" > "$RUN_DIR/kong-start.log" 2>&1 \
    || { tail -8 "$RUN_DIR/kong-start.log" | sed 's/^/  | /'; die "Kong 기동 실패 ($LOGS/kong-error.log)"; }
  for _ in $(seq 1 30); do kong_up && break; sleep 1; done
  kong_up || die "Kong 이 준비되지 않습니다 ($LOGS/kong-error.log)"
  note "시작됨"
fi
fix_log_path      # 유지 폴더가 다른 경로로 붙은 환경이면 요청 로그 위치를 맞춘다 (lib.sh)

say "6/6 모니터링 — Prometheus · Grafana (3-3)"
if ! mon_on; then note "건너뜀 (MONITORING=off)"
else
  # Prometheus — Kong 지표(:$STATUS_PORT)를 15초마다 모으고 경보 규칙(alerts/)을 계산한다.
  #   기록은 로컬 디스크(~/.kong-poc/prometheus) — Prometheus 저장소는 NFS 를 지원하지 않는다.
  #   다시 빌드해 새 환경이 떠도 그래프가 이어지게 유지 폴더에 사본을 두고(5분마다 · 종료할 때 — lib.sh prom_copy), 뜰 때 되살린다.
  #   보관은 PROM_RETENTION(기본 15d) · PROM_RETENTION_SIZE(기본 2GB) 가운데 먼저 닿는 쪽.
  PROM_DATA="$RUN_DIR/prometheus"
  if prom_running && ! tr '\0' '\n' < "/proc/$(cat "$RUN_DIR/prometheus.pid")/cmdline" 2>/dev/null \
       | grep -qxF -- "--storage.tsdb.path=$PROM_DATA"; then   # 예전 판(유지 폴더에서 바로 씀)으로 떠 있으면 내렸다가 로컬 디스크로 옮겨 띄운다
    prom_copy_stop
    kill "$(cat "$RUN_DIR/prometheus.pid")" 2>/dev/null
    for _ in $(seq 1 40); do prom_running || break; sleep 0.5; done
    if prom_running; then kill -9 "$(cat "$RUN_DIR/prometheus.pid")" 2>/dev/null || true; sleep 1; fi
    rm -f "$RUN_DIR/prometheus.pid"; note "Prometheus: 기록 위치를 로컬 디스크로 바꾸려고 잠시 내림"
  fi
  restored=0
  if prom_persist && ! prom_running; then
    prom_copy_stop   # 되살리는 동안 사본을 고치지 않게
    rc=0; prom_restore || rc=$?
    case $rc in
      0) restored=1; age=$(prom_copy_age)
         note "Prometheus: 유지 폴더의 사본으로 기록을 되살림 (블록 $(prom_blocks "$PROM_DATA" | wc -l | tr -d ' ')개${age:+ · 사본은 $((age / 60))분 전 것})" ;;
      2) note "Prometheus: 유지 폴더의 사본을 되살리지 못함 — 로컬 기록으로 시작하고 사본은 그대로 둠 (다음에 뜰 때 다시)" ;;
    esac
  fi
  prom_launch() {
    mkdir -p "$PROM_DATA" && chmod 700 "$PROM_DATA"
    setsid nohup prometheus --config.file="$RUN_DIR/prometheus.yml" --storage.tsdb.path="$PROM_DATA" \
      --storage.tsdb.retention.time="${PROM_RETENTION:-15d}" --storage.tsdb.retention.size="${PROM_RETENTION_SIZE:-2GB}" \
      --web.listen-address="127.0.0.1:$PROM_PORT" >> "$LOGS/prometheus.log" 2>&1 < /dev/null &
    echo $! > "$RUN_DIR/prometheus.pid"
    # 준비될 때까지 → 0 준비됨 · 1 프로세스가 끝남(실패) · 2 아직 기록을 읽는 중(2분 넘게 — 실패로 보지 않는다)
    for _ in $(seq 1 120); do
      curl -sf -m 2 "http://127.0.0.1:$PROM_PORT/-/ready" >/dev/null && return 0
      prom_running || return 1
      sleep 1
    done
    return 2
  }
  if prom_running; then note "Prometheus: 이미 실행 중 (127.0.0.1:$PROM_PORT · 기록 $PROM_DATA)"
  else
    cat > "$RUN_DIR/prometheus.yml" <<YML
global:
  scrape_interval: 15s
  evaluation_interval: 30s
rule_files:
  - $ROOT/alerts/kong-alerts.yml
scrape_configs:
  - job_name: kong
    static_configs:
      - targets: ["127.0.0.1:$STATUS_PORT"]
YML
    log_at=$(stat -c %s "$LOGS/prometheus.log" 2>/dev/null || echo 0)
    rc=0; prom_launch || rc=$?
    if [ "$rc" = 2 ]; then note "Prometheus: 아직 기록을 읽는 중 — 곧 준비됩니다 ($LOGS/prometheus.log)"
    elif [ "$rc" != 0 ]; then
      plog=$(tail -c +"$((log_at + 1))" "$LOGS/prometheus.log" 2>/dev/null || true)
      if [ "$restored" = 1 ] && grep -q "opening storage failed" <<<"$plog"; then
        # 되살린 사본을 Prometheus 가 읽지 못함 — 사본은 옆으로 비켜 두고(prometheus.bad-<시각>) 빈 기록으로 시작한다
        bad="$(date +%Y%m%d-%H%M%S)"
        if prom_running; then kill "$(cat "$RUN_DIR/prometheus.pid")" 2>/dev/null || true; sleep 1; fi
        mv "$PROM_DATA" "$PROM_DATA.bad-$bad" || true; mv "$DATA_DIR/prometheus" "$DATA_DIR/prometheus.bad-$bad" || true
        rm -f "$RUN_DIR/prometheus.id" "$DATA_DIR/prometheus.id"
        note "Prometheus: 되살린 기록을 읽지 못해 처음부터 시작합니다 (사본은 $DATA_DIR/prometheus.bad-$bad)"
        log_at=$(stat -c %s "$LOGS/prometheus.log" 2>/dev/null || echo 0)
        rc=0; prom_launch || rc=$?
        if [ "$rc" = 1 ]; then
          tail -c +"$((log_at + 1))" "$LOGS/prometheus.log" | tail -5 | sed 's/^/  | /'; die "Prometheus 기동 실패 ($LOGS/prometheus.log)"
        fi
      else
        tail -5 <<<"$plog" | sed 's/^/  | /'; die "Prometheus 기동 실패 ($LOGS/prometheus.log)"
      fi
    fi
    note "Prometheus: 시작됨 (127.0.0.1:$PROM_PORT — Kong 지표 15초마다 · 보관 ${PROM_RETENTION:-15d}·${PROM_RETENTION_SIZE:-2GB} · 기록 $PROM_DATA)"
  fi
  if prom_persist; then prom_copy_start; note "Prometheus: 기록 사본 → $DATA_DIR/prometheus (5분마다 · 종료할 때 최근 기록까지)"
  else note "Prometheus: 기록 사본 안 둠 (PROM_PERSIST=off — 다시 빌드하면 처음부터)"; fi
  # 요청 기록 — 요청 로그를 DB(reqlog)로 옮겨 Grafana 「요청 기록」이 표로 보여 준다. Grafana 는 읽기 전용 계정(비밀번호)으로 읽는다
  if [ -z "${REQLOG_DB_PASSWORD:-}" ]; then
    REQLOG_DB_PASSWORD=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')
    env_set REQLOG_DB_PASSWORD "$REQLOG_DB_PASSWORD" "$ENV_FILE" || die "설정 파일에 쓰지 못했습니다: $ENV_FILE"
  fi
  psql_su -d postgres -v pw="$REQLOG_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE reqlog_reader LOGIN PASSWORD %L', :'pw') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reqlog_reader') \gexec
SELECT format('ALTER ROLE reqlog_reader PASSWORD %L', :'pw') \gexec
SELECT 'CREATE DATABASE reqlog' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'reqlog') \gexec
SQL
  psql_su -d reqlog < "$ROOT/addons/reqlog/schema.sql"
  if reqlog_on; then reqlog_start; note "요청 기록: 요청 로그 → DB reqlog (10초마다 · ${REQLOG_KEEP_DAYS:-30}일 보관) — Grafana 「요청 기록」"
  else note "요청 기록: 옮기지 않음 (REQLOG=off)"; fi
  # Grafana — 프록시의 /grafana 경로로 연다(Kong 이 넘김). 관리자 비밀번호가 없으면 만들어 설정 파일에 적는다
  if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
    GRAFANA_ADMIN_PASSWORD=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(20)))')
    env_set GRAFANA_ADMIN_PASSWORD "$GRAFANA_ADMIN_PASSWORD" "$ENV_FILE" || die "설정 파일에 쓰지 못했습니다: $ENV_FILE"
    note "Grafana 관리자 비밀번호를 만들어 설정 파일에 적었습니다 (GRAFANA_ADMIN_PASSWORD)"
  fi
  if grafana_running; then note "Grafana: 이미 실행 중 (127.0.0.1:$GRAFANA_PORT)"
  else
    mkdir -p "$RUN_DIR/grafana-data/plugins"
    # 대시보드 — 저장소의 JSON 을 로컬 디스크로 옮기며 임베딩 모델 이름(DECK_EMBED_MODEL)을 채운다.
    #   LLM 패널에서 의미 기반 가드 · 캐시가 부르는 임베딩 호출을 빼려고 (지표에 경로 라벨이 없어 모델 이름으로만 가를 수 있다)
    GF_DASH="$RUN_DIR/grafana-dashboards"; rm -rf "$GF_DASH"; mkdir -p "$GF_DASH"
    EMBED="${DECK_EMBED_MODEL:-}" python3 - "$ROOT/addons/monitoring/grafana/dashboards" "$GF_DASH" <<'PY' || die "Grafana 대시보드를 준비하지 못했습니다"
import json, os, pathlib, sys
src, dst = map(pathlib.Path, sys.argv[1:3])
embed = json.dumps(os.environ.get("EMBED") or "-")[1:-1]   # 임베딩이 없으면 아무것도 빼지 않는 값
for f in sorted(src.glob("*.json")):
    (dst / f.name).write_text(f.read_text(encoding="utf-8").replace("__EMBED_MODEL__", embed), encoding="utf-8")
PY
    cat > "$RUN_DIR/grafana.ini" <<INI
[paths]
data = $RUN_DIR/grafana-data
logs = $LOGS
plugins = $RUN_DIR/grafana-data/plugins
provisioning = $ROOT/addons/monitoring/grafana/provisioning
[server]
http_addr = 127.0.0.1
http_port = $GRAFANA_PORT
root_url = %(protocol)s://%(domain)s/grafana/
serve_from_sub_path = true
[security]
admin_user = admin
[users]
allow_sign_up = false
[auth.anonymous]
enabled = false
[analytics]
reporting_enabled = false
check_for_updates = false
check_for_plugin_updates = false
feedback_links_enabled = false
[news]
news_feed_enabled = false
[plugins]
preinstall_disabled = true
[dashboards]
default_home_dashboard_path = $GF_DASH/kong-ai-gateway-poc.json
[log]
mode = console
level = warn
INI
    env GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASSWORD" PROM_PORT="$PROM_PORT" PG_PORT="$PG_PORT" REQLOG_DB_PASSWORD="$REQLOG_DB_PASSWORD" \
        KONG_POC_DASHBOARDS="$GF_DASH" \
      setsid nohup "$GRAFANA_HOME/bin/grafana" server --homepath "$GRAFANA_HOME" --config "$RUN_DIR/grafana.ini" \
      >> "$LOGS/grafana.log" 2>&1 < /dev/null &
    echo $! > "$RUN_DIR/grafana.pid"
    for _ in $(seq 1 60); do curl -s -m 2 "http://127.0.0.1:$GRAFANA_PORT/grafana/api/health" | grep -q database && break; sleep 1; done
    curl -s -m 2 "http://127.0.0.1:$GRAFANA_PORT/grafana/api/health" | grep -q database \
      || { tail -5 "$LOGS/grafana.log" | sed 's/^/  | /'; die "Grafana 기동 실패 ($LOGS/grafana.log)"; }
    note "Grafana: 시작됨 (127.0.0.1:$GRAFANA_PORT — 프록시의 /grafana 로 연다, admin / GRAFANA_ADMIN_PASSWORD)"
  fi
fi

cat <<MSG

──────────────────────────────────────────────
 Kong AI Gateway PoC 기동 완료 (직접 설치)
──────────────────────────────────────────────
 프록시        http://127.0.0.1:$PROXY_PORT   (파드 안) · http://<파드 IP>:$PROXY_PORT
 Kong Manager  $MANAGER_URL/
               kong_admin / 설정 파일의 KONG_ADMIN_PASSWORD
 Grafana       <프록시 주소>/grafana/   admin / 설정 파일의 GRAFANA_ADMIN_PASSWORD  (MONITORING=on)
 설정 파일     $ENV_FILE
 데이터·로그   $DATA_DIR
 다음          bash apply-config.sh   요구사항별 설정 적용 (라이선스 필요)
               bash verify.sh         요구사항별 점검
──────────────────────────────────────────────
MSG
