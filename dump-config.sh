#!/usr/bin/env bash
# dump-config.sh — 지금 Kong 에 들어 있는 설정을 파일로 받는다 (Kong Manager 에서 바꾼 것 포함, 백업·비교용)
source "$(dirname "$0")/lib.sh"
load_env; native_env
kong_up || die "Kong 이 실행 중이 아닙니다 — bash start.sh"
mkdir -p conf/backup; out="conf/backup/kong-dump-$(date +%Y%m%d-%H%M%S).yaml"
deck gateway dump --yes -o "$out" --kong-addr "http://127.0.0.1:$ADMIN_PORT" \
  --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD" >/dev/null
note "저장: $out ($(du -h "$out" | cut -f1))"
