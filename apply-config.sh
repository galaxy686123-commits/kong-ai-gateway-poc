#!/usr/bin/env bash
# apply-config.sh — conf/ 의 선언형 설정을 Kong 에 반영한다 (decK sync, 직접 설치 방식).
#   kong-poc 태그가 붙은 것만 관리하므로 Kong Manager 에서 직접 만든 설정은 건드리지 않는다.
source "$(dirname "$0")/lib.sh"
load_env; native_env

# 설정 파일 속 주소 — 모두 이 파드 안
export DECK_AUDIT_LOG="$LOGS/audit.log" DECK_PG_HOST=127.0.0.1 DECK_PG_PORT="$PG_PORT" \
       DECK_PII_URL="http://127.0.0.1:$PII_PORT/check" DECK_KONG_LOOPBACK="http://127.0.0.1:$PROXY_PORT"

files=(conf/kong.yaml)
if [ -n "${DECK_EMBED_URL:-}" ] && [ -n "${DECK_EMBED_MODEL:-}" ]; then files+=(conf/scenarios/semantic-cache.yaml)
else note "임베딩 모델 미지정 — 시맨틱 캐시 시나리오 제외"; fi
if pii_running; then files+=(conf/scenarios/pii-guard.yaml)
else note "PII 가드 미실행 — PII 시나리오 제외"; fi

say "설정 반영: ${files[*]}"
deck gateway sync --kong-addr "http://127.0.0.1:$ADMIN_PORT" \
  --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD" "${files[@]}"
