-- 요청 기록 DB (reqlog) — 요청 로그(audit.log) 한 줄 = 한 행. start.sh 가 기동할 때마다 실행한다 (여러 번 실행해도 같음)
-- 쓰기는 reqlog.py(postgres, 파드 안 소켓), 읽기는 Grafana(reqlog_reader, 127.0.0.1 · 비밀번호)
CREATE TABLE IF NOT EXISTS requests (
  request_id        text PRIMARY KEY,          -- Kong 요청 ID (request.id) — 같은 줄을 두 번 옮겨도 한 행
  ts                timestamptz NOT NULL,      -- 요청 시각 (started_at)
  consumer          text,                      -- 사용자(컨슈머) — 인증 전에 막힌 요청은 비어 있음
  route             text,
  method            text,
  path              text,                      -- 주소 (쿼리 문자열은 뺌 — 키를 쿼리로 보낸 경우 남지 않게)
  status            integer,
  model             text,
  provider          text,
  prompt_tokens     integer,
  completion_tokens integer,
  total_tokens      integer,
  latency_ms        integer,                   -- 게이트웨이가 받은 때부터 답할 때까지
  llm_latency_ms    integer,                   -- 그 가운데 LLM 이 답한 시간
  cache_status      text,
  client_ip         text,
  question          text,                      -- 마지막 사용자 메시지 — Log payloads 를 켠 대상만
  answer            text,                      -- 답변 글 — Log payloads 를 켠 대상만
  request_body      text,                      -- 요청 본문 원문 (JSON)
  response_body     text                       -- 응답 본문 원문 (JSON)
);
CREATE INDEX IF NOT EXISTS requests_ts ON requests (ts DESC);
ALTER TABLE requests ADD COLUMN IF NOT EXISTS cost double precision;   -- 예상 비용 (대상에 넣은 토큰 단가로 Kong 이 계산, 단가가 없으면 0)
ALTER TABLE requests ADD COLUMN IF NOT EXISTS workspace text;         -- Kong 워크스페이스 (요청 로그의 workspace_name) — 예전 행은 비어 있음 = default
CREATE INDEX IF NOT EXISTS requests_ws_ts ON requests (workspace, ts DESC);
ALTER TABLE requests ADD COLUMN IF NOT EXISTS forwarded_for text;     -- 앞단 프록시가 넘긴 원래 IP (X-Forwarded-For) — client_ip 는 Kong 이 받은 접속 주소
ALTER TABLE requests ADD COLUMN IF NOT EXISTS error_message text;     -- 4xx · 5xx 응답의 사유 (post-function block-message 가 남긴 error_body 에서)
ALTER TABLE requests ADD COLUMN IF NOT EXISTS kong_latency_ms integer;  -- 그 가운데 Kong 이 쓴 시간 (latencies.kong — LLM 응답 시간은 뺌)
ALTER TABLE requests ADD COLUMN IF NOT EXISTS ai_window text;           -- 2-4 토큰 한도 — 켰을 때만: 한도 기간 (예: minute-policy-1)
ALTER TABLE requests ADD COLUMN IF NOT EXISTS ai_limit integer;         --   그 기간의 토큰 한도
ALTER TABLE requests ADD COLUMN IF NOT EXISTS ai_remaining integer;     --   이 요청 뒤 남은 토큰 (Kong 이 응답 헤더로 알려 준 값)
ALTER TABLE requests ADD COLUMN IF NOT EXISTS correlation_id text;      -- 추적 ID (X-Correlation-ID) — 에이전트가 이어 붙이면 연쇄 호출이 같은 값
CREATE INDEX IF NOT EXISTS requests_corr ON requests (correlation_id);
CREATE INDEX IF NOT EXISTS requests_route_ts ON requests (route, ts DESC);   -- 에이전트 목록의 경로별 호출 수 · 마지막 호출
ALTER TABLE requests ADD COLUMN IF NOT EXISTS a2a_method text;          -- A2A 에이전트 경로(AI A2A Proxy)만: 메서드 (message/send · tasks/get …)
ALTER TABLE requests ADD COLUMN IF NOT EXISTS a2a_task_id text;         --   작업 ID
ALTER TABLE requests ADD COLUMN IF NOT EXISTS a2a_task_state text;      --   작업 상태 (working · completed …)
ALTER TABLE requests ADD COLUMN IF NOT EXISTS end_user text;            -- SSO 사용자 — openid-connect 가 토큰의 사용자 이름으로 채운 X-User 헤더 (에이전트 키 + 사용자 토큰을 함께 쓰면 consumer = 에이전트, 이 칸 = 사람)
ALTER TABLE requests ADD COLUMN IF NOT EXISTS masked_types text;        -- 질문 개인정보 마스킹(번들 pii-masking)이 가린 종류 — 규칙 이름을 쉼표로 (rrn · card · mobile …)
ALTER TABLE requests ADD COLUMN IF NOT EXISTS masked_count integer;     --   가린 개수
ALTER TABLE requests ADD COLUMN IF NOT EXISTS output_masked integer;    -- 답변 마스킹(번들 response-masking)이 가린 개수
ALTER TABLE requests ADD COLUMN IF NOT EXISTS guardrail_block text;     -- AI Custom Guardrail 이 막은 쪽 · 출처 · 사유 (요청 로그 ai.proxy.custom-guardrail — 막지 않았으면 비어 있음)

-- 보안 기록 대시보드 — 막거나 가린 플러그인. Kong 은 막은 플러그인 이름을 따로 남기지 않아, 플러그인마다 다른 응답 코드 · 사유 문구로 나눈다 (Kong 3.16 확인)
--   사유 문구는 post-function block-message 가 남긴 error_body (reqlog.py error_message). 404 · 5xx 같은 일반 오류는 비워 둔다
--   함수는 부르는 쪽 권한으로 돌므로 팀 계정(reqlog_*)의 행 단위 제한이 그대로 걸린다 — 보기(view)는 만든 계정 권한으로 돌아 제한을 넘으므로 쓰지 않는다
CREATE OR REPLACE FUNCTION security_plugin(st integer, msg text, guardrail text, masked integer, out_masked integer)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN coalesce(guardrail, '') <> '' THEN 'AI Custom Guardrail'
    WHEN st = 400 AND (msg LIKE 'prompt pattern is blocked%' OR msg LIKE 'prompt doesn''t match any allowed pattern%') THEN 'AI Prompt Guard'
    WHEN st = 400 AND msg = 'bad request' THEN 'AI Semantic Prompt Guard'
    WHEN st = 400 AND msg = 'bad response' THEN 'AI Semantic Response Guard'
    WHEN st = 401 THEN 'Key Authentication · OpenID Connect'
    WHEN st = 403 AND msg LIKE 'You cannot consume this service%' THEN 'ACL'
    WHEN st = 403 THEN '접근 거부(기타)'
    WHEN st = 429 AND msg LIKE 'AI token rate limit%' THEN 'AI Rate Limiting Advanced'
    WHEN st = 429 THEN 'Rate Limiting'
    WHEN st = 503 AND msg LIKE '%긴급 차단%' THEN 'Request Termination(긴급 차단)'
    WHEN st < 400 AND coalesce(masked, 0) > 0 THEN 'pii-masking(질문 마스킹)'
    WHEN st < 400 AND coalesce(out_masked, 0) > 0 THEN 'response-masking(답변 마스킹)'
  END $$;
-- 마스킹 규칙 이름 → 화면 이름 (번들 전용 플러그인 pii-masking 의 기본 규칙. 고객이 더한 규칙은 이름 그대로)
CREATE OR REPLACE FUNCTION pii_labels(types text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(array_to_string(ARRAY(
    SELECT CASE t WHEN 'rrn' THEN '주민등록번호' WHEN 'card' THEN '카드번호' WHEN 'mobile' THEN '휴대전화'
                  WHEN 'landline' THEN '전화번호' WHEN 'account' THEN '계좌번호' WHEN 'email' THEN '이메일' ELSE t END
    FROM unnest(string_to_array(types, ',')) AS t), ', '), '') $$;

-- 에이전트 목록 — agents.py 가 1분마다 Kong 설정(이름이 agent- 로 시작하는 경로)과 Agent Card 를 읽어 통째로 바꿔 넣는다
CREATE TABLE IF NOT EXISTS agents (
  workspace        text NOT NULL,
  name             text NOT NULL,             -- 경로(Route) 이름
  paths            text,                      -- 부르는 주소
  kind             text,                      -- A2A (AI A2A Proxy 를 붙임) · HTTP
  registered_by    text,                      -- 설정 파일(kong-poc 태그) · Kong Manager
  auth             text,                      -- 붙은 인증 (키 · SSO 토큰 …)
  access_rule      text,                      -- ACL 규칙 (허용 그룹 · 차단 그룹 · 허용 식 · 차단 식)
  callers          text,                      -- 부를 수 있는 계정 (허용 그룹이면 그 계정들)
  kill_switch      boolean,                   -- 긴급 차단 켜짐
  a2a_logging      text,                      -- AI A2A Proxy 기록 (통계 · 본문)
  health           text,                      -- Upstream 상태 점검 결과
  targets          text,                      -- 에이전트 서버 (Target)
  card_name        text,                      -- Agent Card 의 name · description · version · skills
  card_description text,
  card_version     text,
  card_skills      text,
  card_error       text,                      -- 카드를 읽지 못한 이유
  updated_at       timestamptz,
  PRIMARY KEY (workspace, name)
);

-- 행 단위 제한 — 팀 Grafana(GRAFANA_TEAMS)는 그 워크스페이스 행만 읽히는 계정(reqlog_t_<팀>)으로 연결한다 (start.sh 가 계정 · 정책을 만든다).
--   기존 화면(reqlog_reader)은 전부 읽는다. 쓰기 · 보관 기간 정리(postgres)는 제한을 받지 않는다
ALTER TABLE requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reader_all ON requests;
CREATE POLICY reader_all ON requests FOR SELECT TO reqlog_reader USING (true);
ALTER TABLE agents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reader_all ON agents;
CREATE POLICY reader_all ON agents FOR SELECT TO reqlog_reader USING (true);

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE reqlog TO reqlog_reader;
GRANT USAGE ON SCHEMA public TO reqlog_reader;
GRANT SELECT ON requests, agents TO reqlog_reader;
