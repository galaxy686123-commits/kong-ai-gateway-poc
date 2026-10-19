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

-- 행 단위 제한 — 팀 Grafana(GRAFANA_TEAMS)는 그 워크스페이스 행만 읽히는 계정(reqlog_t_<팀>)으로 연결한다 (start.sh 가 계정 · 정책을 만든다).
--   기존 화면(reqlog_reader)은 전부 읽는다. 쓰기 · 보관 기간 정리(postgres)는 제한을 받지 않는다
ALTER TABLE requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reader_all ON requests;
CREATE POLICY reader_all ON requests FOR SELECT TO reqlog_reader USING (true);

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE reqlog TO reqlog_reader;
GRANT USAGE ON SCHEMA public TO reqlog_reader;
GRANT SELECT ON requests TO reqlog_reader;
