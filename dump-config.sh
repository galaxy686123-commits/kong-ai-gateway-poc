#!/usr/bin/env bash
# dump-config.sh — 현재 Kong 설정 전체를 파일로 백업한다.
#   Kong Manager 에서 바꾼 내용도 포함된다. 데이터가 날아갔을 때 복원 근거가 된다.
source "$(dirname "$0")/lib.sh"
load_env
mkdir -p conf/backup
out="conf/backup/kong-dump-$(date +%Y%m%d-%H%M%S).yaml"
docker run --rm --network "$NET" kong-poc/deck gateway dump -o - \
  --kong-addr "http://$C_KONG:8001" --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD" > "$out"
note "저장: $out ($(du -h "$out" | cut -f1), 최상위 항목 $(grep -c "^- " "$out")개)"
