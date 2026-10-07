#!/usr/bin/env bash
# guard-test.sh — 가드레일(4-1 ~ 4-5)을 문장 묶음으로 시험한다: 잡은 비율(막거나 가림)과 잘못 막은 비율
#   bash guard-test.sh                 묶음으로 시험 — 유지 폴더의 guard-set.tsv, 없으면 저장소의 tests/guard-set.tsv
#   bash guard-test.sh <파일>           그 묶음으로
#   bash guard-test.sh --init          저장소의 기본 묶음을 유지 폴더(guard-set.tsv)에 복사 — 고객 업무 문장을 더해 쓴다
#   --detect <퍼센트> · --fp <퍼센트>    판정 기준 (기본 90 · 5 — 예시. 합의한 값으로)
#   빌드한 새 환경이면 개발 파드에서 bash remote.sh guard-test (유지 폴더의 묶음 · 기본 기준)
# verify.sh 처럼 /poc 의 가드레일 플러그인을 영역마다 잠깐 켜고(약 1~2분), 끝나면(Ctrl+C 로 멈춰도) 처음 상태로 돌린다.
# 그동안 /poc 를 부르는 다른 요청에도 같은 플러그인이 걸리므로 시연 중에는 돌리지 않고, verify.sh 와 동시에 돌리지 않는다.
# 문장은 모의 LLM(model=mock-llm)으로 보낸다 — 받은 질문을 그대로 답하므로 4-4 · 4-5 묶음의 문장은 곧 「LLM 의 답」이다.
# 결과는 화면과 유지 폴더 reports/guard-<시각>.txt (요약) · .tsv (문장마다).
source "$(dirname "$0")/lib.sh"
load_env; native_env

SET=""; DETECT=90; FPMAX=5; INIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --init)   INIT=1 ;;
    --detect) DETECT=${2:-}; shift ;;
    --fp)     FPMAX=${2:-}; shift ;;
    -*)       die "알 수 없는 옵션: $1  (--init · --detect <퍼센트> · --fp <퍼센트>)" ;;
    *)        SET=$1 ;;
  esac
  shift
done
{ [[ "$DETECT" =~ ^[0-9]+$ ]] && [ "$DETECT" -le 100 ] && [[ "$FPMAX" =~ ^[0-9]+$ ]] && [ "$FPMAX" -le 100 ]; } \
  || die "--detect · --fp 는 0 ~ 100 사이 숫자입니다"
DEFAULT_SET="$ROOT/tests/guard-set.tsv"; PV_SET="$DATA_DIR/guard-set.tsv"
if [ "$INIT" = 1 ]; then
  if [ -f "$PV_SET" ]; then note "이미 있습니다 — 그대로 둡니다: $PV_SET"
  else
    cp "$DEFAULT_SET" "$PV_SET" || die "복사하지 못했습니다: $PV_SET"
    note "기본 묶음을 복사했습니다: $PV_SET"
    note "고객 업무 문장을 더한 뒤 bash guard-test.sh (빌드한 새 환경이면 개발 파드에서 bash remote.sh guard-test)"
  fi
  exit 0
fi
if [ -z "$SET" ]; then SET=$DEFAULT_SET; [ -f "$PV_SET" ] && SET=$PV_SET; fi
[ -f "$SET" ] || die "묶음 파일이 없습니다: $SET"
GT() { GT_URL="http://127.0.0.1:$PROXY_PORT/poc" GT_KEY="$DECK_CLIENT_KEY" python3 "$ROOT/guard-test.py" "$@"; }
GT check "$SET" >/dev/null || exit 1          # 형식이 틀리면 플러그인을 건드리기 전에 멈춘다

if ! kong_up; then
  lock_read
  if [ -n "$LOCK_HOST" ] && [ "$LOCK_HOST" != "$HOST_ID" ] && [ "$LOCK_AGE" -lt "$LOCK_STALE" ]; then
    die "Kong 은 다른 환경($LOCK_HOST)에서 돌고 있습니다 — 개발 파드에서 bash remote.sh guard-test"
  fi
  die "Kong 이 떠 있지 않습니다 — bash start.sh"
fi
PL=$(admin "/routes/poc/plugins?size=100")
[[ "$PL" == *'"data"'* ]] || die "/poc 경로가 없습니다 — bash apply-config.sh"
# 긴급 차단 중이면 시험하지 않는다 — /poc 차단은 시험이 잠깐 풀게 되고, 계정 차단이면 시험 요청이 모두 403
for k in kill-switch--poc kill-switch--team-a-app; do
  admin "/plugins?size=1000" | python3 -c 'import json, sys
sys.exit(0 if any(p.get("instance_name") == sys.argv[1] and p.get("enabled") for p in json.load(sys.stdin)["data"]) else 1)' "$k" \
    && die "긴급 차단($k)이 켜져 있어 시험하지 않습니다 — Kong Manager 에서 끈 뒤 다시 하세요"
done

mkdir -p "$DATA_DIR/reports"
STAMP="$DATA_DIR/reports/guard-$(date +%Y%m%d-%H%M%S)"
exec > >(tee "$STAMP.txt") 2>&1; TEE_PID=$!
echo "가드레일 문장 묶음 시험 — $(date '+%F %T')"
note "$(GT check "$SET" | sed 's/^ *//') · 묶음 $SET"
note "기준 — 잡은 비율 ${DETECT}% 이상 · 잘못 막은 비율 ${FPMAX}% 이하 · 모의 LLM(mock-llm) · 부서 키 team-a"

# 플러그인은 verify.sh 와 같은 방식으로 바꾼다 (lib.sh 의 pset · phase — 처음 값은 verify-restore.json 에 남겨 끊겨도 되돌림)
RESTORE=$(verify_restore_file); BASE=$(poc_base)
if [ -f "$RESTORE" ]; then
  verify_restore; note "지난 점검이 중간에 끊겨 바뀐 채 남은 /poc 플러그인을 먼저 처음 상태로 돌렸습니다"; sleep 6
fi
trap 'verify_restore' EXIT; trap 'exit 130' INT TERM
hasp() { grep -q "\"name\":\"$1\"" <<<"$PL"; }
RES="$STAMP.tsv"
area() {  # area "<영역…>" "<설명>" <플러그인…> — 기본 상태(키 인증만)에서 그 플러그인만 켜고 영역의 문장을 보낸다
  local areas=$1 desc=$2 p a on=() names=(); shift 2
  for p in "$@"; do
    if hasp "$p"; then on+=("$p=true"); names+=("$p"); fi
  done
  say "$areas $desc — 켬: ${names[*]:-없음}"
  for p in "$@"; do
    case "$p" in ai-semantic-*) hasp "$p" || note "$p 없음 — 임베딩 모델이 없어 의미 기반 검사 없이 봅니다" ;; esac
  done
  phase "${on[@]}"
  for a in $areas; do GT run "$a" "$SET" "$RES"; done
}
area "4-1" "개인정보 마스킹 (질문)" pii-masking
area "4-2 4-3" "기밀 키워드 · 인젝션·탈옥 (질문)" ai-prompt-guard ai-semantic-prompt-guard
area "4-4" "유해 답변 (답변)" ai-custom-guardrail ai-semantic-response-guard
area "4-5" "답변 속 내부 정보 (답변)" response-masking

say "결과"
GT summary "$RES" "$DETECT" "$FPMAX"
verify_restore; trap - EXIT
note "/poc 플러그인을 처음 상태로 돌렸습니다"
echo "  기록: $STAMP.txt (요약) · $STAMP.tsv (문장마다)"
exec >&- 2>&-; wait "$TEE_PID" 2>/dev/null   # 기록을 다 쓴 뒤 끝낸다
