#!/usr/bin/env bash
# apply-config.sh — 요구사항별 Kong 설정(conf/*.yaml)을 적용한다 (decK).
#   bash apply-config.sh                 적용 — 여러 번 실행해도 안전 (바뀐 것만 반영)
#   bash apply-config.sh --dry-run       무엇이 바뀌는지만 본다 (적용하지 않음)
#
# 채팅 경로는 /poc 하나다. 요구사항 플러그인을 모두 붙여 두고 설정 파일의 FEATURE_…=on/off 로 켜고 끈다
# (bash set-env.sh FEATURE_… on — 처음에는 키 인증만 켬).
# Kong Manager 와 같이 쓸 때 — /poc 스위치와 긴급 차단(kill-switch--…)은 Manager 에서 켜고 꺼도 된다:
#   적용할 때 지난 적용 뒤 Manager 에서 바꾼 스위치는 설정 파일에 적어 유지하고, 긴급 차단은 지금 상태 그대로 둔다.
#   그 밖의 값(한도·패턴 등)은 설정 파일 기준이다 — Manager 에서 바꾼 값은 되돌아가며, 적용 전에 그 목록을 보여 준다.
# 설정 파일에 값이 있는 항목만 들어간다 (LLM·Azure·GCP·AWS·SSO·추적·중앙 로그·임베딩).
# kong-poc 태그가 붙은 것만 관리하므로 Kong Manager 에서 직접 만든 설정은 건드리지 않는다.
source "$(dirname "$0")/lib.sh"
load_env; native_env

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run)     DRY=1 ;;
    *) die "알 수 없는 옵션: $a  (--dry-run)" ;;
  esac
done

say "사전 확인"
kong_up || die "Kong 이 떠 있지 않습니다 — bash start.sh"
license_state
case "$LIC_STATE" in
  valid|grace) note "라이선스 $LIC_MSG" ;;
  *) die "$LIC_MSG.
  라이선스가 없거나 유예 기간도 끝나면 Kong 이 읽기 전용이라 설정을 적용할 수 없습니다.
  bash set-license.sh <라이선스 파일> 로 넣고 bash stop.sh && bash start.sh 후 다시 실행하세요." ;;
esac
# 2-2 접근 통제를 보려면 부서 키가 둘 필요하다 — 두 번째 키가 없으면 만들어 설정 파일에 적는다
if [ -z "${DECK_CLIENT_KEY_B:-}" ]; then
  DECK_CLIENT_KEY_B=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')
  env_set DECK_CLIENT_KEY_B "$DECK_CLIENT_KEY_B" "$ENV_FILE" || die "설정 파일에 쓰지 못했습니다: $ENV_FILE"
  note "team-b 사용자 키를 만들어 설정 파일에 적었습니다 (DECK_CLIENT_KEY_B · $ENV_FILE)"
fi

# ── Kong Manager 에서 바꾼 것 ─────────────────────────────────────────
#  기준은 지난 적용 직후의 Kong 상태(데이터 폴더 state/applied.json, 600). 지금 상태와 비교해
#   · /poc 스위치: Manager 에서 바꿨으면 설정 파일에 적어 유지 · 지난 적용 뒤 설정 파일에서 바꿨으면 설정 파일 값
#   · 긴급 차단: 지금 상태 그대로 (적용해도 차단이 풀리지 않게)
#   · 그 밖의 값: 설정 파일 기준이라 되돌아감 — 목록을 보여 주고, 되돌리기 전 상태를 backup/ 에 남긴다
DECK=(--kong-addr "http://127.0.0.1:$ADMIN_PORT" --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD")
STATE_DIR="$DATA_DIR/state"; mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
kdump() { deck gateway dump --select-tag kong-poc --format json -o "$1" --yes "${DECK[@]}" >/dev/null 2>&1 && chmod 600 "$1"; }
if [ -f "$(verify_restore_file)" ]; then   # Manager 에서 바꾼 것으로 오해하지 않게 먼저
  verify_restore; note "지난 점검(verify.sh)이 중간에 끊겨 바뀐 채 남은 /poc 플러그인을 먼저 되돌렸습니다"
fi
NOW="$STATE_DIR/now.json"; WANT="$STATE_DIR/want.json"; trap 'rm -f "$NOW" "$WANT"' EXIT   # want = 이번에 적용할 설정(키 포함)
kdump "$NOW" || die "지금 Kong 설정을 읽지 못했습니다 — 긴급 차단 상태를 모른 채 적용하면 차단이 풀릴 수 있어 멈춥니다"
ADOPT=(); FIRST=(); KILLED=()
while IFS= read -r l; do
  case "$l" in
    "SW "*)
      read -r _ n kv bv <<<"$l"; sv=$(switch_value "$n")
      if [ "$bv" = - ]; then [ "$kv" != "$sv" ] && FIRST+=("$n")
      elif [ "$kv" != "$bv" ] && [ "$sv" = "$bv" ]; then ADOPT+=("$n=$kv"); printf -v "FEATURE_$n" '%s' "$kv"; fi ;;   # 설정 파일을 바꿨으면 그 값
    "KILL "*)
      read -r _ n st <<<"$l"; printf -v "$(kill_var "$n")" '%s' "$([ "$st" = on ] && echo true || echo false)"
      [ "$st" = on ] && KILLED+=("kill-switch--$n") ;;
  esac
done < <(python3 "$ROOT/manager-changes.py" "$STATE_DIR/applied.json" "$NOW" "$POC_SWITCHES" "$KILL_SWITCHES" 2>/dev/null)
if [ "$DRY" = 0 ]; then
  for a in "${ADOPT[@]}"; do env_set "FEATURE_${a%%=*}" "${a#*=}" "$ENV_FILE" || die "설정 파일에 쓰지 못했습니다: $ENV_FILE"; done
fi
[ ${#ADOPT[@]} -gt 0 ] && note "Kong Manager 에서 켜고 끈 /poc 스위치를 설정 파일에 $([ "$DRY" = 1 ] && echo '적을 예정(미리 보기)' || echo '적었습니다'): ${ADOPT[*]}"
[ ${#FIRST[@]} -gt 0 ] && note "지난 적용 기록이 없어 설정 파일 값으로 맞춥니다: ${FIRST[*]} (다음부터는 Manager 에서 바꾼 스위치를 유지)"
[ ${#KILLED[@]} -gt 0 ] && note "긴급 차단이 켜져 있어 그대로 둡니다: ${KILLED[*]} (풀려면 Kong Manager 에서 끄세요)"
deck_env

files=(conf/00-base.yaml conf/10-poc.yaml)
row() { printf '  %s %-26s %s\n' "$1" "$2" "$3"; }
opt() {  # 파일 조건값 설명 없을때-이유
  if [ -n "$2" ]; then files+=("conf/$1.yaml"); row O "$1" "$3"; else row - "$1" "$4"; fi
}

say "적용할 설정"
row O 00-base "사용자·키·그룹 · 요청 로그 · 추적 ID · 지표 · 계정 긴급 차단 · /poc 공통 전처리"
row O 10-poc  "/poc — 채팅 경로 하나에 요구사항 플러그인을 모두 붙임 (켜짐·꺼짐은 아래 스위치)"

# /poc 의 LLM 대상(AI Proxy Advanced) — 설정 파일의 LLM 값으로 만든다 (lib.sh 의 select_models 와 같은 규칙)
#   기본(요청에 model 이 없거나 등록되지 않은 이름): 1순위 사내 LLM → 장애 시 2순위(외부 LLM, FALLBACK=azure 면 Azure)
#                                                   LLM 을 아직 넣지 않았으면 모의 LLM(mock-llm → 장애 시 backup-model)
#   model 로 고름: LLM 마다(model_alias = 모델 이름) · Azure·GCP·AWS · 시험용 mock-llm(mock-llm → 장애 시 backup-model)
#   Kong 3.16 실측: 별칭 없는 대상끼리 기본 묶음, 별칭마다 따로 묶임 — 이름을 지정한 요청은 그 묶음 안에서만 장애 대체
gen="$RUN_DIR/11-targets.yaml"
while read -r n uv mv av; do
  [ -n "$n" ] || continue
  if llm_connected "$uv" && [ -z "${!mv:-}" ]; then die "$mv 가 비어 있습니다 — LLM $n 의 모델 이름을 넣으세요 (bash set-env.sh $mv)"; fi
done <<<"$(llm_list)"
LLM_LIST="$(llm_list)" python3 - "$gen" <<'PY' || die "LLM 대상을 만들지 못했습니다"
import os, sys
E = os.environ
env = lambda v: '${{ env "%s" }}' % v
connected = lambda uv: bool(E.get(uv)) and "example" not in E.get(uv, "")
out = ['_format_version: "3.0"', "_info:", "  select_tags:", "    - kong-poc", "plugins:",
       "  - name: ai-proxy-advanced", "    route: poc", "    config:",
       '      response_streaming: ${{ env "DECK_LLM_STREAMING" }}   # 답변 검사(4-4·4-5) 스위치를 켜면 deny',
       "      max_request_body_size: 8388608",
       "      model_name_header: true           # 응답 헤더 X-Kong-LLM-Model 로 실제로 답한 모델을 알려 준다",
       "      balancer:",
       "        algorithm: priority             # weight 가 큰 대상부터. 실패하면 다음 순위로 (1-4)",
       "        failover_criteria: [error, timeout, non_idempotent, http_429, http_500, http_502, http_503, http_504]",
       "        retries: 2", "        connect_timeout: 5000", "        read_timeout: 300000", "        write_timeout: 60000",
       "      targets:"]
def target(desc, weight, auth, model):
    out.extend(["        - description: " + desc, "          weight: %d" % weight, "          route_type: llm/v1/chat",
                "          auth:"] + ["            " + l for l in auth] +
               ["          logging:", "            log_statistics: true", "            log_payloads: false", "          model:"] +
               ["            " + l for l in model])
def vault(var): return '"{vault://env/%s}"' % var.lower().replace("_", "-")
def openai(namev, urlv, alias, prefix):
    m = ["provider: openai", "name: " + env(namev)] + (["model_alias: " + env(namev)] if alias else []) + ["options:", "  upstream_url: " + env(urlv)]
    for k in ("INPUT_COST", "OUTPUT_COST"):
        if E.get(prefix + k): m.append("  %s: %s" % (k.lower(), E[prefix + k]))
    return m
def mock(name, alias, weight, desc):
    m = ["provider: openai", "name: " + name] + (["model_alias: mock-llm"] if alias else []) + \
        ["options:", '  upstream_url: ${{ env "DECK_MOCK_URL" }}/v1/chat/completions', "  input_cost: 1000", "  output_cost: 2000"]
    target(desc, weight, ["header_name: Authorization", 'header_value: "Bearer mock"'], m)
def azure(alias):
    target("Azure OpenAI" + (" — model 로 지정" if alias else " (2순위)"), 100 if alias else 10, ["header_name: api-key", 'header_value: "{vault://env/azure-api-key}"'],
           ["provider: azure", "name: " + env("DECK_AZURE_DEPLOYMENT")] + (["model_alias: " + env("DECK_AZURE_DEPLOYMENT")] if alias else []) +
           ["options:", "  azure_instance: " + env("DECK_AZURE_INSTANCE"), "  azure_deployment_id: " + env("DECK_AZURE_DEPLOYMENT"),
            "  azure_api_version: " + env("DECK_AZURE_API_VERSION")])
prefix = {"DECK_CHAT_URL": "DECK_CHAT_", "DECK_EXT_URL": "DECK_EXT_"}
llms = [l.split() for l in E["LLM_LIST"].splitlines() if l.strip()]
llms = [x for x in llms if connected(x[1])]
first = llms[0] if llms and llms[0][1] == "DECK_CHAT_URL" else None
fb = E.get("FALLBACK", "auto")
out.append("        # ── 기본 — 요청에 model 이 없거나 등록되지 않은 이름 ──")
if first:
    target("사내 LLM (1순위)", 100, ["header_name: Authorization", "header_value: " + vault(first[3])], openai(first[2], first[1], False, "DECK_CHAT_"))
    if fb == "azure" and E.get("DECK_AZURE_INSTANCE"):
        azure(False)
    elif fb != "none" and any(x[1] == "DECK_EXT_URL" for x in llms):
        target("외부 LLM (2순위 — 사내 LLM 장애 시)", 10, ["header_name: Authorization", 'header_value: "{vault://env/ext-auth-header}"'],
               openai("DECK_EXT_MODEL", "DECK_EXT_URL", False, "DECK_EXT_"))
else:
    mock("mock-llm", False, 100, "모의 LLM (LLM 을 넣기 전 기본 — 1순위)")
    mock("backup-model", False, 10, "모의 보조 모델 (2순위)")
out.append("        # ── 요청의 model 로 고름 (model_alias = 모델 이름) ──")
for n, uv, mv, av in llms:
    target("LLM %s — model 로 지정" % n, 100, ["header_name: Authorization", "header_value: " + vault(av)],
           openai(mv, uv, True, prefix.get(uv, "DECK_LLM%s_" % n)))
if E.get("DECK_AZURE_INSTANCE"):
    azure(True)
if E.get("DECK_GCP_PROJECT"):
    target("GCP Vertex — model 로 지정", 100, ["gcp_use_service_account: true", 'gcp_service_account_json: "{vault://env/gcp-service-account-json}"'],
           ["provider: gemini", "name: " + env("DECK_GCP_MODEL"), "model_alias: " + env("DECK_GCP_MODEL"), "options:", "  gemini:",
            "    api_endpoint: " + env("DECK_GCP_LOCATION") + "-aiplatform.googleapis.com", "    project_id: " + env("DECK_GCP_PROJECT"),
            "    location_id: " + env("DECK_GCP_LOCATION")])
if E.get("DECK_AWS_REGION"):
    target("AWS Bedrock — model 로 지정", 100, ['aws_access_key_id: "{vault://env/aws-access-key-id}"', 'aws_secret_access_key: "{vault://env/aws-secret-access-key}"'],
           ["provider: bedrock", "name: " + env("DECK_AWS_MODEL"), "model_alias: " + env("DECK_AWS_MODEL"), "options:", "  bedrock:",
            "    aws_region: " + env("DECK_AWS_REGION")])
out.append("        # ── 시험용 mock-llm — 결과가 늘 같은 모의 LLM. 요청 헤더 X-Mock-Down: mock-llm 이면 주 모델이 503 → backup-model (1-4) ──")
mock("mock-llm", True, 100, "시험용 모의 LLM (주 모델)")
mock("backup-model", True, 10, "시험용 모의 보조 모델 (주 모델 장애 시)")
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
files+=("$gen")
row O "LLM 대상" "기본: $(if llm_connected DECK_CHAT_URL; then echo "사내 LLM $DECK_CHAT_MODEL$( [ "${FALLBACK:-auto}" != none ] && [ -n "${DECK_EXT_URL:-}" ] && echo " → 장애 시 $DECK_EXT_MODEL")"; else echo "모의 LLM (LLM 미연결)"; fi)"
row O "모델 선택" "요청의 model 로 고름 — ${DECK_SELECT_MODELS//,/ · }"
row O 40-ocr-agents "OCR·Agent (주소: ${DECK_OCR_URL%/ocr}…)"
files+=(conf/40-ocr-agents.yaml)
opt 50-sso      "${DECK_OIDC_ISSUER:-}"   "/poc 에 사내 SSO(OIDC) — 스위치 FEATURE_SSO" "DECK_OIDC_ISSUER 없음"
opt 60-otel     "${DECK_OTEL_ENDPOINT:-}" "분산 추적 → ${DECK_OTEL_ENDPOINT:-}"   "DECK_OTEL_ENDPOINT 없음"
opt 61-http-log "${DECK_LOG_HTTP_URL:-}"  "중앙 로그 → ${DECK_LOG_HTTP_URL:-}"     "DECK_LOG_HTTP_URL 없음"
EMB=""; [ -n "${DECK_EMBED_URL:-}" ] && [ -n "${DECK_EMBED_MODEL:-}" ] && EMB=1
opt 70-semantic "$EMB" "/poc 에 의미 기반 가드(질문·답변)·시맨틱 캐시" "임베딩 모델 없음 (DECK_EMBED_URL·DECK_EMBED_MODEL)"
MON=""; mon_on && MON=1
opt 80-monitoring "$MON" "모니터링 화면 /grafana — Prometheus · Grafana (3-3)" "MONITORING=off"

say "/poc 플러그인 스위치 (설정 파일의 FEATURE_… · Kong Manager 에서 켜고 끈 것은 적용할 때 여기에 적어 유지)"
sw() {
  local v="DECK_ON_$1" m=""
  [[ " ${ADOPT[*]} " = *" $1="* ]] && m="  ← Kong Manager 에서 바꿈"
  printf '  %-4s %-26s %s%s\n' "$([ "${!v}" = true ] && echo 켬 || echo 끔)" "$1" "$2" "$m"
}
sw KEY_AUTH       "2-1 부서 키 (key-auth)"
[ -n "${DECK_OIDC_ISSUER:-}" ] && sw SSO "2-1 사내 SSO (openid-connect)"
sw ACL            "2-2 허용 그룹만 (acl)"
sw RATE_LIMIT     "2-3 호출 수 — 분당 $DECK_RPM · 일 $DECK_RPD (rate-limiting)"
sw TOKEN_LIMIT    "2-4 토큰 — 분당 $DECK_TPM (ai-rate-limiting-advanced)"
sw MASKING        "4-1 개인정보 마스킹 (pii-masking)"
sw PROMPT_GUARD   "4-2·4-3 기밀 키워드·인젝션 (ai-prompt-guard)"
sw OUTPUT_GUARD   "4-4 유해 답변 → 표준 문구 (ai-custom-guardrail) — 켜면 스트리밍 꺼짐"
sw OUTPUT_MASK    "4-5 답변 속 내부 정보 가림 (response-masking) — 켜면 스트리밍 꺼짐"
if [ -n "$EMB" ]; then
  sw SEMANTIC_GUARD          "4-3 의미 기반 질문 가드 (ai-semantic-prompt-guard)"
  sw SEMANTIC_RESPONSE_GUARD "4-4 의미 기반 답변 가드 (ai-semantic-response-guard) — 켜면 스트리밍 요청에도 한 번에 답함"
  sw SEMANTIC_CACHE          "시맨틱 캐시 (ai-semantic-cache)"
fi
note "긴급 차단(3-4)은 Kong Manager 에서 kill-switch--poc · kill-switch--<계정> 을 켠다 (평소 꺼 둠 · 적용해도 지금 상태 그대로)"

# LLM 주소가 IP 면 이름으로 바꿔 넘긴다 (lib.sh 의 ai_url — Kong 3.16 AI 플러그인은 IP 주소로는 장애 대체가 안 됨)
AENV=(); for v in $(ai_url_vars); do AENV+=("$v=$(ai_url "${!v:-}")"); done

# 이름(instance_name)이 있는 플러그인의 붙는 곳(서비스·경로·계정)이 바뀌면 decK 는 새것을 먼저 만들다가
# 이름 중복(409 UNIQUE)으로 멈춘다 — 그런 플러그인만 골라 「id 이름」 줄로 낸다 (예: 서비스 → 경로로 옮긴 2026-10 판)
moved_named() {
  local t; t=$(mktemp -d)
  env "${AENV[@]}" deck file render --populate-env-vars --format json "${files[@]}" > "$t/want.json" 2>/dev/null \
    || { rm -rf "$t"; return 0; }
  admin '/plugins?size=1000&tags=kong-poc' > "$t/plugins.json"
  admin '/services?size=1000' > "$t/services.json"
  admin '/routes?size=1000' > "$t/routes.json"
  admin '/consumers?size=1000' > "$t/consumers.json"
  python3 - "$t" <<'PY' 2>/dev/null || true
import json, os, sys
t = sys.argv[1]
load = lambda n: json.load(open(os.path.join(t, n), encoding="utf-8"))
want = load("want.json")
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
  rm -rf "$t"
}

# Manager 에서 바꾼 그 밖의 값 — 이번에 적용할 값과 다른 것만 (설정 파일에 이미 옮긴 값은 유지되므로 빠진다)
VALS=()
if env "${AENV[@]}" deck file render --populate-env-vars --format json "${files[@]}" > "$WANT" 2>/dev/null; then
  chmod 600 "$WANT"
  while IFS= read -r l; do VALS+=("${l#VAL }"); done < <(python3 "$ROOT/manager-changes.py" "$STATE_DIR/applied.json" "$NOW" \
    "$POC_SWITCHES" "$KILL_SWITCHES" "$WANT" 2>/dev/null | grep '^VAL ')
fi
if [ ${#VALS[@]} -gt 0 ]; then
  say "Kong Manager 에서 바꾼 값 ${#VALS[@]}개 — 설정 파일 기준이라 $([ "$DRY" = 1 ] && echo '적용하면' || echo '이번 적용으로') 되돌아감 (지난 적용 값 → 지금 값)"
  bk=""
  if [ "$DRY" = 0 ]; then
    mkdir -p "$DATA_DIR/backup"; bk="$DATA_DIR/backup/kong-before-apply-$(date +%Y%m%d-%H%M%S).json"
    cp "$NOW" "$bk" && chmod 600 "$bk"
  fi
  for v in "${VALS[@]:0:20}"; do note "· $v"; done
  [ ${#VALS[@]} -gt 20 ] && note "· … 외 $(( ${#VALS[@]} - 20 ))개"
  note "계속 쓰려면 그 값을 설정 파일(bash set-env.sh — 키가 있는 값은 위에 명령을 적었음)이나 conf/*.yaml 에 옮긴 뒤 적용하세요"
  [ -n "$bk" ] && note "되돌리기 전 상태: $bk"
fi

if [ "$DRY" = 1 ]; then
  say "바뀔 내용 (적용하지 않음)"
  del=$(moved_named)
  if [ -n "$del" ]; then
    note "붙는 곳이 바뀐 이름 있는 플러그인 $(wc -l <<<"$del")개는 적용할 때 먼저 지우고 새로 만듭니다 (이름 중복 방지):"
    note "  $(awk '{print $2}' <<<"$del" | tr '\n' ' ')"
  fi
  env "${AENV[@]}" deck gateway diff "${DECK[@]}" "${files[@]}"
  exit 0
fi

say "적용"
# 그 이름을 Kong 이 읽는 hosts 파일에 적는다 — 바뀌었거나 지금 Kong 이 그 파일을 안 읽었으면 끊김 없이 다시 읽힌다(reload)
loaded=0; grep -qxF "dns_hostsfile = $RUN_DIR/hosts" "$KONG_PREFIX/.kong_env" 2>/dev/null && loaded=1
if kong_hosts || [ "$loaded" = 0 ]; then
  kong_env; kong reload -p "$KONG_PREFIX" >/dev/null 2>&1 || die "Kong reload 실패 ($LOGS/kong-error.log)"
  sleep 3; note "LLM 주소의 IP 에 붙인 이름을 Kong 에 반영 ($RUN_DIR/hosts)"
fi
del=$(moved_named)
if [ -n "$del" ]; then   # 바로 아래 sync 가 같은 이름으로 새로 만든다 — 그 사이 몇 초만 빈다
  while read -r id _; do admin "/plugins/$id" -X DELETE -o /dev/null; done <<<"$del"
  note "붙는 곳이 바뀐 이름 있는 플러그인 $(wc -l <<<"$del")개를 먼저 지움 (이름 중복 방지): $(awk '{print $2}' <<<"$del" | tr '\n' ' ')"
fi
out=$(env "${AENV[@]}" deck gateway sync "${DECK[@]}" "${files[@]}" 2>&1) || { echo "$out" | tail -15; die "적용 실패"; }
echo "$out" | grep -A3 '^Summary' | sed 's/^/  /'
# 다음 적용 때 Kong Manager 에서 바꾼 것을 알아보는 기준
kdump "$STATE_DIR/applied.json" || note "적용 결과를 기록하지 못했습니다 — 다음 적용 때 Manager 에서 바꾼 스위치를 알아보지 못할 수 있음"
sleep 6   # traditional 모드는 라우터가 몇 초 안에 새 설정을 읽는다
note "적용 완료 — bash verify.sh 로 요구사항별 점검"
