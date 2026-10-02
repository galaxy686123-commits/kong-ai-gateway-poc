#!/usr/bin/env bash
# set-license.sh — 받은 라이선스 파일을 제자리(유지 폴더를 쓰면 그곳의 secrets/license.json)에 넣는다.
#   bash set-license.sh <라이선스 파일>     예) 주피터로 올린 파일
#   넣은 뒤 Kong 을 다시 띄워야 읽는다: bash stop.sh && bash start.sh  (빌드한 새 환경이면 bash remote.sh restart)
source "$(dirname "$0")/lib.sh"
load_env --no-check

[ $# -eq 1 ] || die "사용법: bash set-license.sh <라이선스 파일>   (넣을 곳: $LICENSE_FILE)"
src=$1
[ -f "$src" ] || die "파일이 없습니다: $src"
grep -q '"license_expiration_date"' "$src" || die "Kong 라이선스 파일이 아닌 것 같습니다 (license_expiration_date 없음): $src"
mkdir -p "$(dirname "$LICENSE_FILE")" && chmod 700 "$(dirname "$LICENSE_FILE")" 2>/dev/null || true
if [ -f "$LICENSE_FILE" ] && ! cmp -s "$src" "$LICENSE_FILE"; then
  cp -p "$LICENSE_FILE" "$LICENSE_FILE.before-$(date +%Y%m%d-%H%M%S)"
fi
{ cp "$src" "$LICENSE_FILE.tmp" && chmod 600 "$LICENSE_FILE.tmp" && mv -f "$LICENSE_FILE.tmp" "$LICENSE_FILE"; } \
  || die "넣지 못했습니다: $LICENSE_FILE"
license_state
note "라이선스를 넣었습니다 → $LICENSE_FILE ($LIC_MSG)"
note "Kong 이 새 라이선스를 읽게:  bash stop.sh && bash start.sh   (빌드한 새 환경이면 bash remote.sh restart)"
