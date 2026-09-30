#!/usr/bin/env bash
# apply-config.sh — conf/ 의 선언형 설정을 Kong 에 반영한다 (decK sync).
#   kong-poc 태그가 붙은 것만 관리하므로 Kong Manager 에서 직접 만든 설정은 건드리지 않는다.
source "$(dirname "$0")/lib.sh"
load_env

files=(/conf/kong.yaml)
if [ -n "${DECK_EMBED_URL:-}" ] && [ -n "${DECK_EMBED_MODEL:-}" ]; then files+=(/conf/scenarios/semantic-cache.yaml)
else note "임베딩 모델 미지정 — 시맨틱 캐시 시나리오 제외"; fi
if running "$C_PII"; then files+=(/conf/scenarios/pii-guard.yaml)
else note "PII 가드 미실행 — PII 시나리오 제외"; fi

say "설정 반영: ${files[*]}"
build kong-poc/deck build/deck.Dockerfile --build-arg DECK_IMAGE="$DECK_IMAGE"
# 설정 파일 속 주소는 실행 방식마다 다르다 — 컨테이너 방식에서 보이는 값 (직접 설치는 native/apply-config.sh)
export DECK_AUDIT_LOG=/var/log/kong-poc/audit.log DECK_PG_HOST="$C_PG" DECK_PG_PORT=5432 \
       DECK_PII_URL="http://$C_PII:8080/check" DECK_KONG_LOOPBACK=http://127.0.0.1:8000
DECK_VARS=(); while IFS='=' read -r k _; do DECK_VARS+=(-e "$k"); done < <(env | grep '^DECK_')
docker run --rm --network "$NET" "${DECK_VARS[@]}" kong-poc/deck gateway sync \
  --kong-addr "http://$C_KONG:8001" --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD" "${files[@]}"
