#!/usr/bin/env bash
# workspace-copy.sh — 팀 워크스페이스: default 의 지금 PoC 설정을 새 워크스페이스에 같게 만든다. default 설정은 읽기만 한다.
#   bash workspace-copy.sh <워크스페이스> [<워크스페이스> …]     만들기 (예: it-infra) — 이 스크립트로 만든 것이 이미 있으면 건너뜀
#   bash workspace-copy.sh --dry-run <워크스페이스> …           무엇이 만들어지는지만 본다
#   bash workspace-copy.sh --reset <워크스페이스> …             이미 만든 것을 default 의 지금 설정으로 다시 맞춘다
#        (복사본을 그 워크스페이스에서 Manager 로 바꾼 값은 되돌아감 · 팀이 Manager 로 직접 만든 것과 계정 키는 그대로)
#   bash workspace-copy.sh --roles default                    default 에 팀 역할만 만든다 — default 를 한 팀(예: Agentic AI팀)이 쓸 때.
#        그 팀 계정에 workspace-admin 을 주면 default 만 다루고, 다른 워크스페이스 · 권한 설정 · 워크스페이스와 라이선스 관리는 403
# 고객 환경(빌드한 새 환경): bash remote.sh workspace-copy [--dry-run | --reset | --roles] <워크스페이스> …  (새 코드는 먼저 bash remote.sh update)
#
# 무엇을 옮기나 — default 에서 kong-poc 태그가 붙은 지금 설정 (Manager 에서 바꾼 LLM 대상 · 스위치와 지운 경로가 그대로 반영된다)
#   경로와 그 플러그인 · 전역 플러그인(요청 로그 · 지표 · 추적 ID · 전처리) · 계정과 그룹(키는 새로 만든다) · 긴급 차단
#   경로는 워크스페이스끼리 같을 수 없어(409) 앞에 워크스페이스 이름을 붙인다: /poc → /<워크스페이스>/poc
#   (경로 이름은 그대로 poc — 전역 전처리 · 차단 문구가 이름으로 고른다)
#   빼는 것: grafana(화면은 Kong 에 하나 — 팀 화면은 설정 GRAFANA_TEAMS) · ai-embed(게이트웨이 안 임베딩 경로 — 복사본도 default 의 것을 부른다)
#            · 경로가 없는 서비스
# 워크스페이스가 없으면 만들고, Kong Manager 가 「New Workspace」 때 만드는 역할 4개를 같은 권한으로 만든다
#   (workspace-admin · workspace-super-admin · workspace-read-only · workspace-portal-admin — Admin API 로만 만들면 역할이 없다)
# 새 계정 키: <유지 폴더>/secrets/workspace-<이름>-keys.txt (600, 「계정 이름 · 키」). 끝에 default 설정을 전후로 비교해 보여 준다.
# Manager 계정은 Teams → Invite Admin 에서 만든다 (메일 서버가 없으니 그 계정의 Generate Registration Link 를 전달 — 3일 유효).
source "$(dirname "$0")/lib.sh"
load_env; native_env

DRY=0; RESET=0; ROLES_ONLY=0; WS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --reset)   RESET=1 ;;
    --roles)   ROLES_ONLY=1 ;;
    -*) die "알 수 없는 옵션: $a  (--dry-run · --reset · --roles)" ;;
    *) [[ "$a" =~ ^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$ ]] || die "워크스페이스 이름은 영문 소문자 · 숫자 · - 로 3~40자: $a"
       WS+=("$a") ;;
  esac
done
[ ${#WS[@]} -gt 0 ] || die "사용법: bash workspace-copy.sh [--dry-run | --reset | --roles] <워크스페이스> [<워크스페이스> …]   (예: it-infra)"
if [ "$ROLES_ONLY" = 0 ]; then
  for ws in "${WS[@]}"; do [ "$ws" != default ] || die "default 는 복사 대상이 아닙니다 — default 에 팀 역할만 만들려면 --roles default"; done
fi

say "사전 확인"
kong_up || die "Kong 이 떠 있지 않습니다 — bash start.sh"
license_state
case "$LIC_STATE" in
  valid|grace) note "라이선스 $LIC_MSG" ;;
  *) die "$LIC_MSG — 라이선스가 없거나 유예 기간도 끝나면 Kong 이 읽기 전용이라 만들 수 없습니다" ;;
esac
DECK=(--kong-addr "http://127.0.0.1:$ADMIN_PORT" --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD")
T=$(mktemp -d); chmod 700 "$T"; trap 'rm -rf "$T"' EXIT
J='Content-Type: application/json'
dump_default() { deck gateway dump --workspace default "${@:2}" --format json -o "$1" --yes "${DECK[@]}" >/dev/null 2>&1; }
dump_default "$T/before-all.json" || die "default 설정을 읽지 못했습니다"
dump_default "$T/default.json" --select-tag kong-poc || die "default 설정을 읽지 못했습니다"
SECRETS="$DATA_DIR/secrets"; mkdir -p "$SECRETS" && chmod 700 "$SECRETS"

# Kong Manager 3.16 이 New Workspace 때 만드는 역할 (Manager 코드 그대로 — 권한 줄의 \${e} 는 워크스페이스 이름)
ROLES='[{"name":"workspace-read-only","comment":"Read access to all endpoints in the workspace","endpoints":[{"actions":"read","endpoint":"*","negative":false}]},{"name":"workspace-super-admin","comment":"Full access to all endpoints in the workspace, except write access to custom-plugins and cloned-plugins","endpoints":[{"actions":"delete,create,update,read","endpoint":"*","negative":false},{"actions":"delete,create,update","endpoint":"/custom-plugins","negative":true},{"actions":"delete,create,update","endpoint":"/cloned-plugins","negative":true},{"actions":"delete,create,update","endpoint":"/custom-plugins/*","negative":true},{"actions":"delete,create,update","endpoint":"/cloned-plugins/*","negative":true}]},{"name":"workspace-admin","comment":"Full access to all endpoints in the workspace, except RBAC Admin API and write access to custom-plugins and cloned-plugins","endpoints":[{"actions":"delete,create,update,read","endpoint":"*","negative":false},{"actions":"delete,create,update,read","endpoint":"groups","negative":true},{"actions":"delete,create,update,read","endpoint":"groups/*","negative":true},{"actions":"delete,create,update,read","endpoint":"admins","negative":true},{"actions":"delete,create,update,read","endpoint":"admins/*","negative":true},{"actions":"delete,create,update,read","endpoint":"rbac/*","negative":true},{"actions":"delete,create,update,read","endpoint":"rbac/*/*","negative":true},{"actions":"delete,create,update,read","endpoint":"rbac/*/*/*","negative":true},{"actions":"delete,create,update,read","endpoint":"rbac/*/*/*/*","negative":true},{"actions":"delete,create,update,read","endpoint":"rbac/*/*/*/*/*","negative":true},{"actions":"delete,create,update","endpoint":"/custom-plugins","negative":true},{"actions":"delete,create,update","endpoint":"/cloned-plugins","negative":true},{"actions":"delete,create,update","endpoint":"/custom-plugins/*","negative":true},{"actions":"delete,create,update","endpoint":"/cloned-plugins/*","negative":true}]},{"name":"workspace-portal-admin","comment":"Full access to Dev Portal related endpoints in the workspace","endpoints":[{"actions":"delete,create,update,read","endpoint":"/developers","negative":false},{"actions":"delete,create,update,read","endpoint":"/developers/*","negative":false},{"actions":"delete,create,update,read","endpoint":"/applications","negative":false},{"actions":"delete,create,update,read","endpoint":"/applications/*","negative":false},{"actions":"delete,create,update,read","endpoint":"/files","negative":false},{"actions":"delete,create,update,read","endpoint":"/files/*","negative":false},{"actions":"delete,create,update,read","endpoint":"/kong","negative":false},{"actions":"update,read","endpoint":"workspaces/${e}","negative":false},{"actions":"delete,create,update,read","endpoint":"groups","negative":true},{"actions":"delete,create,update,read","endpoint":"groups/*","negative":true},{"actions":"delete,create,update,read","endpoint":"admins","negative":true},{"actions":"delete,create,update,read","endpoint":"admins/*","negative":true},{"actions":"delete,create,update,read","endpoint":"rbac/*","negative":true},{"actions":"delete,create,update,read","endpoint":"rbac/*/*","negative":true},{"actions":"delete,create,update,read","endpoint":"rbac/*/*/*","negative":true},{"actions":"delete,create,update,read","endpoint":"rbac/*/*/*/*","negative":true},{"actions":"delete,create,update,read","endpoint":"rbac/*/*/*/*/*","negative":true}]}]'
mkroles() {  # mkroles <워크스페이스> — 없는 역할만 만든다
  local w=$1 n
  python3 -c 'import json,sys; [print(r["name"]) for r in json.loads(sys.argv[1])]' "$ROLES" | while read -r n; do
    [ "$(admin "/$w/rbac/roles/$n" -o /dev/null -w '%{http_code}')" = 200 ] && continue
    python3 - "$ROLES" "$n" "$w" > "$T/role.sh" <<'PY'
import json, shlex, sys
roles, name, ws = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
r = [x for x in roles if x["name"] == name][0]
print("admin " + shlex.quote("/%s/rbac/roles" % ws) + " -X POST -H \"$J\" -o /dev/null -d " + shlex.quote(json.dumps({"name": name, "comment": r["comment"]})))
for e in r["endpoints"]:
    body = {"workspace": ws, "endpoint": e["endpoint"].replace("${e}", ws), "actions": e["actions"], "negative": e["negative"]}
    print("admin " + shlex.quote("/%s/rbac/roles/%s/endpoints" % (ws, name)) + " -X POST -H \"$J\" -o /dev/null -d " + shlex.quote(json.dumps(body)))
PY
    source "$T/role.sh"
    if [ "$w" = default ] && [ "$n" != workspace-read-only ]; then
      # default 범위 역할은 전역 작업(워크스페이스 만들기 · 라이선스)까지 허용된다(3.16 실측: 워크스페이스 만들기 201) — 그 쓰기만 뺀다
      for ep in '/workspaces' '/workspaces/*' '/licenses' '/licenses/*'; do   # 따옴표 — 없으면 셸이 * 를 파일 이름으로 바꾼다
        admin "/default/rbac/roles/$n/endpoints" -X POST -H "$J" -o /dev/null -d "{\"workspace\":\"default\",\"endpoint\":\"$ep\",\"actions\":\"create,update,delete\",\"negative\":true}"
      done
    fi
    note "역할 $n ($(admin "/$w/rbac/roles/$n/endpoints" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("data") or []))')줄)"
  done
}

if [ "$ROLES_ONLY" = 1 ]; then
  for ws in "${WS[@]}"; do
    say "$ws — 역할만"
    [ "$(admin "/workspaces/$ws" -o /dev/null -w '%{http_code}')" = 200 ] || die "워크스페이스가 없습니다: $ws (만들려면 --roles 없이)"
    if [ "$DRY" = 1 ]; then note "없는 역할을 만듭니다: $(python3 -c 'import json,sys; print(" · ".join(r["name"] for r in json.loads(sys.argv[1])))' "$ROLES")"; continue; fi
    mkroles "$ws"
  done
  [ "$DRY" = 1 ] || note "Manager 계정: Teams → Invite Admin → 워크스페이스 ${WS[0]} · 역할 workspace-admin → 그 계정의 Generate Registration Link 를 전달"
  exit 0
fi

for ws in "${WS[@]}"; do
  say "$ws"
  code=$(admin "/workspaces/$ws" -o /dev/null -w '%{http_code}')
  have=0
  if [ "$code" = 200 ]; then
    for t in services consumers plugins; do
      n=$(admin "/$ws/$t?tags=kong-poc&size=1" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("data") or []))' 2>/dev/null); [ "${n:-0}" -gt 0 ] && have=1
    done
  fi
  if [ "$have" = 1 ] && [ "$RESET" = 0 ] && [ "$DRY" = 0 ]; then
    note "이미 이 스크립트로 만든 설정이 있어 건너뜀 — default 의 지금 설정으로 다시 맞추려면 --reset (먼저 --dry-run --reset 으로 볼 것)"; continue
  fi
  KEYS="$SECRETS/workspace-$ws-keys.txt"
  python3 - "$T/default.json" "$ws" "$T/$ws.json" "$KEYS" "$T/$ws.keys" <<'PY' || die "설정을 바꾸지 못했습니다"
import json, os, secrets, string, sys
src, ws, out, keys_path, keys_out = sys.argv[1:6]
SKIP = {"grafana", "ai-embed"}
d = json.load(open(src, encoding="utf-8"))
d["_workspace"] = ws
d.setdefault("_info", {})["select_tags"] = ["kong-poc"]
paths, dropped = [], []
def move(r):
    r["paths"] = [("/" + ws + p) if p.startswith("/") else p for p in (r.get("paths") or [])]
    paths.extend(r["paths"])
svcs = []
for s in d.get("services") or []:
    keep = []
    for r in s.get("routes") or []:
        if r.get("name") in SKIP: dropped.append("경로 " + r["name"]); continue
        move(r); keep.append(r)
    if not keep: dropped.append("서비스 " + s.get("name", "?")); continue
    s["routes"] = keep; svcs.append(s)
d["services"] = svcs
rts = []
for r in d.get("routes") or []:
    if r.get("name") in SKIP: dropped.append("경로 " + r["name"]); continue
    move(r); rts.append(r)
if "routes" in d: d["routes"] = rts
old = {}
if os.path.exists(keys_path):
    for line in open(keys_path, encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if len(p) == 2: old[p[0]] = p[1]
alpha = string.ascii_letters + string.digits
lines = []
for c in d.get("consumers") or []:
    for i, k in enumerate(c.get("keyauth_credentials") or []):
        tag = c["username"] + ("" if i == 0 else "#%d" % (i + 1))
        k["key"] = old.get(tag) or "".join(secrets.choice(alpha) for _ in range(32))
        lines.append(tag + "\t" + k["key"])
json.dump(d, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
open(keys_out, "w", encoding="utf-8").write("".join(l + "\n" for l in lines))
gp = [p["name"] + ("(" + p["instance_name"] + ")" if p.get("instance_name") else "") for p in d.get("plugins") or []]
print("  경로: " + " · ".join(paths))
print("  전역 플러그인: " + " · ".join(gp))
print("  계정: " + " · ".join(c["username"] for c in d.get("consumers") or []) + " (키 " + str(len(lines)) + "개 — " + ("기존 키 그대로" if old else "새로 만듦") + ")")
if dropped: print("  뺀 것: " + " · ".join(dropped))
PY
  if [ "$DRY" = 1 ]; then
    if [ "$code" = 200 ]; then deck gateway diff --workspace "$ws" "${DECK[@]}" "$T/$ws.json" 2>&1 | grep -E '^(creating|updating|deleting)|Summary|Created|Updated|Deleted' | sed 's/^/  /' | tail -12
    else note "워크스페이스가 아직 없어 만들 때 역할 4개와 위 설정이 모두 새로 생깁니다"; fi
    continue
  fi
  if [ "$code" != 200 ]; then
    c=$(admin "/workspaces" -X POST -H "$J" -o "$T/ws.out" -w '%{http_code}' -d "{\"name\":\"$ws\"}")
    [ "$c" = 201 ] || die "워크스페이스를 만들지 못했습니다 ($c): $(head -c 200 "$T/ws.out")"
    note "워크스페이스 만듦"
  fi
  mkroles "$ws"
  out=$(deck gateway sync --workspace "$ws" "${DECK[@]}" "$T/$ws.json" 2>&1) || { echo "$out" | tail -15; die "$ws 에 만들지 못했습니다"; }
  echo "$out" | grep -A3 '^Summary' | sed 's/^/  /'
  install -m 600 "$T/$ws.keys" "$KEYS"
  note "계정 키: $KEYS (계정 이름 · 키) — 부를 때 헤더 apikey: <키>"
done

[ "$DRY" = 1 ] && exit 0
sleep 6   # 라우터가 새 경로를 읽는 시간
say "확인"
for ws in "${WS[@]}"; do
  c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST -H "$J" -d '{"messages":[{"role":"user","content":"ping"}]}' "http://127.0.0.1:$PROXY_PORT/$ws/poc")
  note "$ws — 키 없이 /$ws/poc → $c (키 인증이 켜져 있으면 401)"
done
dump_default "$T/after-all.json" || die "default 설정을 다시 읽지 못했습니다"
if cmp -s "$T/before-all.json" "$T/after-all.json"; then note "default 워크스페이스 — 전후 설정이 같음 (건드리지 않음)"
else note "⚠ default 설정이 그 사이에 바뀌었습니다 — 이 스크립트는 default 에 쓰지 않으니 다른 변경(Manager 등)인지 확인하세요"; fi
note "Manager 계정: Teams → Invite Admin → 워크스페이스·역할(workspace-admin) 고르기 → 그 계정의 Generate Registration Link 를 전달 (메일 서버가 없어서)"
