#!/usr/bin/env bash
# stop.sh — 컨테이너를 내린다. 데이터는 남긴다.
#   ./stop.sh --purge   데이터(도커 볼륨)까지 삭제 — 되돌릴 수 없음
source "$(dirname "$0")/lib.sh"
say "컨테이너 정지"
for c in "$C_KONG" "$C_PII" "$C_PG"; do docker rm -f "$c" >/dev/null 2>&1 && note "$c 정지" || true; done
if [ "${1:-}" = "--purge" ]; then
  say "데이터 삭제"
  for v in "$PG_VOLUME" "$LOG_VOLUME"; do
    docker volume rm "$v" >/dev/null 2>&1 && note "볼륨 $v 삭제" || true
  done
  docker network rm "$NET" >/dev/null 2>&1 || true
fi
