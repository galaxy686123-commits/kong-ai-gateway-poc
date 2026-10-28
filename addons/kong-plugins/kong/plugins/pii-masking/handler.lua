-- pii-masking — 4-1 프롬프트 속 개인정보를 LLM 으로 보내기 전에 번호 붙은 라벨로 바꾸고, LLM 답에서는 원래 값으로 되돌린다 (이 번들 전용 플러그인)
--   Kong AI Sanitizer 의 자리 표시(placeholder) · Recover redacted 와 같은 방식 — 같은 값은 같은 번호, 다른 값은 다른 번호 (10-27 사용자 결정)
--   예) "주민번호 900101-1234567, 연락처 010-1111-2222 · 010-3333-4444"
--       → LLM 에는 "주민번호 [주민등록번호1], 연락처 [휴대전화1] · [휴대전화2]"
--       → LLM 답에 [휴대전화1] 이 있으면 사용자에게는 010-1111-2222 로 돌려준다 (recover_redacted, 기본 켬 · 스트리밍 답도)
--   무엇을 가렸는지는 X-PII-Masked 헤더 · 요청 로그의 pii_masked.
--   다른 플러그인처럼 Kong Manager 에서 켜고 끈다. 순서: 키 인증(1250)·허용 그룹(950)·호출 수(910)·토큰(905) 뒤 —
--   막힐 요청은 손대지 않는다 — 질문 가드(775·771)·AI 프록시(770)·시맨틱 캐시(765) 앞이라 가드·캐시·LLM 은 가린 질문을 본다.
--   되돌리기는 이 플러그인의 header_filter · body_filter 에서 한다. 스트리밍은 OpenAI 형식(choices[].delta.content)의
--   조각을 이어 붙여, 라벨이 여러 조각에 걸쳐 와도 원래 값으로 바꾼다 (라벨 앞부분만 온 조각은 다음 조각까지 잠시 붙잡아 둠).
--   원래 값은 사용자에게 보내는 답에만 넣는다 — 요청 로그(Log payloads)의 응답과 시맨틱 캐시에는 LLM 이 준 답 그대로(라벨)
--   남기고(log 단계), 캐시에서 꺼낸 답도 그 요청의 값으로 되돌린다 (10-28 사용자 「Grafana 응답은 LLM 이 준 원문으로」).
local PiiMasking = { PRIORITY = 800, VERSION = "1.3.0" }

-- 규칙은 설정(config.rules)에서 읽는다 — Kong Manager 에서 보고 고친다. 비어 있으면 기본 6종(defaults.lua)
--   기본 규칙(rrn·card·mobile·landline·account·email)은 config.types 로 켜고 끄고, 직접 더한 규칙은 늘 적용한다
local defaults = require "kong.plugins.pii-masking.defaults"
local cjson = require("cjson.safe").new()
cjson.decode_array_with_array_mt(true)      -- 다시 만들 때 빈 목록 [] 이 {} 로 바뀌지 않게

-- 라벨에 번호를 붙인다 — [주민등록번호] → [주민등록번호1] (] 로 끝나지 않는 라벨은 끝에 번호)
local function numbered(label, n)
  if label:sub(-1) == "]" then return label:sub(1, -2) .. n .. "]" end
  return label .. n
end

-- s 에서 pattern 에 맞는 곳을 모두 fn(맞은 글자) 으로 바꾼다 — 패턴에 괄호(캡처)가 있어도 맞은 글자 전체를 넘긴다
local function replace_all(s, pattern, fn)
  local out, i, n, len = {}, 1, 0, #s
  while i <= len do
    local a, b = s:find(pattern, i)
    if not a then break end
    if b < a then                       -- 빈 글자에 맞는 패턴(스키마가 막는다) — 무한 반복하지 않게 한 글자 건너뜀
      out[#out + 1] = s:sub(i, a)
      i = a + 1
    else
      out[#out + 1] = s:sub(i, a - 1)
      out[#out + 1] = fn(s:sub(a, b))
      n = n + 1
      i = b + 1
    end
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out), n
end

-- s 안의 keys 를 map[key] 로 모두 바꾼다 (keys 는 긴 것부터 — 앞부분이 겹치는 것끼리도 맞게)
local function swap_all(s, keys, map)
  if type(s) ~= "string" or s == "" then return s end
  for _, k in ipairs(keys) do
    if s:find(k, 1, true) then
      local v, out, i = map[k], {}, 1
      while true do
        local a, b = s:find(k, i, true)
        if not a then break end
        out[#out + 1] = s:sub(i, a - 1)
        out[#out + 1] = v
        i = b + 1
      end
      out[#out + 1] = s:sub(i)
      s = table.concat(out)
    end
  end
  return s
end

-- 라벨을 원래 값으로 (긴 라벨부터 — ] 로 끝나지 않는 라벨끼리 앞부분이 겹쳐도 맞게)
local function restore_text(s, ctx) return swap_all(s, ctx.labels, ctx.restore) end

-- 원래 값을 라벨로 되바꾼다 (요청 로그 · 시맨틱 캐시용, 긴 값부터)
local function mask_back_text(s, ctx) return swap_all(s, ctx.values, ctx.masked) end

-- JSON 안의 모든 글자 값을 fn 으로 바꾼다
local function map_json(v, fn, ctx)
  if type(v) == "string" then return fn(v, ctx) end
  if type(v) == "table" then
    for k, x in pairs(v) do v[k] = map_json(x, fn, ctx) end
  end
  return v
end

-- 본문 전체(JSON 이면 모든 글자 값, 아니면 글 그대로)를 fn 으로 바꾼다
local function map_body(body, fn, ctx)
  local obj = cjson.decode(body)
  if type(obj) == "table" then
    local out = cjson.encode(map_json(obj, fn, ctx))
    if out then return out end
  end
  return fn(body, ctx)
end

local function restore_body(body, ctx) return map_body(body, restore_text, ctx) end

-- 스트리밍: 끝부분이 어떤 라벨의 앞부분이면 다음 조각까지 붙잡아 둔다 → (지금 보낼 글, 붙잡아 둘 글)
local function split_hold(text, ctx)
  local max = math.min(#text, ctx.maxlen - 1)
  for k = max, 1, -1 do
    local tail = text:sub(-k)
    for _, lb in ipairs(ctx.labels) do
      if #lb > k and lb:sub(1, k) == tail then
        return text:sub(1, #text - k), tail
      end
    end
  end
  return text, ""
end

-- 스트리밍 이벤트 하나(data: {...}) — delta.content 를 이어 붙여 되돌린다. 마침 표시(finish_reason)가 오면 붙잡은 글을 내보낸다
local function sse_event(ev, ctx)
  local pre, payload = ev:match("^(.-data:%s?)(.*)$")
  if not payload or payload:sub(1, 1) ~= "{" then
    if payload and payload:match("^%[DONE%]") then        -- 끝 — 아직 붙잡은 글이 있으면 먼저 내보낸다
      local extra = {}
      for idx, rest in pairs(ctx.pending) do
        if rest ~= "" then
          extra[#extra + 1] = "data: " .. cjson.encode({ object = "chat.completion.chunk",
            choices = { { index = idx, delta = { content = restore_text(rest, ctx) } } } }) .. "\n\n"
          ctx.pending[idx] = ""
        end
      end
      return table.concat(extra) .. ev
    end
    return ev
  end
  local obj = cjson.decode(payload)
  if type(obj) ~= "table" or type(obj.choices) ~= "table" then return ev end
  local changed = false
  for _, ch in ipairs(obj.choices) do
    local idx = ch.index or 0
    local delta = type(ch.delta) == "table" and ch.delta or nil
    if delta and type(delta.content) == "string" then
      local text = (ctx.pending[idx] or "") .. delta.content
      local send, hold = split_hold(text, ctx)
      ctx.pending[idx] = hold
      delta.content = restore_text(send, ctx)
      changed = true
    end
    if ch.finish_reason ~= nil and ch.finish_reason ~= cjson.null and (ctx.pending[idx] or "") ~= "" then
      if not delta then delta = {}; ch.delta = delta end
      delta.content = (delta.content or "") .. restore_text(ctx.pending[idx], ctx)
      ctx.pending[idx] = ""
      changed = true
    end
    if type(ch.message) == "table" and type(ch.message.content) == "string" then
      ch.message.content = restore_text(ch.message.content, ctx)
      changed = true
    end
  end
  if not changed then return ev end
  local out = cjson.encode(obj)
  return out and (pre .. out) or ev
end

function PiiMasking:access(conf)
  local body = kong.request.get_body("application/json")
  if type(body) ~= "table" or type(body.messages) ~= "table" then return end
  local on = {}
  for _, t in ipairs(conf.types or {}) do on[t] = true end
  local rules = (type(conf.rules) == "table" and #conf.rules > 0) and conf.rules or defaults.RULES
  local total, seen, kinds = 0, {}, {}
  local label_of, count, restore = {}, {}, {}        -- (라벨, 원래 값) → 번호 붙은 라벨 · 라벨마다 번호 · 번호 붙은 라벨 → 원래 값
  local function mask(s)
    for _, r in ipairs(rules) do
      if on[r.name] or not defaults.BUILTIN[r.name] then
        local base = tostring(r.label)
        local ok, out, n = pcall(replace_all, s, r.pattern, function(v)
          local key = base .. "\0" .. v
          local lb = label_of[key]
          if not lb then
            count[base] = (count[base] or 0) + 1
            lb = numbered(base, count[base])
            label_of[key] = lb
            restore[lb] = v
          end
          return lb
        end)
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
    if conf.recover_redacted then
      local labels, values, masked, maxlen = {}, {}, {}, 0
      for lb, v in pairs(restore) do
        labels[#labels + 1] = lb
        values[#values + 1] = v
        masked[v] = lb
        if #lb > maxlen then maxlen = #lb end
      end
      table.sort(labels, function(a, b) return #a > #b end)
      table.sort(values, function(a, b) return #a > #b end)
      kong.ctx.plugin.recover = { restore = restore, labels = labels, values = values, masked = masked,
                                  maxlen = maxlen, pending = {}, buf = "" }
      kong.service.request.clear_header("Accept-Encoding")   -- 압축된 답은 글자를 바꿀 수 없다
    end
  end
end

function PiiMasking:header_filter(conf)
  local ctx = kong.ctx.plugin.recover
  if not ctx then return end
  kong.response.clear_header("Content-Length")
  ctx.sse = (kong.response.get_header("Content-Type") or ""):find("text/event-stream", 1, true) ~= nil
  -- 비스트리밍 AI 응답 — AI Proxy 가 응답을 모아(buffered proxying) header_filter 에서 그 본문을 읽어 다듬고 길이(Content-Length)를 정한 뒤
  --   body_filter 에서 자기 보관 본문으로 내보낸다(kong/llm/plugin/base.lua · normalize-json-response, 3.16 확인).
  --   그래서 body_filter 에서 바꾸면 덮어써진다 → AI Proxy(770)보다 먼저 도는 여기서(800) 모은 LLM 답 원본을 되돌려 둔다.
  --   쓰는 자리는 PDK 가 response 단계 set_raw_body 로 쓰는 ngx.ctx.buffered_body
  --   (response 단계는 header_filter · body_filter 와 한 플러그인에 둘 수 없어 쓰지 않음)
  --   모은 본문이 없으면(시맨틱 캐시가 저장한 답을 돌려줌 등 — LLM 을 부르지 않은 응답) body_filter 에서 조각을 모아 되돌린다
  if not ctx.sse and ngx.ctx.buffered_proxying then
    local body = kong.service.response.get_raw_body()
    if type(body) == "string" and body ~= "" then
      ngx.ctx.buffered_body = restore_body(body, ctx)
      ctx.done = true
    end
  end
end

function PiiMasking:body_filter(conf)
  local ctx = kong.ctx.plugin.recover
  if not ctx then return end
  if ctx.sse then
    -- 스트리밍 — 받은 조각을 이벤트(빈 줄로 끝남) 단위로 나눠 되돌리고, 끝나지 않은 이벤트는 다음 조각과 잇는다
    local chunk, eof = ngx.arg[1], ngx.arg[2]
    local buf = ctx.buf .. (chunk or "")
    local out = {}
    while true do
      local a, b = buf:find("\r?\n\r?\n")
      if not a then break end
      out[#out + 1] = sse_event(buf:sub(1, a - 1), ctx) .. buf:sub(a, b)
      buf = buf:sub(b + 1)
    end
    if eof then
      if buf ~= "" then out[#out + 1] = sse_event(buf, ctx) end
      buf = ""
      for idx, rest in pairs(ctx.pending) do       -- 마침 표시 없이 끝난 경우에도 붙잡은 글을 남기지 않는다
        if rest ~= "" then
          out[#out + 1] = "data: " .. cjson.encode({ object = "chat.completion.chunk",
            choices = { { index = idx, delta = { content = restore_text(rest, ctx) } } } }) .. "\n\n"
          ctx.pending[idx] = ""
        end
      end
    end
    ctx.buf = buf
    ngx.arg[1] = table.concat(out)
    return
  end
  if ctx.done then return end                      -- 모은 응답은 header_filter 에서 이미 되돌림
  -- 모으지 않은 비스트리밍 응답(AI 플러그인이 아닌 경로) — 조각을 이 플러그인이 모았다가 마지막 조각에서 한 번에 되돌린다
  --   (kong.response.get_raw_body() 는 플러그인끼리 같은 버퍼를 써서 뒤의 플러그인이 원래 본문으로 덮어쓸 수 있다)
  local chunk, eof = ngx.arg[1], ngx.arg[2]
  if type(chunk) == "string" and chunk ~= "" then
    ctx.parts = ctx.parts or {}
    ctx.parts[#ctx.parts + 1] = chunk
  end
  if not eof then
    ngx.arg[1] = nil
    return
  end
  local body = table.concat(ctx.parts or {})
  ctx.parts = nil
  ngx.arg[1] = restore_body(body, ctx)
end

-- 요청 로그 · 시맨틱 캐시에는 LLM 이 준 답 그대로(라벨)를 남긴다
--   AI Proxy 는 되돌린 답을 공용 응답 본문(kong.llm.plugin.ctx 의 _global.response_body)에 두고 응답 기록(Log payloads)에 쓰며,
--   시맨틱 캐시는 로그 단계에서 그 본문을 저장한다(3.16 확인). 그대로 두면 Grafana 「요청 기록」 응답 칸에 원래 값이 보이고,
--   가리면 같은 질문이 되는 다른 사용자가 캐시에서 이 값을 받는다 → 로그 단계에서 AI Proxy(770) · 시맨틱 캐시(765) ·
--   로그 플러그인보다 먼저 도는 여기서(800) 원래 값을 라벨로 되바꾼다. 응답 기록은 Log payloads 를 켠 대상만 있으므로 있을 때만 바꾼다
local ai_ctx
function PiiMasking:log(conf)
  local ctx = kong.ctx.plugin.recover
  if not ctx then return end
  if ai_ctx == nil then
    local ok, m = pcall(require, "kong.llm.plugin.ctx")
    ai_ctx = ok and m or false
  end
  if not ai_ctx then return end
  local ok, body = pcall(ai_ctx.get_namespaced_ctx, "_global", "response_body")
  if not ok or type(body) ~= "string" or body == "" then return end
  local back = map_body(body, mask_back_text, ctx)
  if back == body then return end
  pcall(ai_ctx.set_namespaced_ctx, "_global", "response_body", back)
  kong.log.set_serialize_value("ai.proxy.payload.response", back, { mode = "replace" })
end

return PiiMasking
