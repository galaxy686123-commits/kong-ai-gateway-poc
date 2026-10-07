-- response-masking — 4-5 LLM 답변 속 사설 IP · API 키 · DB 접속 정보 · password 값을 가린다 (이 번들 전용 플러그인)
--   답변을 다 받은 뒤 고치므로 스트리밍 답변에는 걸리지 않는다 (켤 때는 AI Proxy Advanced 의 스트리밍을 끈다 — 설정 파일 스위치가 함께 끔).
--   다른 플러그인처럼 Kong Manager 에서 켜고 끈다. 순서: 답변 검사(가드레일) 뒤, 표준 문구 바꾸기(post-function) 앞.
local ResponseMasking = { PRIORITY = -900, VERSION = "1.0.0" }

local RULES = {
  ip = {
    { "10%.%d+%.%d+%.%d+", "[내부IP]" },
    { "172%.1[6-9]%.%d+%.%d+", "[내부IP]" },
    { "172%.2%d%.%d+%.%d+", "[내부IP]" },
    { "172%.3[01]%.%d+%.%d+", "[내부IP]" },
    { "192%.168%.%d+%.%d+", "[내부IP]" },
  },
  api_key = {
    { "sk%-[%w%-_][%w%-_][%w%-_][%w%-_][%w%-_]+", "[API키]" },
    { "AKIA[%u%d][%u%d][%u%d][%u%d]+", "[API키]" },
    { "gh[po]_%w+", "[API키]" },
    { "xox[abpr]%-[%w%-]+", "[API키]" },
  },
  db_url = {
    { "(%a[%w%+%.%-]*://)[^:/@%s\"]+:[^@%s\"]+@", "%1***:***@" },
  },
  password = {
    { "([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[=:]%s*)[^%s,;\"\\]+", "%1***" },
  },
}
local ORDER = { "ip", "api_key", "db_url", "password" }

function ResponseMasking:access(conf)
  -- 압축된 응답은 글자를 바꿀 수 없다 → 업스트림에 압축을 요청하지 않는다
  kong.service.request.clear_header("Accept-Encoding")
end

function ResponseMasking:header_filter(conf)
  kong.response.clear_header("Content-Length")
end

function ResponseMasking:body_filter(conf)
  local body = kong.response.get_raw_body()        -- 마지막 조각에서 전체 본문을 돌려준다
  if not body then return end
  local on = {}
  for _, t in ipairs(conf.types or {}) do on[t] = true end
  local total = 0
  for _, kind in ipairs(ORDER) do
    if on[kind] then
      for _, r in ipairs(RULES[kind]) do
        local n
        body, n = body:gsub(r[1], r[2])
        total = total + n
      end
    end
  end
  if total > 0 then kong.log.set_serialize_value("output_masked", total) end
  kong.response.set_raw_body(body)
end

return ResponseMasking
