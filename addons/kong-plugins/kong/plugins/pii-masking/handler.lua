-- pii-masking — 4-1 프롬프트 속 개인정보를 LLM 으로 보내기 전에 라벨로 바꾼다 (이 번들 전용 플러그인)
--   예) "주민번호 900101-1234567" → "주민번호 [주민등록번호]". 무엇을 가렸는지는 X-PII-Masked 헤더 · 요청 로그의 pii_masked.
--   다른 플러그인처럼 Kong Manager 에서 켜고 끈다. 순서: 키 인증(1250)·허용 그룹(950)·호출 수(910)·토큰(905) 뒤 —
--   막힐 요청은 손대지 않는다 — 질문 가드(775·771)·AI 프록시(770)·시맨틱 캐시(765) 앞이라 가드·캐시·LLM 은 가린 질문을 본다.
local PiiMasking = { PRIORITY = 800, VERSION = "1.1.0" }

-- 규칙은 설정(config.rules)에서 읽는다 — Kong Manager 에서 보고 고친다. 비어 있으면 기본 6종(defaults.lua)
--   기본 규칙(rrn·card·mobile·landline·account·email)은 config.types 로 켜고 끄고, 직접 더한 규칙은 늘 적용한다
local defaults = require "kong.plugins.pii-masking.defaults"

function PiiMasking:access(conf)
  local body = kong.request.get_body("application/json")
  if type(body) ~= "table" or type(body.messages) ~= "table" then return end
  local on = {}
  for _, t in ipairs(conf.types or {}) do on[t] = true end
  local rules = (type(conf.rules) == "table" and #conf.rules > 0) and conf.rules or defaults.RULES
  local total, seen, kinds = 0, {}, {}
  local function mask(s)
    for _, r in ipairs(rules) do
      if on[r.name] or not defaults.BUILTIN[r.name] then
        -- 라벨의 % 는 글자 그대로 (gsub 의 %1 같은 치환으로 읽히지 않게)
        local ok, out, n = pcall(string.gsub, s, r.pattern, (tostring(r.label):gsub("%%", "%%%%")))
        if not ok then
          kong.log.err("pii-masking: 규칙 ", r.name, " 의 패턴을 쓸 수 없습니다 — ", out)
        elseif n > 0 then
          s = out
          total = total + n
          if not seen[r.name] then seen[r.name] = true; kinds[#kinds + 1] = r.name end
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
