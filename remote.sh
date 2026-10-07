#!/usr/bin/env bash
# remote.sh — 빌드한 새 환경(run.sh 로 떠 있는 곳)에 일을 맡기고 결과를 보여 준다.
#   같은 유지 폴더를 붙인 개발 파드에서 쓴다 — 새 환경에 터미널이 없어도 된다 (유지 폴더의 requests/ 를 거쳐 전달).
#   bash remote.sh status        상태
#   bash remote.sh apply         설정 적용 (bash set-env.sh 로 값을 바꾼 뒤) · apply-dry = 바뀔 내용만 보기
#   bash remote.sh restart       다시 띄우기 (접속 주소·포트·LLM 주소·라이선스를 바꾼 뒤)
#   bash remote.sh verify        점검 · verify-full = 70초 장기 응답까지
#   bash remote.sh switch [<이름> on|off]   /poc 플러그인·긴급 차단 켜고 끄기 (이름 없이 = 지금 상태) — switch.sh
#   결과는 화면에 보여 주고 <유지 폴더>/requests/done/ 에도 남는다.
source "$(dirname "$0")/lib.sh"
load_env; native_env

cmd=${1:-}
case "$cmd" in
  status|apply|apply-dry|restart|verify|verify-full) ;;
  switch)   # 이름은 글자·숫자·- _ 만, 상태는 on/off — 새 환경의 switch.sh 가 아는 이름인지 다시 확인한다
    [ $# -eq 1 ] || { [ $# -eq 3 ] && [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && [[ "$3" =~ ^(on|off)$ ]]; } \
      || die "사용법: bash remote.sh switch <이름> on|off   (목록: bash remote.sh switch)"
    if [ $# -eq 3 ]; then cmd="switch $2 $3"; fi ;;
  *) die "사용법: bash remote.sh status | apply | apply-dry | restart | verify | verify-full | switch [<이름> on|off]" ;;
esac
lock_read
if [ -z "$LOCK_HOST" ] || [ "$LOCK_AGE" -ge "$LOCK_STALE" ]; then
  die "실행 중인 환경이 없습니다 (유지 폴더 $DATA_DIR 의 실행 기록${LOCK_HOST:+ — 마지막 $LOCK_HOST, ${LOCK_AGE}초 전}).
  빌드한 새 환경에서 run.sh 가 떠 있는지 확인하세요."
fi
[ "$LOCK_HOST" != "$HOST_ID" ] || die "이 환경에서 직접 돌고 있습니다 — remote.sh 대신 스크립트를 바로 실행하세요 (status.sh · apply-config.sh · verify.sh …)"

REQ="$DATA_DIR/requests"
mkdir -p "$REQ/done"
id="$(date +%Y%m%d-%H%M%S)-$$-${cmd// /_}"
printf '%s\n' "$cmd" > "$REQ/$id.req.tmp" && mv -f "$REQ/$id.req.tmp" "$REQ/$id.req"
say "$LOCK_HOST 에 '$cmd' 를 맡겼습니다 — 결과를 기다립니다 (최대 15분)"
for _ in $(seq 1 900); do [ -f "$REQ/done/$id.log" ] && break; sleep 1; done
[ -f "$REQ/done/$id.log" ] || die "15분 안에 결과가 없습니다 — 새 환경의 로그를 확인하세요 (요청: $REQ/$id.req)"
cat "$REQ/done/$id.log"
