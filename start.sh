#!/usr/bin/env bash
# start.sh — Kong AI Gateway PoC 기동. 여러 번 실행해도 안전하다(이미 떠 있으면 건너뜀).
source "$(dirname "$0")/lib.sh"
load_env

say "0/6 라이선스 확인"
check_license

say "1/6 이미지 준비"
ensure_image "$KONG_IMAGE"; ensure_image "$PG_IMAGE"; ensure_image "$DECK_IMAGE"
HAS_PII=0; [ -f addons/pii-guard/app.py ] && HAS_PII=1
[ "$HAS_PII" = 1 ] && ensure_image "$PY_IMAGE"

say "2/6 설정을 담은 이미지 빌드 (바인드 마운트 없이 동작)"
build kong-poc/postgres build/postgres.Dockerfile --build-arg PG_IMAGE="$PG_IMAGE"
build kong-poc/deck     build/deck.Dockerfile     --build-arg DECK_IMAGE="$DECK_IMAGE"
[ "$HAS_PII" = 1 ] && build kong-poc/pii-guard build/pii-guard.Dockerfile --build-arg PY_IMAGE="$PY_IMAGE"
note "kong-poc/postgres · kong-poc/deck$([ "$HAS_PII" = 1 ] && echo ' · kong-poc/pii-guard')"

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

say "3/6 PostgreSQL"
if running "$C_PG"; then note "이미 실행 중"
else
  docker rm -f "$C_PG" >/dev/null 2>&1 || true
  if [ -n "${PG_DATA_DIR:-}" ]; then mkdir -p "$PG_DATA_DIR"; DATA_MOUNT="$PG_DATA_DIR:/var/lib/postgresql/data"
  else DATA_MOUNT="$PG_VOLUME:/var/lib/postgresql/data"; fi
  docker run -d --name "$C_PG" --network "$NET" --restart unless-stopped --memory 1g \
    -e POSTGRES_DB=kong -e POSTGRES_USER=kong -e POSTGRES_PASSWORD="$KONG_PG_PASSWORD" \
    -v "$DATA_MOUNT" kong-poc/postgres postgres -c max_connections=200 >/dev/null
  note "데이터: ${PG_DATA_DIR:-도커 볼륨 $PG_VOLUME}"
fi
for i in $(seq 1 60); do
  docker exec "$C_PG" pg_isready -U kong -d kong >/dev/null 2>&1 && break
  [ "$i" = 60 ] && die "PostgreSQL 이 준비되지 않습니다.  docker logs $C_PG"
  sleep 2
done
# 초기화 스크립트가 벡터 DB 를 만들 때까지 대기
for i in $(seq 1 30); do
  docker exec "$C_PG" psql -U kong -d kong-pgvector -tAc "select 1 from pg_extension where extname='vector'" 2>/dev/null | grep -q 1 && break
  [ "$i" = 30 ] && die "벡터 DB(kong-pgvector) 초기화 실패.  docker logs $C_PG"
  sleep 2
done
note "준비됨 (DB: kong · kong-pgvector)"

say "4/6 Kong DB 마이그레이션"
kong_env
out=$(docker run --rm --network "$NET" "${KONG_ENV[@]}" "$KONG_IMAGE" kong migrations bootstrap 2>&1) || true
if echo "$out" | grep -qi "already bootstrapped"; then
  docker run --rm --network "$NET" "${KONG_ENV[@]}" "$KONG_IMAGE" sh -c 'kong migrations up && kong migrations finish' >/dev/null 2>&1 || true
  note "기존 DB — 필요한 마이그레이션만 적용"
elif echo "$out" | grep -qiE "complete|executed"; then
  note "최초 초기화 완료 (관리자 계정 kong_admin 생성)"
else
  echo "$out" | tail -5; die "마이그레이션 실패"
fi

if [ "$HAS_PII" = 1 ]; then
  say "5/6 한국어 PII 가드"
  if running "$C_PII"; then note "이미 실행 중"
  else
    docker rm -f "$C_PII" >/dev/null 2>&1 || true
    docker run -d --name "$C_PII" --network "$NET" --restart unless-stopped --memory 256m \
      -e LLM_ENABLED="${PII_LLM_ENABLED:-false}" -e LLM_URL="${PII_LLM_URL:-}" -e LLM_MODEL="${PII_LLM_MODEL:-}" \
      kong-poc/pii-guard >/dev/null
    note "시작됨 (문맥 판정 LLM: ${PII_LLM_ENABLED:-false})"
  fi
else
  say "5/6 한국어 PII 가드 — addons/pii-guard/app.py 가 없어 건너뜀"
fi

say "6/6 Kong Gateway"
if running "$C_KONG"; then note "이미 실행 중"
else
  docker rm -f "$C_KONG" >/dev/null 2>&1 || true
  # 요청 로그 저장소: LOG_DIR 을 지정하면 그 경로, 아니면 도커 볼륨
  if [ -n "${LOG_DIR:-}" ]; then mkdir -p "$LOG_DIR"; LOG_MOUNT="$LOG_DIR:/var/log/kong-poc"
  else LOG_MOUNT="$LOG_VOLUME:/var/log/kong-poc"; fi
  # Kong 은 kong 사용자로 실행되므로 로그 디렉토리 소유자를 맞춘다
  docker run --rm -u 0 -v "$LOG_MOUNT" --entrypoint chown "$KONG_IMAGE" kong:kong /var/log/kong-poc
  docker run -d --name "$C_KONG" --network "$NET" --restart unless-stopped --memory 2g \
    -p "$PROXY_PORT:8000" -p "$ADMIN_PORT:8001" -p "$MANAGER_PORT:8002" \
    -v "$LOG_MOUNT" "${KONG_ENV[@]}" "$KONG_IMAGE" >/dev/null
  note "요청 로그: ${LOG_DIR:-도커 볼륨 $LOG_VOLUME}"
fi
for i in $(seq 1 60); do
  docker exec "$C_KONG" kong health >/dev/null 2>&1 && break
  [ "$i" = 60 ] && die "Kong 이 준비되지 않습니다.  docker logs $C_KONG"
  sleep 2
done
note "준비됨"

# 최초 기동이면 설정 적용 (이후 변경은 ./apply-config.sh)
if ! docker run --rm --network "$NET" kong-poc/deck gateway dump -o - --select-tag kong-poc \
      --kong-addr "http://$C_KONG:8001" --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD" 2>/dev/null \
      | grep -q 'name: llm-chat'; then
  "$ROOT/apply-config.sh"
fi

cat <<MSG

──────────────────────────────────────────────
 Kong AI Gateway PoC 기동 완료
──────────────────────────────────────────────
 프록시        http://localhost:$PROXY_PORT
 Kong Manager  $MANAGER_URL   (kong_admin / .env 의 KONG_ADMIN_PASSWORD)
 상태 확인     ./status.sh
──────────────────────────────────────────────
MSG
