#!/usr/bin/env bash
# switch.sh — /poc 의 플러그인과 긴급 차단을 바로 켜고 끈다 (Kong Manager 의 스위치와 같음)
#   bash switch.sh                       지금 상태 — /poc 플러그인 스위치 · 긴급 차단
#   bash switch.sh <이름> on|off          예) bash switch.sh pii-masking on · bash switch.sh MASKING off · bash switch.sh kill-switch--poc on
#   이름은 플러그인 이름(pii-masking)이나 설정 파일 스위치 이름(MASKING), 긴급 차단은 kill-switch--<poc·계정·경로>.
#   반영을 기다려(6초) 끝나므로 바로 다음 요청부터 바뀐 상태다.
#   켜 둔 채 bash apply-config.sh 를 하면 /poc 스위치는 설정 파일 FEATURE_… 에 적혀 유지되고, 긴급 차단은 그대로 둔다.
#   빌드한 새 환경이면 개발 파드에서 bash remote.sh switch <이름> on|off
source "$(dirname "$0")/lib.sh"
load_env; native_env
kong_up || die "Kong 이 떠 있지 않습니다 — bash start.sh"

PL=$(admin "/routes/poc/plugins?size=100")
[[ "$PL" == *'"data"'* ]] || die "/poc 경로가 없습니다 — bash apply-config.sh 로 설정을 적용하세요"
ALL=$(admin "/plugins?size=1000")

if [ $# -eq 0 ]; then
  python3 - "$POC_SWITCHES" "$PL" "$ALL" <<'PY'
import json, sys
sw, pl, al = sys.argv[1].split(), json.loads(sys.argv[2])["data"], json.loads(sys.argv[3])["data"]
on = {p["name"]: p["enabled"] for p in pl if not p.get("instance_name")}
print("  /poc 플러그인 스위치 (켬·끔 · 설정 파일 스위치 · 플러그인)")
for s in sw:
    name, _d, plugin = s.split(":")
    if plugin in on:
        print("    %-3s  FEATURE_%-24s %s" % ("켬" if on[plugin] else "끔", name, plugin))
print("  긴급 차단 (켜면 그 대상의 호출이 모두 막힘 · 설정을 다시 적용해도 그대로)")
for p in sorted((p for p in al if (p.get("instance_name") or "").startswith("kill-switch--")), key=lambda p: p["instance_name"]):
    print("    %-3s  %s" % ("켬" if p["enabled"] else "끔", p["instance_name"]))
PY
  exit 0
fi

[ $# -eq 2 ] || die "사용법: bash switch.sh <이름> on|off   (목록: bash switch.sh)"
name=$1; st=$2
case "$st" in on|off) ;; *) die "on 또는 off 로 — bash switch.sh $name on" ;; esac
for f in $POC_SWITCHES; do [ "${f%%:*}" = "${name^^}" ] && name=${f##*:}; done   # MASKING → pii-masking
id=$(python3 - "$name" "$POC_SWITCHES" "$PL" "$ALL" <<'PY'
import json, sys
name, sw = sys.argv[1], [s.split(":")[2] for s in sys.argv[2].split()]
pl, al = json.loads(sys.argv[3])["data"], json.loads(sys.argv[4])["data"]
if name.startswith("kill-switch--"):          # 긴급 차단 — 경로·계정 어디에 붙어 있든
    hit = [p for p in al if p.get("instance_name") == name]
elif name in sw:                               # /poc 플러그인 스위치만 (LLM 연결 등 다른 플러그인은 바꾸지 않음)
    hit = [p for p in pl if p["name"] == name and not p.get("instance_name")]
else:
    hit = []
print(hit[0]["id"] if hit else "")
PY
)
[ -n "$id" ] || die "켜고 끌 수 있는 이름이 아닙니다: $1 — 목록은 bash switch.sh"
c=$(admin "/plugins/$id" -X PATCH -H 'Content-Type: application/json' \
      -d "{\"enabled\":$([ "$st" = on ] && echo true || echo false)}" -o /dev/null -w '%{http_code}')
[ "$c" = 200 ] || die "바꾸지 못했습니다 (Admin API HTTP $c)"
sleep 6   # Kong 이 바뀐 설정을 읽는 주기(최대 약 5초)
note "$name → $([ "$st" = on ] && echo 켬 || echo 끔) (반영됨)"
