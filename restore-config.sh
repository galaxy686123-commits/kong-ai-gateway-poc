#!/usr/bin/env bash
# restore-config.sh — Kong 의 번들 설정(kong-poc 태그)을 백업해 둔 시점으로 되돌린다.
#   bash restore-config.sh                           백업 목록 (최근 것부터)
#   bash restore-config.sh <백업 파일 이름> --dry-run   바뀔 것만 본다 (값은 보이지 않음 — 만들기 · 바꾸기 · 지우기 목록)
#   bash restore-config.sh <백업 파일 이름>             그 시점으로 되돌림
# 백업 (유지 폴더 backup/):
#   kong-before-apply-<시각>.json    설정 적용(apply-config.sh)이 Kong Manager 에서 바꾼 값을 되돌리기 직전 상태
#                                   — 적용으로 되돌아간 Manager 설정(LLM 대상 · 한도 · 지운 경로 …)을 그대로 되살릴 때
#   kong-before-restore-<시각>.json  이 스크립트가 되돌리기 직전 상태 — 되돌린 것을 다시 되돌릴 때
# 되돌리는 범위: kong-poc 태그가 붙은 것 전부(서비스 · 경로 · 플러그인 · 계정 · Upstream). Manager 에서 직접 만든 것(태그 없음)은 건드리지 않는다.
# 되살린 Manager 값은 설정 파일과 다르므로 다음 설정 적용 때 다시 「Kong Manager 에서 바꾼 값」으로 나와 되돌아간다 — 적용 전에 apply-dry 로 확인.
# 빌드한 새 환경: bash remote.sh restore [<백업 파일 이름>] [--dry-run]
source "$(dirname "$0")/lib.sh"
load_env; native_env

BK="$DATA_DIR/backup"
NAME=""; DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -*) die "알 수 없는 옵션: $a  (--dry-run)" ;;
    *) [ -z "$NAME" ] || die "백업 파일은 하나만 줍니다"; NAME=$a ;;
  esac
done
if [ -z "$NAME" ]; then
  say "백업 ($BK — 최근 것부터)"
  found=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue; found=1
    note "$(basename "$f")   $(date -r "$f" '+%F %T')"
  done < <(ls -t "$BK"/kong-before-apply-*.json "$BK"/kong-before-restore-*.json 2>/dev/null | head -15)
  [ "$found" = 1 ] || note "되돌릴 백업이 없습니다 — 설정 적용이 Manager 에서 바꾼 값을 되돌릴 때 만들어집니다"
  note "되돌리기: bash restore-config.sh <파일 이름> --dry-run  (바뀔 것 확인) → bash restore-config.sh <파일 이름>"
  exit 0
fi
NAME=$(basename "$NAME")
[[ "$NAME" =~ ^kong-before-(apply|restore)-[0-9]{8}-[0-9]{6}\.json$ ]] \
  || die "백업 파일 이름은 kong-before-apply-<시각>.json · kong-before-restore-<시각>.json 입니다 — 목록: bash restore-config.sh"
FILE="$BK/$NAME"
[ -f "$FILE" ] || die "백업이 없습니다: $FILE — 목록: bash restore-config.sh"
python3 - "$FILE" <<'PY' || die "백업 파일을 읽지 못했습니다 (kong-poc 태그로 뜬 decK 덤프여야 함): $FILE"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert "kong-poc" in ((d.get("_info") or {}).get("select_tags") or [])
assert not d.get("_workspace") or d["_workspace"] == "default"
PY

say "사전 확인"
kong_up || die "Kong 이 떠 있지 않습니다 — bash start.sh"
license_state
case "$LIC_STATE" in
  valid|grace) note "라이선스 $LIC_MSG" ;;
  *) die "$LIC_MSG — 라이선스가 없거나 유예 기간도 끝나면 Kong 이 읽기 전용이라 되돌릴 수 없습니다" ;;
esac
note "되돌릴 시점: $NAME ($(date -r "$FILE" '+%F %T'))"
DECK=(--kong-addr "http://127.0.0.1:$ADMIN_PORT" --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD")
T=$(mktemp -d); chmod 700 "$T"; trap 'rm -rf "$T"' EXIT

# 바뀔 것 — 값(키 · 주소)은 보이지 않게 만들기 · 바꾸기 · 지우기 줄과 합계만
out=$(deck gateway diff "${DECK[@]}" "$FILE" 2>&1) || { echo "$out" | grep -vi 'key\|secret\|password\|token' | tail -8; die "백업과 지금 설정을 비교하지 못했습니다"; }
say "바뀔 것 (지금 → $NAME)"
grep -E '^(creating|updating|deleting) ' <<<"$out" | sed 's/ *{$//; s/^/  /' | head -60
grep -A3 '^Summary' <<<"$out" | sed 's/^/  /'
if [ "$DRY" = 1 ]; then note "미리 보기만 했습니다 — 되돌리려면 --dry-run 없이"; exit 0; fi
if ! grep -qE '^(creating|updating|deleting) ' <<<"$out"; then note "지금 설정이 이미 백업과 같습니다 — 바꿀 것 없음"; exit 0; fi

# 되돌리기 직전 상태를 남긴다 — 이 파일로 다시 되돌릴 수 있다
mkdir -p "$BK"; NOWF="$BK/kong-before-restore-$(date +%Y%m%d-%H%M%S).json"
deck gateway dump --select-tag kong-poc --format json -o "$NOWF" --yes "${DECK[@]}" >/dev/null 2>&1 && chmod 600 "$NOWF" \
  || die "지금 설정을 백업하지 못해 멈춥니다 — 되돌린 뒤 되돌아올 수 없게 되므로"

# 붙는 곳이 바뀐 이름 있는 플러그인(instance_name)은 먼저 지운다 — 같은 이름으로 새로 만들 때 겹치지 않게 (apply-config.sh 와 같은 방식)
admin '/plugins?size=1000&tags=kong-poc' > "$T/plugins.json"
admin '/services?size=1000' > "$T/services.json"
admin '/routes?size=1000' > "$T/routes.json"
admin '/consumers?size=1000' > "$T/consumers.json"
del=$(python3 - "$T" "$FILE" <<'PY' 2>/dev/null || true
import json, os, sys
t, f = sys.argv[1:3]
load = lambda n: json.load(open(os.path.join(t, n), encoding="utf-8"))
want = json.load(open(f, encoding="utf-8"))
names = {k: {x["id"]: x.get("name") or x.get("username") for x in load(k + ".json")["data"]} for k in ("services", "routes", "consumers")}
def ref(x):
    return (x.get("name") or x.get("username") or x.get("id")) if isinstance(x, dict) else x
desired = {}
def add(p, s=None, r=None, c=None):
    if p.get("instance_name"):
        desired[p["instance_name"]] = (ref(p.get("service")) or s, ref(p.get("route")) or r, ref(p.get("consumer")) or c)
for p in want.get("plugins") or []:
    add(p)
for s in want.get("services") or []:
    for p in s.get("plugins") or []:
        add(p, s=s["name"])
    for r in s.get("routes") or []:
        for p in r.get("plugins") or []:
            add(p, r=r["name"])
for r in want.get("routes") or []:
    for p in r.get("plugins") or []:
        add(p, r=r["name"])
for c in want.get("consumers") or []:
    for p in c.get("plugins") or []:
        add(p, c=c["username"])
for p in load("plugins.json")["data"]:
    n = p.get("instance_name")
    if n in desired:
        cur = tuple(names[k].get((p.get(f) or {}).get("id")) for k, f in (("services", "service"), ("routes", "route"), ("consumers", "consumer")))
        if cur != desired[n]:
            print(p["id"], n)
PY
)
say "되돌리기"
if [ -n "$del" ]; then
  while read -r id _; do admin "/plugins/$id" -X DELETE -o /dev/null; done <<<"$del"
  note "붙는 곳이 바뀐 이름 있는 플러그인 $(wc -l <<<"$del")개를 먼저 지움 (이름 중복 방지): $(awk '{print $2}' <<<"$del" | tr '\n' ' ')"
fi
out=$(deck gateway sync "${DECK[@]}" "$FILE" 2>&1) || { echo "$out" | grep -vi 'key\|secret\|password\|token' | tail -15; die "되돌리지 못했습니다 — 되돌리기 직전 상태: $NOWF"; }
grep -A3 '^Summary' <<<"$out" | sed 's/^/  /'
sleep 6   # traditional 모드는 라우터가 몇 초 안에 새 설정을 읽는다
note "되돌림 완료 — $NAME 시점의 설정 (Kong Manager 에서 확인)"
note "되돌리기 직전 상태: $NOWF (다시 되돌리려면: bash restore-config.sh $(basename "$NOWF"))"
note "되살린 Manager 값은 다음 설정 적용 때 다시 되돌아갑니다 — 적용 전에 apply-dry(bash apply-config.sh --dry-run)로 목록을 확인하세요"
