-- pii-masking 기본 규칙 — schema.lua(설정 기본값) 와 handler.lua(설정이 비었을 때) 가 함께 쓴다.
--   위에서부터 차례로 적용한다. 긴 형식(주민번호·카드)을 먼저 가려야 짧은 형식(계좌)에 잘못 걸리지 않는다.
--   pattern 은 Lua 패턴이다 — %d 숫자 · %s 공백 · %- 는 - 글자 · [..] 그 가운데 하나 · ? 있어도 없어도 됨.
local RULES = {
  { name = "rrn",      label = "[주민등록번호]", pattern = "%d%d%d%d%d%d%s*%-%s*[1-8]%d%d%d%d%d%d" },   -- 뒷자리 5~8 은 외국인등록번호
  { name = "card",     label = "[카드번호]",     pattern = "%d%d%d%d[%- ]%d%d%d%d[%- ]%d%d%d%d[%- ]%d%d%d%d" },
  { name = "mobile",   label = "[휴대전화]",     pattern = "01[016789][%-%. ]?%d%d%d%d?[%-%. ]?%d%d%d%d" },
  { name = "landline", label = "[전화번호]",     pattern = "0[2-6]%d?[%-%. ]%d%d%d%d?[%-%. ]%d%d%d%d" },
  -- 계좌: 숫자 묶음 3개(2~6 · 2~6 · 4~7자리). 날짜(2026-10-01)는 마지막 묶음이 짧아 걸리지 않는다
  { name = "account",  label = "[계좌번호]",     pattern = "%d%d%d?%d?%d?%d?%-%d%d%d?%d?%d?%d?%-%d%d%d%d%d?%d?%d?" },
  { name = "email",    label = "[이메일]",       pattern = "[%w%.%+%-_]+@[%w%-]+%.[%w%.%-]+" },
}

local NAMES, BUILTIN = {}, {}
for i, r in ipairs(RULES) do
  NAMES[i] = r.name
  BUILTIN[r.name] = true
end

return { RULES = RULES, NAMES = NAMES, BUILTIN = BUILTIN }
