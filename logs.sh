#!/usr/bin/env bash
# logs.sh — 요청 로그(감사 추적) 보기·내보내기
#   ./logs.sh              최근 20건 요약
#   ./logs.sh -f           실시간
#   ./logs.sh export DIR   로그 파일을 DIR 로 복사 (보관·제출용)
#   ./logs.sh admin        관리 작업 감사로그(설정 변경 이력, DB 저장)
source "$(dirname "$0")/lib.sh"
LOG=/var/log/kong-poc/audit.log
case "${1:-}" in
  -f)     docker exec "$C_KONG" tail -f "$LOG" ;;
  export) dir=${2:?"저장할 디렉토리를 지정하세요"}; mkdir -p "$dir"
          out="$dir/kong-audit-$(date +%Y%m%d-%H%M%S).log"
          docker cp "$C_KONG:$LOG" "$out" && note "저장: $out ($(wc -l < "$out")건, $(du -h "$out" | cut -f1))" ;;
  admin)  # 설정을 바꾼 요청만 (조회 GET 제외). 30일 보관 후 자동 삭제.
          docker exec "$C_PG" psql -U kong -d kong -c \
            "select to_char(request_timestamp,'MM-DD HH24:MI:SS') as 시각, rbac_user_name as 사용자,
                    method, path, status
               from audit_requests where method <> 'GET'
              order by request_timestamp desc limit 20" ;;
  *)      # 요약은 Kong 컨테이너 안의 resty(Lua)로 만든다 — 개발환경 도구에 의존하지 않는다
          docker exec "$C_KONG" resty -e '
local cjson = require "cjson.safe"
local f = io.open("/var/log/kong-poc/audit.log")
if not f then print("  아직 기록된 요청이 없습니다.") return end
local rows = {}
for l in f:lines() do rows[#rows + 1] = l end
f:close()
print(string.format("  %-14s %-12s %4s  %-34s %-14s %6s  %s", "시각(KST)", "사용자", "상태", "경로", "모델", "토큰", "캐시"))
for i = math.max(1, #rows - 19), #rows do
  local d = cjson.decode(rows[i])
  if d then
    local ai = {}
    if type(d.ai) == "table" then ai = d.ai.proxy or select(2, next(d.ai)) or {} end
    local meta, usage, cache = ai.meta or {}, ai.usage or {}, ai.cache or {}
    local model = meta.response_model or meta.request_model or "-"
    if model == "UNSPECIFIED" then model = "-" end
    print(string.format("  %-14s %-12s %4s  %-34s %-14s %6s  %s",
      os.date("!%m-%d %H:%M:%S", math.floor((d.started_at or 0) / 1000) + 9 * 3600),
      (d.consumer and d.consumer.username) or "-",
      tostring(d.response and d.response.status or "-"),
      ((d.request and d.request.uri) or ""):sub(1, 34),
      model:sub(1, 14),
      tostring(usage.total_tokens or "-"),
      cache.cache_status or ""))
  end
end' ;;
esac
