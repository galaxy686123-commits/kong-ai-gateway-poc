#!/usr/bin/env bash
# apply-config.sh — 요구사항별 Kong 설정(conf/*.yaml)을 적용한다 (decK).
#   bash apply-config.sh                 적용 — 여러 번 실행해도 안전 (바뀐 것만 반영)
#   bash apply-config.sh --dry-run       무엇이 바뀌는지만 본다 (적용하지 않음)
#   bash apply-config.sh --no-areas      영역별 시험 경로(/poc/1~4)를 빼고 적용 (이미 있으면 지운다)
#
# 통합 경로 /v1/chat/completions 의 기능은 설정 파일의 FEATURE_…=on/off 로 켜고 끈다 (bash set-env.sh FEATURE_… on).
# 설정 파일에 값이 있는 항목만 들어간다 (외부 LLM·Azure·GCP·AWS·SSO·추적·중앙 로그·임베딩).
# kong-poc 태그가 붙은 것만 관리하므로 Kong Manager 에서 직접 만든 설정은 건드리지 않는다.
source "$(dirname "$0")/lib.sh"
load_env; native_env

DRY=0; FEAT=1
for a in "$@"; do
  case "$a" in
    --dry-run)     DRY=1 ;;
    --no-areas|--no-features) FEAT=0 ;;   # --no-features 는 예전 이름
    *) die "알 수 없는 옵션: $a  (--dry-run · --no-areas)" ;;
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
deck_env

files=(conf/00-base.yaml conf/10-llm.yaml conf/12-select.yaml conf/40-ocr-agents.yaml)
row() { printf '  %s %-26s %s\n' "$1" "$2" "$3"; }
opt() {  # 파일 조건값 설명 없을때-이유
  if [ -n "$2" ]; then files+=("conf/$1.yaml"); row O "$1" "$3"; else row - "$1" "$4"; fi
}

say "적용할 설정"
row O 00-base "사용자·키·그룹 · 요청 로그 · 추적 ID · 지표 · 계정 긴급 차단 · 개인정보 마스킹"
row O 10-llm  "통합 경로 /v1/chat/completions (기능은 아래 스위치)"
# 통합 경로가 부를 LLM — 장애 대체 대상
FB="${FALLBACK:-auto}"
if [ "$FB" = azure ] && [ -n "${DECK_AZURE_INSTANCE:-}" ]; then
  files+=(conf/11-target-fallback-azure.yaml); row O 11-target-fallback-azure "사내 LLM → Azure 장애 대체"
elif [ "$FB" != none ] && [ -n "${DECK_EXT_URL:-}" ]; then
  files+=(conf/11-target-fallback.yaml); row O 11-target-fallback "사내 LLM → 외부 LLM 장애 대체"
else
  files+=(conf/11-target-single.yaml); row O 11-target-single "사내 LLM (장애 대체 없음)"
fi
# 요청의 model 로 LLM 고르기 — OpenAI 호환 LLM 이 둘 이상이면, 위 대상 파일 끝에 모델마다 대상(model_alias)을 붙인 사본을 쓴다.
#  model 이 없거나 목록에 없는 이름이면 위 파일의 기본 대상(1순위 사내 → 장애 시 2순위)으로 간다 (chat-preprocess 가 다른 이름을 지움).
#  Kong 3.16 실측: 별칭 없는 대상끼리 기본 묶음, 별칭마다 따로 묶임 — 이름을 지정한 요청은 그 LLM 이 실패해도 다른 LLM 으로 안 넘어간다.
if [ "$DECK_MODEL_SELECT" = true ]; then
  ti=$(( ${#files[@]} - 1 )); gen="$RUN_DIR/11-targets-select.yaml"; shown=""
  { cat "${files[$ti]}"
    while read -r n uv mv av; do
      [ -n "$n" ] || continue
      [ -n "${!mv:-}" ] || die "$mv 가 비어 있습니다 — LLM $n 의 모델 이름을 넣으세요 (bash set-env.sh $mv)"
      shown="${shown:+$shown · }${!mv}"
      cat <<EOF
            - description: LLM $n — 요청의 model 이 이 이름일 때
              weight: 100
              route_type: llm/v1/chat
              auth:
                header_name: Authorization
                header_value: "{vault://env/$(printf '%s' "$av" | tr 'A-Z_' 'a-z-')}"
              logging:
                log_statistics: true
                log_payloads: false
              model:
                provider: openai
                name: \${{ env "$mv" }}
                model_alias: \${{ env "$mv" }}
                options:
                  upstream_url: \${{ env "$uv" }}
EOF
    done <<<"$(llm_list)"
  } > "$gen"
  files[$ti]=$gen
  row O "모델 선택" "요청의 model 로 고름 — $shown"
fi
row O 12-select "x-ai-target: internal"
opt 12-select-external "${DECK_EXT_URL:-}"       "x-ai-target: external" "DECK_EXT_URL 없음"
opt 13-llm-azure       "${DECK_AZURE_INSTANCE:-}" "x-ai-target: azure"    "DECK_AZURE_INSTANCE 없음"
opt 14-llm-gcp         "${DECK_GCP_PROJECT:-}"    "x-ai-target: gcp"      "DECK_GCP_PROJECT 없음"
opt 15-llm-aws         "${DECK_AWS_REGION:-}"     "x-ai-target: aws"      "DECK_AWS_REGION 없음"
F=""; [ "$FEAT" = 1 ] && mock_running && pii_running && F=1
opt 20-areas "$F" "영역별 시험 경로 /poc/1~4 — ①연동 ②접근·사용량 ③이력·감사 ④가드레일 (LLM: ${FEATURE_UPSTREAM:-mock})" \
    "$([ "$FEAT" = 0 ] && echo '--no-areas' || echo '모의 서버·PII 가드가 떠 있지 않음 (bash start.sh)')"
row O 40-ocr-agents "OCR·Agent (주소: ${DECK_OCR_URL%/ocr}…)"
opt 50-sso      "${DECK_OIDC_ISSUER:-}"   "/sso — 사내 SSO(OIDC) 토큰으로 호출" "DECK_OIDC_ISSUER 없음"
opt 60-otel     "${DECK_OTEL_ENDPOINT:-}" "분산 추적 → ${DECK_OTEL_ENDPOINT:-}"   "DECK_OTEL_ENDPOINT 없음"
opt 61-http-log "${DECK_LOG_HTTP_URL:-}"  "중앙 로그 → ${DECK_LOG_HTTP_URL:-}"     "DECK_LOG_HTTP_URL 없음"
EMB=""; [ -n "${DECK_EMBED_URL:-}" ] && [ -n "${DECK_EMBED_MODEL:-}" ] && EMB=1
opt 70-semantic "$EMB" "의미 기반 가드·시맨틱 캐시" "임베딩 모델 없음 (DECK_EMBED_URL·DECK_EMBED_MODEL)"
FS=""; [ -n "$EMB" ] && [ -n "$F" ] && FS=1
opt 21-areas-semantic "$FS" "영역 ④ 의미 기반 가드 — 질문(4-3)·답변(4-4)" \
    "$([ -z "$EMB" ] && echo '임베딩 모델 없음' || echo '영역별 시험 경로 없음')"

say "통합 경로 기능 스위치 (설정 파일의 FEATURE_…)"
sw() { local v="DECK_ON_$1"; printf '  %-4s %-16s %s\n' "$([ "${!v}" = true ] && echo 켬 || echo 끔)" "$1" "$2"; }
sw MASKING      "4-1 개인정보 마스킹 (모든 채팅 경로)"
sw ACL          "2-2 허용 그룹만"
sw RATE_LIMIT   "2-3 호출 수 (분당 $DECK_RPM · 일 $DECK_RPD)"
sw TOKEN_LIMIT  "2-4 토큰 (분당 $DECK_TPM)"
sw PROMPT_GUARD "4-2·4-3 기밀 키워드·인젝션"
sw OUTPUT_GUARD "4-4 유해 답변 → 표준 문구 (켜면 스트리밍 꺼짐)"
sw OUTPUT_MASK  "4-5 답변 속 시스템 정보 마스킹 (켜면 스트리밍 꺼짐)"
if [ -n "$EMB" ]; then
  sw SEMANTIC_GUARD "4-3 의미 기반 가드"
  sw SEMANTIC_CACHE "시맨틱 캐시"
fi

DECK=(--kong-addr "http://127.0.0.1:$ADMIN_PORT" --headers "Kong-Admin-Token:$KONG_ADMIN_PASSWORD")
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
sleep 6   # traditional 모드는 라우터가 몇 초 안에 새 설정을 읽는다
note "적용 완료 — bash verify.sh 로 요구사항별 점검"
