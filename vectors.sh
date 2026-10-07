#!/usr/bin/env bash
# vectors.sh — Kong 이 벡터 DB(kong-pgvector)에 넣은 것 보기 (읽기만 한다)
#   bash vectors.sh                    표마다 무엇이 들어 있나 — 시맨틱 캐시(저장된 답) · 의미 기반 질문·답변 가드(막을 예문)
#   bash vectors.sh --query '문장'      그 문장을 임베딩해 표마다 가장 가까운 것 3개와 거리 — 막히는지·캐시가 맞는지 미리 보기
#   빌드한 새 환경이면 개발 파드에서 bash remote.sh vectors ['문장']
# 표는 /poc 의 의미 기반 플러그인마다 하나다(이름 끝 = 플러그인 ID). 플러그인이 처음 쓰일 때 Kong 이 만든다.
# 시맨틱 캐시는 플러그인을 껐다 켜거나 설정이 바뀌면 표째 비워진다(Kong 3.16 실측). 캐시에는 LLM 답변 원문이 cache_ttl 동안
# 남고, 질문은 원문 없이 임베딩(숫자)만 남는다. 가드 표에는 설정의 예문(deny_prompts · deny_responses)이 들어 있다.
source "$(dirname "$0")/lib.sh"
load_env; native_env
kong_up || die "Kong 이 떠 있지 않습니다 — bash start.sh"
pg_ready || die "PostgreSQL 이 멈춰 있습니다 — bash start.sh"

Q=""
case "${1:-}" in
  "") ;;
  --query) Q=${2:-}; [ -n "$Q" ] || die "사용법: bash vectors.sh --query '문장'" ;;
  *) die "사용법: bash vectors.sh [--query '문장']" ;;
esac
PL=$(admin "/routes/poc/plugins?size=100")
[[ "$PL" == *'"data"'* ]] || die "/poc 경로가 없습니다 — bash apply-config.sh"

# Kong 3.16 이 무엇을 임베딩하나 (kong/llm/plugin/ctx.lua · shared-filters/guardrails/utils.lua):
#   의미 기반 가드 = 문장 그대로(discard_role_name) · 시맨틱 캐시 = 마지막 메시지를 「user: 문장」 모양으로(format_chat)
VEC=""; VEC_CACHE=""
embed() {  # embed <문장> → 벡터(JSON) — 플러그인과 같은 길(/ai/embed — 파드 안에서만 받음)
  local body
  body=$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "input": sys.argv[2]}, ensure_ascii=False))' "$DECK_EMBED_MODEL" "$1")
  curl -s -m 30 -H 'Content-Type: application/json' -d "$body" "http://127.0.0.1:$PROXY_PORT/ai/embed" \
    | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["data"][0]["embedding"]))' 2>/dev/null || true
}
if [ -n "$Q" ]; then
  { [ -n "${DECK_EMBED_URL:-}" ] && [ -n "${DECK_EMBED_MODEL:-}" ]; } || die "임베딩 모델이 연결돼 있지 않습니다 (DECK_EMBED_URL · DECK_EMBED_MODEL)"
  VEC=$(embed "$Q"); VEC_CACHE=$(embed "user: $Q")
  { [ -n "$VEC" ] && [ -n "$VEC_CACHE" ]; } || die "임베딩을 받지 못했습니다 (/ai/embed — bash verify.sh 로 임베딩 연결을 확인하세요)"
fi

# /poc 의 의미 기반 플러그인 — 「종류 표이름 켜짐 기준거리」
plugins=$(python3 -c '
import json, sys
kinds = {"ai-semantic-cache": "semantic_cache", "ai-semantic-prompt-guard": "semantic_prompt_guard",
         "ai-semantic-response-guard": "semantic_response_guard"}
for p in json.loads(sys.argv[1])["data"]:
    k = kinds.get(p["name"])
    if not k:
        continue
    c = p.get("config") or {}
    thr = (c.get("search") or {}).get("threshold") or (c.get("vectordb") or {}).get("threshold")
    print(k, k + "_" + p["id"].replace("-", "_"), "켜짐" if p.get("enabled") else "꺼짐", thr)
' "$PL")
[ -n "$plugins" ] || { note "/poc 에 의미 기반 플러그인이 없습니다 — 임베딩 모델을 연결하면 붙습니다 (DECK_EMBED_URL · DECK_EMBED_MODEL)"; exit 0; }

sql() { psql_su -d kong-pgvector -F $'\t' -c "$1" 2>/dev/null; }
while read -r kind table state thr; do
  case "$kind" in
    semantic_cache)          title="시맨틱 캐시 — 저장된 답 (질문은 임베딩만, 답은 원문)" ;;
    semantic_prompt_guard)   title="의미 기반 질문 가드 — 막을 질문의 예" ;;
    semantic_response_guard) title="의미 기반 답변 가드 — 막을 답변의 예" ;;
  esac
  say "$title · 플러그인 $state · 기준 거리 $thr"
  if [ "$(sql "select to_regclass('public.$table') is not null")" != t ]; then
    note "표가 아직 없습니다 ($table) — 플러그인이 처음 쓰일 때 만들어집니다"; continue
  fi
  n=$(sql "select count(*) from \"$table\""); dims=$(sql "select vector_dims(embedding) from \"$table\" limit 1")
  note "표 $table · ${n}개${dims:+ · 임베딩 ${dims}차원}"
  [ "${n:-0}" -gt 0 ] || continue
  if [ "$kind" = semantic_cache ]; then
    cols="to_char(expire_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI'), payload->'payload'->>'model',
          coalesce(payload->'payload'->'usage'->>'total_tokens', '-'),
          left(regexp_replace(coalesce(payload->'payload'->'choices'->0->'message'->>'content', ''), '\s+', ' ', 'g'), 60)"
    head="  %-11s %-18s %6s  %s\n"; [ -n "$VEC" ] || printf "$head" "만료(KST)" "모델" "토큰" "저장된 답"
  else
    cols="payload->'payload'->>'action',
          left(regexp_replace(coalesce(payload->'payload'->>'prompt', payload->'payload'->>'response', ''), '\s+', ' ', 'g'), 70)"
    head="  %-6s %s\n"; [ -n "$VEC" ] || printf "$head" "동작" "예문"
  fi
  if [ -z "$VEC" ]; then
    order=$([ "$kind" = semantic_cache ] && echo "order by expire_at desc" || echo "")
    sql "select $cols from \"$table\" $order limit 20" | while IFS=$'\t' read -r a b c d; do
      if [ "$kind" = semantic_cache ]; then printf "$head" "$a" "$b" "$c" "$d"; else printf "$head" "$a" "$b"; fi
    done
    [ "$n" -gt 20 ] && note "… 외 $((n - 20))개"
  else
    note "「$(python3 -c 'import sys; t=sys.argv[1]; print(t if len(t) <= 30 else t[:30] + "…")' "$Q")」 과 가까운 것 (코사인 거리 — 작을수록 비슷, 기준 $thr 보다 작으면 걸림)"
    v=$VEC; [ "$kind" = semantic_cache ] && v=$VEC_CACHE
    sql "select round((embedding <=> '$v'::vector)::numeric, 3), $cols from \"$table\" order by 1 limit 3" \
      | while IFS=$'\t' read -r dist a b c d; do
          hit=$(awk -v d="$dist" -v t="$thr" 'BEGIN{print (d < t) ? 1 : 0}')
          if [ "$kind" = semantic_cache ]; then
            v=$([ "$hit" = 1 ] && echo "캐시 적중 — 이 답을 돌려줌" || echo "캐시 아님")
            printf '  거리 %s  %s · %s\n' "$dist" "$v" "$d"
          else
            v=$([ "$hit" = 1 ] && echo "막힘" || echo "통과")
            printf '  거리 %s  %s · %s\n' "$dist" "$v" "$b"
          fi
        done
  fi
done <<<"$plugins"
