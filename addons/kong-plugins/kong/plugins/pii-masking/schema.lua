local typedefs = require "kong.db.schema.typedefs"
local defaults = require "kong.plugins.pii-masking.defaults"

-- Lua 패턴 검사 — 저장할 때 틀린 패턴(괄호 짝 등)과 빈 글자에도 맞는 패턴(%d* 처럼 — 글자마다 라벨이 끼어든다)을 거른다
local function lua_pattern(p)
  local ok, s = pcall(string.find, "", p)
  if not ok then
    return nil, "Lua 패턴이 올바르지 않습니다: " .. (tostring(s):gsub("^.-:%d+: ", ""))
  end
  if s then
    return nil, "빈 글자에도 맞는 패턴은 쓸 수 없습니다 (예: %d* 대신 %d+)"
  end
  return true
end

local function copy_rules()
  local out = {}
  for i, r in ipairs(defaults.RULES) do
    out[i] = { name = r.name, label = r.label, pattern = r.pattern }
  end
  return out
end

local function copy_names()
  local out = {}
  for i, n in ipairs(defaults.NAMES) do out[i] = n end
  return out
end

return {
  name = "pii-masking",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- 기본 규칙 6종 가운데 쓸 것: rrn 주민·외국인등록번호 · card 카드 · mobile 휴대전화 · landline 유선전화 · account 계좌 · email 이메일
          { types = { type = "set", default = copy_names(),
                      elements = { type = "string", one_of = defaults.NAMES },
                      description = "기본 규칙(rrn · card · mobile · landline · account · email) 가운데 쓸 것. "
                                 .. "rules 에 직접 더한 규칙은 이 목록과 상관없이 늘 적용된다 — 빼려면 rules 에서 지운다." } },
          -- 가릴 규칙 — Kong Manager 에서 보고 고친다. 비우면 기본 6종으로 돈다
          { rules = { type = "array", default = copy_rules(),
                      description = "가릴 규칙. 위에서부터 차례로 적용한다(긴 형식을 먼저). pattern 은 Lua 패턴 — "
                                 .. "%d 숫자 · %s 공백 · %- 는 - 글자 · [..] 그 가운데 하나 · ? 있어도 없어도 됨. 비우면 기본 6종.",
                      elements = { type = "record", fields = {
                        { name = { type = "string", required = true, match = "^[%w_%-]+$", len_max = 40,
                                   description = "규칙 이름 — X-PII-Masked 헤더와 요청 로그(pii_masked)에 남는다" } },
                        { label = { type = "string", required = true, len_max = 100,
                                    description = "가린 자리에 넣을 글자 (예: [주민등록번호])" } },
                        { pattern = { type = "string", required = true, len_max = 500, custom_validator = lua_pattern,
                                      description = "찾을 형식 (Lua 패턴)" } },
                      } } } },
          { response_header = { type = "boolean", default = true,
                                description = "가린 종류를 응답 헤더 X-PII-Masked 로 알린다" } },
        },
    } },
  },
}
