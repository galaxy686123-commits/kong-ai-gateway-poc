#!/usr/bin/env bash
# status.sh — 컨테이너·라우트 상태를 보여준다.
source "$(dirname "$0")/lib.sh"
load_env
say "컨테이너"
docker ps -a --filter "name=kong-poc-" --format 'table {{.Names}}\t{{.Status}}' | sed 's/^/  /'
say "Kong"
if running "$C_KONG"; then
  docker exec "$C_KONG" kong health 2>&1 | sed 's/^/  /' | tail -3
  say "라우트"
  docker run --rm --network "$NET" kong-poc/deck gateway dump -o - \
    --kong-addr "http://$C_KONG:8001" --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD" 2>/dev/null \
    | awk '/^  routes:/{r=1} /paths:/{p=1;next} p&&/- \//{print "  " $2; p=0}'
else note "실행 중 아님"; fi
