-- pii-masking — 4-1 프롬프트 속 개인정보를 LLM 으로 보내기 전에 라벨로 바꾼다 (이 번들 전용 플러그인)
--   예) "주민번호 900101-1234567" → "주민번호 [주민등록번호]". 무엇을 가렸는지는 X-PII-Masked 헤더 · 요청 로그의 pii_masked.
--   다른 플러그인처럼 Kong Manager 에서 켜고 끈다. 순서: 키 인증(1250)·허용 그룹(950)·호출 수(910)·토큰(905) 뒤 —
--   막힐 요청은 손대지 않는다 — 질문 가드(775·771)·AI 프록시(770)·시맨틱 캐시(765) 앞이라 가드·캐시·LLM 은 가린 질문을 본다.
local PiiMasking = { PRIORITY = 800, VERSION = "1.0.0" }

-- 순서가 중요하다: 긴 형식(주민번호·카드)을 먼저 가려야 짧은 형식(계좌)에 잘못 걸리지 않는다
local RULES = {
  { "rrn",      "[주민등록번호]", "%d%d%d%d%d%d%s*%-%s*[1-8]%d%d%d%d%d%d" },
  { "card",     "[카드번호]",     "%d%d%d%d[%- ]%d%d%d%d[%- ]%d%d%d%d[%- ]%d%d%d%d" },
  { "mobile",   "[휴대전화]",     "01[016789][%-%. ]?%d%d%d%d?[%-%. ]?%d%d%d%d" },
  { "landline", "[전화번호]",     "0[2-6]%d?[%-%. ]%d%d%d%d?[%-%. ]%d%d%d%d" },
  -- 계좌: 숫자 묶음 3개(2~6 · 2~6 · 4~7자리). 날짜(2026-10-01)는 마지막 묶음이 짧아 걸리지 않는다
  { "account",  "[계좌번호]",     "%d%d%d?%d?%d?%d?%-%d%d%d?%d?%d?%d?%-%d%d%d%d%d?%d?%d?" },
  { "email",    "[이메일]",       "[%w%.%+%-_]+@[%w%-]+%.[%w%.%-]+" },
}

function PiiMasking:access(conf)
  local body = kong.request.get_body("application/json")
  if type(body) ~= "table" or type(body.messages) ~= "table" then return end
  local on = {}
  for _, t in ipairs(conf.types or {}) do on[t] = true end
  local total, seen, kinds = 0, {}, {}
  local function mask(s)
    for _, r in ipairs(RULES) do
      if on[r[1]] then
        local n
        s, n = s:gsub(r[3], r[2])
        if n > 0 then
          total = total + n
          if not seen[r[1]] then seen[r[1]] = true; kinds[#kinds + 1] = r[1] end
        end
      end
    end
    return s
  end
  for _, m in ipairs(body.messages) do
    if type(m) == "table" then
      if type(m.content) == "string" then
        m.content = mask(m.content)
      elseif type(m.content) == "table" then          -- 멀티모달: 글자 부분만
        for _, part in ipairs(m.content) do
          if type(part) == "table" and type(part.text) == "string" then part.text = mask(part.text) end
        end
      end
    end
  end
  if total > 0 then
    kong.service.request.set_body(body, "application/json")
    if conf.response_header then kong.response.set_header("X-PII-Masked", table.concat(kinds, ",")) end
    kong.log.set_serialize_value("pii_masked", { count = total, types = table.concat(kinds, ",") })
  end
end

return PiiMasking
