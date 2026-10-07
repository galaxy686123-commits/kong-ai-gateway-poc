#!/usr/bin/env bash
# remote.sh — 빌드한 새 환경(run.sh 로 떠 있는 곳)에 일을 맡기고 결과를 보여 준다.
#   같은 유지 폴더를 붙인 개발 파드에서 쓴다 — 새 환경에 터미널이 없어도 된다 (유지 폴더의 requests/ 를 거쳐 전달).
#   bash remote.sh status        상태
#   bash remote.sh apply         설정 적용 (bash set-env.sh 로 값을 바꾼 뒤) · apply-dry = 바뀔 내용만 보기
#   bash remote.sh restart       다시 띄우기 (접속 주소·포트·LLM 주소·라이선스를 바꾼 뒤)
#   bash remote.sh verify        점검 · verify-full = 70초 장기 응답까지
#   bash remote.sh switch [<이름> on|off]   /poc 플러그인·긴급 차단 켜고 끄기 (이름 없이 = 지금 상태) — switch.sh
#   bash remote.sh vectors ['문장']   벡터 DB 에 들어 있는 것 (문장을 주면 가까운 것과 거리) — vectors.sh
#   bash remote.sh update        빌드 없이 코드 갱신 — 이 저장소(git pull 한 것)를 유지 폴더의 code/ 에 넣고 새 환경이 그 코드로 다시 뜬다
#   bash remote.sh rollback      바로 전 코드로 되돌림 (처음 update 전이면 빌드 스냅샷으로)
#   결과는 화면에 보여 주고 <유지 폴더>/requests/done/ 에도 남는다.
source "$(dirname "$0")/lib.sh"
load_env; native_env

cmd=${1:-}
case "$cmd" in
  status|apply|apply-dry|restart|verify|verify-full|update|rollback) ;;
  switch)   # 이름은 글자·숫자·- _ 만, 상태는 on/off — 새 환경의 switch.sh 가 아는 이름인지 다시 확인한다
    [ $# -eq 1 ] || { [ $# -eq 3 ] && [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && [[ "$3" =~ ^(on|off)$ ]]; } \
      || die "사용법: bash remote.sh switch <이름> on|off   (목록: bash remote.sh switch)"
    if [ $# -eq 3 ]; then cmd="switch $2 $3"; fi ;;
  vectors)  # 문장은 한 줄 · 300자까지 (요청 파일 한 줄로 전달)
    if [ $# -ge 2 ]; then
      q="${*:2}"; [ "${#q}" -le 300 ] && [[ "$q" != *$'\n'* ]] || die "문장은 한 줄 · 300자까지입니다"
      cmd="vectors $q"
    fi ;;
  *) die "사용법: bash remote.sh status | apply | apply-dry | restart | verify | verify-full | switch [<이름> on|off] | vectors ['문장'] | update | rollback" ;;
esac
lock_read
[ "$LOCK_HOST" != "$HOST_ID" ] || die "이 환경에서 직접 돌고 있습니다 — remote.sh 대신 스크립트를 바로 실행하세요 (status.sh · apply-config.sh · verify.sh …)"
running=1; if [ -z "$LOCK_HOST" ] || [ "$LOCK_AGE" -ge "$LOCK_STALE" ]; then running=0; fi

REQ="$DATA_DIR/requests"
mkdir -p "$REQ/done"
send() {  # send <일> <기다릴 초> — 새 환경에 맡기고 결과를 보여 준다
  local c=$1 wait=$2 id
  id="$(date +%Y%m%d-%H%M%S)-$$-${c%% *}"   # 파일 이름에는 일 이름만 (문장이 들어가지 않게)
  printf '%s\n' "$c" > "$REQ/$id.req.tmp" && mv -f "$REQ/$id.req.tmp" "$REQ/$id.req"
  say "$LOCK_HOST 에 '$c' 를 맡겼습니다 — 결과를 기다립니다 (최대 $((wait / 60))분)"
  for _ in $(seq 1 "$wait"); do [ -f "$REQ/done/$id.log" ] && break; sleep 1; done
  [ -f "$REQ/done/$id.log" ] || return 1
  cat "$REQ/done/$id.log"
}

# ── 빌드 없이 코드 갱신 ──────────────────────────────────────────────
#  새 환경의 run.sh 는 시작할 때 유지 폴더에 code/run.sh 가 있으면 빌드 스냅샷 대신 그 코드로 돈다.
#  code/ = 지금 코드 · code.prev/ = 바로 전 코드(rollback 용, 처음 update 전이면 「빌드 스냅샷」 표시만 든 빈 폴더).
#  사본을 넣은 뒤 다시 빌드하면 새 환경은 빌드한 코드로 돌고 사본을 code.prev 로 비켜 둔다 (run.sh).
#  설치 파일(pkgs/)이 그대로면 바로 전 사본과 하드 링크로 나눠 써서 거의 복사하지 않는다.
if [ "$cmd" = update ] || [ "$cmd" = rollback ]; then
  CODE="$DATA_DIR/code"
  if [ "$cmd" = update ]; then
    for f in "$ROOT"/*.sh; do bash -n "$f" || die "문법 오류: ${f#"$ROOT"/} — 고친 뒤 다시 하세요"; done
    python3 - "$ROOT" <<'PY' || die "파이썬 문법 오류 — 고친 뒤 다시 하세요"
import ast, pathlib, sys
root = pathlib.Path(sys.argv[1])
for f in sorted(root.glob("*.py")) + sorted(root.glob("addons/*/*.py")):
    ast.parse(f.read_text(encoding="utf-8"), str(f))
PY
    (cd "$ROOT/pkgs" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1) || die "설치 파일(pkgs/)의 체크섬이 맞지 않습니다 — git pull 로 다시 받으세요"
    new="$DATA_DIR/code.new"; rm -rf "$new"; mkdir -p "$new"
    tar -C "$ROOT" --exclude=./.git --exclude=./data --exclude='./data.moved-*' --exclude=./secrets --exclude=./pkgs \
        --exclude='__pycache__' --exclude='*.pyc' -cf - . | tar -C "$new" -xf - || die "코드를 유지 폴더에 복사하지 못했습니다 ($new)"
    if [ -f "$CODE/pkgs/SHA256SUMS" ] && cmp -s "$CODE/pkgs/SHA256SUMS" "$ROOT/pkgs/SHA256SUMS" && cp -al "$CODE/pkgs" "$new/pkgs" 2>/dev/null; then :
    else rm -rf "$new/pkgs"; cp -a "$ROOT/pkgs" "$new/pkgs" || die "설치 파일을 복사하지 못했습니다"; fi
    rev=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "-")
    dirty=$(git -C "$ROOT" status --porcelain 2>/dev/null | grep -vc '^??' || true)
    { echo "commit=$rev$([ "${dirty:-0}" -gt 0 ] && echo " (+수정 $dirty)")"
      echo "at=$(date '+%F %T')"; echo "from=$HOST_ID"; } > "$new/.code-info"
    rm -rf "$DATA_DIR/code.prev"
    if [ -d "$CODE" ]; then mv "$CODE" "$DATA_DIR/code.prev"
    else mkdir -p "$DATA_DIR/code.prev" && echo "빌드 스냅샷" > "$DATA_DIR/code.prev/.snapshot"; fi
    mv "$new" "$CODE"
    say "유지 폴더에 코드를 넣었습니다 — $(code_info "$CODE")"
  else
    [ -d "$DATA_DIR/code.prev" ] || die "되돌릴 코드가 없습니다 — bash remote.sh update 를 한 적이 없습니다"
    tmp="$DATA_DIR/code.swap.$$"
    if [ -d "$CODE" ]; then mv "$CODE" "$tmp"; fi
    mv "$DATA_DIR/code.prev" "$CODE"
    if [ -d "$tmp" ]; then mv "$tmp" "$DATA_DIR/code.prev"; fi
    rm -f "$CODE/.snapshot-fp"   # 새 환경이 지금 스냅샷을 다시 기억한다 (다시 빌드한 것으로 오해하지 않게)
    say "바로 전 코드로 되돌렸습니다 — $(code_info "$CODE")"
  fi
  rm -f "$DATA_DIR/code-fails"
  if [ "$running" = 0 ]; then note "새 환경이 떠 있지 않습니다 — 다음에 뜰 때 이 코드로 돕니다"; exit 0; fi
  send reload 120 || die "새 환경이 2분 안에 응답하지 않습니다 — bash remote.sh status 로 확인하세요"
  # 새 환경이 내렸다가 새 코드로 다시 뜬다 — 다시 뜨면 상태 요청을 처리한다
  send status 600 || die "새 환경이 10분 안에 다시 뜨지 않았습니다.
  새 코드가 세 번 연속 기동에 실패하면 빌드 스냅샷으로 돕니다. 되돌리려면: bash remote.sh rollback"
  exit 0
fi

if [ "$running" = 0 ]; then
  die "실행 중인 환경이 없습니다 (유지 폴더 $DATA_DIR 의 실행 기록${LOCK_HOST:+ — 마지막 $LOCK_HOST, ${LOCK_AGE}초 전}).
  빌드한 새 환경에서 run.sh 가 떠 있는지 확인하세요."
fi
send "$cmd" 900 || die "15분 안에 결과가 없습니다 — 새 환경의 로그를 확인하세요 (요청: $REQ)"
