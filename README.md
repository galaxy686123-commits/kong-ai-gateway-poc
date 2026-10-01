# Kong AI Gateway PoC

docker 를 쓸 수 없는 **개발환경 파드(주피터)**에 Kong AI Gateway(Enterprise)를 직접 설치하고,
PoC 요구사항(1-1 ~ 4-5)을 설정으로 구현해 **스크립트 한 번으로 점검**하는 저장소입니다.
Kubernetes 권한이나 컨테이너 없이 **sudo · apt(Ubuntu 22.04) · GitHub** 만 있으면 됩니다.

```
                ┌──────────────────────── 개발환경 파드 (Ubuntu 22.04) ────────────────────────┐
 클라이언트 ───▶ │ Kong Gateway 3.16  :8000 프록시   ── 통합 경로 /v1/chat/completions ──────────│──▶ 사내 LLM
 (부서 키·SSO)   │                    :8001 Admin API (RBAC)                                    │──▶ 외부 LLM·Azure·GCP·AWS
 브라우저 ─────▶ │                    :8002 Kong Manager                                        │──▶ OCR · Agent
 Prometheus ───▶ │                    :8100 /metrics                                            │──▶ 중앙 로그 · 추적 수집기
                 │        │                         │                        │                   │
                 │ PostgreSQL 14 :5432        한국어 PII 가드 :18080     모의 서버 :18090       │
                 │  ├ kong (설정·관리 감사로그)  (개인정보·유해 답변 판정)  (시험용 LLM·OCR·Agent) │
                 │  └ kong-pgvector (의미 기반 가드·시맨틱 캐시)                                 │
                 └──────────────────────────────────────────────────────────────────────────────┘
```

| 구성 | 내용 |
|---|---|
| Kong | Kong Gateway **Enterprise 3.16.0.0** · traditional 모드 · 워커 2개 |
| 데이터베이스 | PostgreSQL 14 (Ubuntu 저장소) + pgvector 0.8.6 (GitHub 소스 빌드) |
| 설정 관리 | [decK](https://developer.konghq.com/deck/) 선언형 파일 `conf/*.yaml` → `apply-config.sh` |
| 설치 파일 | `pkgs/` — Kong `.deb`(Ubuntu 22.04용) · decK 1.65.1 · `SHA256SUMS` |
| 실행 | 컨테이너 없이 파드 안의 프로세스 4개 (PostgreSQL · Kong · PII 가드 · 모의 서버) |

Kong 패키지 저장소·GitHub Release 가 막힌 파드를 위해 설치 파일을 저장소에 넣었습니다. `git clone` 하나로 받습니다.

---

## 처음 설치

```bash
cd /project/work/Kong                     # 파드를 다시 만들어도 남는 경로
git clone --depth 1 https://github.com/galaxy686123-commits/kong-ai-gateway-poc.git
cd kong-ai-gateway-poc
bash kong-check.sh                        # (선택) 설치 전 환경 점검
cp .env.example .env
```

**`.env`** — 비밀번호·키 4개를 임의값으로 만들고, 브라우저 접속 주소를 넣습니다.

```bash
for k in KONG_PG_PASSWORD KONG_ADMIN_PASSWORD KONG_SESSION_SECRET DECK_CLIENT_KEY; do
  v=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')
  sed -i "s|^$k=.*|$k=$v|" .env
done
sed -i 's|^MANAGER_URL=.*|MANAGER_URL=<8002 포트의 외부 주소>|; s|^ADMIN_API_URL=.*|ADMIN_API_URL=<8001 포트의 외부 주소>|' .env
grep -E '^(KONG_ADMIN_PASSWORD|DECK_CLIENT_KEY|MANAGER_URL|ADMIN_API_URL)=' .env    # 로그인 비밀번호·사용자 키 확인
```

- `.env` 는 숨김 파일이라 주피터 탐색기에서 바로 안 열립니다. `sed` 로 고치거나 `cp .env env.txt` → 편집 → `mv env.txt .env`.
- **라이선스**: 주피터 탐색기로 `secrets/` 에 올리고 이름을 `license.json` 으로 바꿉니다.

```bash
bash start.sh          # 설치 → DB → 마이그레이션 → PII 가드·모의 서버 → Kong (처음 약 2분)
bash apply-config.sh   # 요구사항별 설정 적용 (라이선스 필요)
bash verify.sh         # 요구사항별 점검 — 요약이 「불가 0」이면 됩니다
```

`bash verify.sh --full` 은 70초 장기 연결·긴급 차단 켜고 끄기까지 실제로 해 봅니다 (약 2분).
항목별로 하나씩 보여 주는 방법과 **파드 밖(PC)에서 외부 주소로 검증하는 방법**은 [VERIFY.md](VERIFY.md) 에 있습니다.

### Kong Manager 접속

Kong Manager 는 **브라우저가 Admin API(8001)를 직접 부르므로** 8002 와 8001 이 둘 다 브라우저에서 닿아야 합니다.

| 방식 | `.env` | 브라우저 주소 |
|---|---|---|
| **플랫폼이 8000·8001·8002 를 밖으로 연 경우** | `MANAGER_URL=<8002 주소>` · `ADMIN_API_URL=<8001 주소>` · `JUPYTER_URL=` (비움) | `MANAGER_URL` |
| 주피터를 거쳐 여는 경우 (`jupyter-server-proxy`) | `JUPYTER_URL=<주피터 주소>` | `<JUPYTER_URL>/proxy/absolute/8002/` |

계정은 `kong_admin` / `.env` 의 `KONG_ADMIN_PASSWORD`. 접속 방식을 바꾼 뒤에는 `bash stop.sh && bash start.sh`.

Manager 화면에서 비밀번호를 바꾸면 **로그인 비밀번호만** 바뀌고, 스크립트가 쓰는 Admin API 토큰은 처음 값(`KONG_ADMIN_PASSWORD`)
그대로입니다. `.env` 의 `KONG_ADMIN_PASSWORD` 는 고치지 말고, 새 비밀번호는 `KONG_MANAGER_PASSWORD` 에 적으세요(`verify.sh` 의 로그인 점검용). 넣는 법 — 아래를 붙여 넣고 묻는 곳에 새 비밀번호를 입력합니다 (화면에 안 보임).

```bash
read -rsp 'Manager 비밀번호: ' P; echo
sed -i '/^KONG_MANAGER_PASSWORD=/d' .env; printf 'KONG_MANAGER_PASSWORD=%s\n' "$P" >> .env; unset P
```

---

## 요구사항 → 설정

| ID | 요구사항 | Kong 구현 | 설정 파일 | 점검 경로 (`verify.sh`) |
|---|---|---|---|---|
| 1-1 | 멀티 모델 단일 엔드포인트 | 같은 주소 `/v1/chat/completions` + 헤더 `x-ai-target` 로 대상 선택 (`ai-proxy-advanced`·`ai-proxy`) | 10 · 11 · 12 · 13 · 14 · 15 | 통합 경로·대상별 실제 호출 |
| 1-2 | 스트리밍 · 첫 토큰 지연 10ms 이내 | SSE 를 조각마다 바로 전달 (`response_buffering: false`) | 모든 채팅 경로 | `/features/stream` — LLM 직접 호출과 5회 비교 |
| 1-3 | OCR 10MB+ · Agent 장기 연결 | 업로드 상한 50MB(`request-size-limiting`) · 응답 대기 600초 | 40 | `/ocr` 12MB · `/agents/a` 70초 |
| 1-4 | 장애 시 대체 모델 (SD-04-17) | 우선순위 분산 + 실패 시 다음 모델 (`ai-proxy-advanced` priority·failover) | 11 · 20 | `/features/failover` |
| 2-1 | SSO · 부서별 API 키 (SD-01-3) | 부서별 사용자·키(`key-auth`) · 사내 IdP 토큰(`openid-connect`) | 00 · 50 | 키 없음 401 · 부서 키 200 |
| 2-2 | 키별 Agent 접근 통제 403 (PD-05-31) | 부서 그룹별 허용(`acl`) | 00 · 40 | team-a 키로 agent-b → 403 |
| 2-3 | 호출 수·토큰 한도 429 (RL-08-81) | 분당·일일 호출 수(`rate-limiting`) · 분당 토큰(`ai-rate-limiting-advanced`) | 10 · 20 | `/features/rate-limit` · `/features/token-limit` |
| 3-1 | 감사 로그 (MN-02-76) | 요청마다 한 줄(`file-log`) + 중앙 저장소 전송(`http-log`) · 관리 작업 이력(DB) | 00 · 61 | 추적 ID 로 기록 찾기 |
| 3-2 | Correlation ID 분산 추적 (MN-06-86) | `X-Correlation-ID`(`correlation-id`) · OpenTelemetry(`opentelemetry`) | 00 · 60 | Agent 까지 같은 ID |
| 3-3 | 이상 징후 경보 (MN-03-79) | 사용자·경로별 지표(`prometheus`) + 경보 규칙 예시 | 00 · `alerts/` | `:8100/metrics` |
| 3-4 | Kill-Switch (MN-01-73) | 계정·서비스마다 꺼 둔 `request-termination` — Manager 에서 켜면 즉시 차단 | 00 · 10 · 40 | `--full` 에서 켰다 끔 |
| 4-1 | 개인정보 마스킹 (PO-02-59) | 주민·카드·전화·계좌·이메일 → `[주민등록번호]` 등 (`pre-function`) | 00 | 모의 LLM 이 받은 질문 확인 |
| 4-2 | 기밀 키워드 외부 전송 차단 (PO-02-60) | `대외비`·`기밀` 등 → 외부로 갈 수 있는 경로에서 400 (`ai-prompt-guard`) | 10 · 12 | `/features/dlp` |
| 4-3 | 프롬프트 인젝션 차단 (PO-01-57) | 정규식(`ai-prompt-guard`) + 의미 기반(`ai-semantic-prompt-guard`) | 10 · 70 | `/features/injection` · `/features/semantic-guard` |
| 4-4 | 유해 답변 → 표준 문구 (PO-05-65) | 답변을 PII 가드로 검사, 유해하면 표준 문구 (`ai-custom-guardrail`) | 10 | `/features/output-guard` |
| 4-5 | 답변 속 내부 IP·키·DB 정보 마스킹 (PO-06-67) | 답변의 사설 IP·API 키·DB 접속 정보 → `[내부IP]`·`***` (`post-function`) | 10 | `/features/output-mask` |

설정 파일 번호: `00-base` 공통 · `10-llm` 통합 경로 · `11-target-*` 통합 경로의 LLM(장애 대체) · `12`~`15` 모델 선택 ·
`20-features` 기능별 경로 · `40-ocr-agents` · `50-sso` · `60-otel` · `61-http-log` · `70-semantic` 임베딩 기능.

> **3-1 위변조 방지**: 게이트웨이는 모든 요청을 즉시 중앙 저장소로 보냅니다(`DECK_LOG_HTTP_URL`). 위변조 불가는 받는 쪽
> 보관 정책(WORM 버킷·SIEM)으로 완성합니다. 파드 안 파일(`data/logs/audit.log`)은 보조 기록입니다.

---

## 통합 경로와 기능별 경로

### 통합 경로 `/v1/chat/completions`

모든 기능을 **겹쳐 붙이고** `.env` 의 스위치로 필요한 것만 켭니다. 실제 서비스와 같은 모습으로 시험할 때 씁니다.

| 스위치 (`.env`) | 기본 | 기능 |
|---|---|---|
| `FEATURE_MASKING` | on | 4-1 개인정보 마스킹 (모든 채팅 경로) |
| `FEATURE_ACL` | on | 2-2 허용 그룹만 |
| `FEATURE_RATE_LIMIT` | on | 2-3 호출 수 (`DECK_RPM`·`DECK_RPD`) |
| `FEATURE_TOKEN_LIMIT` | on | 2-3 토큰 (`DECK_TPM`) |
| `FEATURE_PROMPT_GUARD` | on | 4-2 기밀 키워드 · 4-3 인젝션 |
| `FEATURE_OUTPUT_GUARD` | off | 4-4 유해 답변 → 표준 문구 |
| `FEATURE_OUTPUT_MASK` | off | 4-5 답변 속 시스템 정보 마스킹 |
| `FEATURE_SEMANTIC_GUARD` | off | 4-3 의미 기반 가드 (임베딩 모델 필요) |
| `FEATURE_SEMANTIC_CACHE` | off | 시맨틱 캐시 (임베딩 모델 필요) |

스위치를 바꾼 뒤 `bash apply-config.sh`. **답변 검사(OUTPUT_GUARD·OUTPUT_MASK)를 켜면 통합 경로는 스트리밍 요청을 받지
않습니다** — 조각으로 나뉜 답은 검사할 수 없어서입니다 (`"stream": true` 요청은 400).
Kong Manager 에서 플러그인을 직접 켜고 꺼도 되지만, 다음 `apply-config.sh` 때 `.env` 값으로 돌아갑니다.

**요청 본문의 `model` 은 게이트웨이가 지우고 설정된 모델을 씁니다** — OpenAI SDK 처럼 `model` 을 항상 보내는 앱도
그대로 붙고, 대상은 헤더 `x-ai-target` 으로 고릅니다. 클라이언트가 보낸 이름은 요청 로그의 `client_model` 에 남습니다.

통합 경로의 LLM: 사내 LLM(`DECK_CHAT_URL`) → 실패하면(503·429·5xx·연결 실패·시간 초과) 외부 LLM(`DECK_EXT_URL`, 또는
`FALLBACK=azure` 면 Azure)으로 같은 요청을 다시 보냅니다. 클라이언트는 응답 헤더 `X-Kong-LLM-Model` 로 실제 모델을 봅니다.

### 모델 선택 — 헤더 `x-ai-target`

같은 주소에 헤더만 붙여 대상을 고릅니다: `internal`(사내 LLM 만 · 기밀 키워드 허용) · `external` · `azure` · `gcp` · `aws`.
`.env` 에 값이 있는 대상만 만들어집니다. 외부로 나가는 대상은 기밀 키워드를 차단합니다.

### 기능별 경로 `/features/<기능>/v1/chat/completions`

기능 **하나만** 붙인 시험용 경로입니다. LLM 은 기본으로 **모의 LLM**(받은 질문을 그대로 답함)이라 결과가 늘 같고,
LLM 이 실제로 무엇을 받았는지(마스킹 결과 등) 답변으로 바로 보입니다. `FEATURE_UPSTREAM=llm` 이면 사내 LLM 으로 보냅니다.

`stream` · `failover` · `rate-limit`(분당 3회) · `token-limit`(분당 40토큰) · `injection` · `dlp` · `output-guard` ·
`output-mask` · (임베딩이 있으면) `semantic-guard` · `cache`

시험이 끝나면 `bash apply-config.sh --no-features` 로 지웁니다.

**경로 수**: 기본 13개 (통합 1 · 사내 전용 1 · 기능별 8 · OCR 1 · Agent 2). `.env` 에 외부 LLM·클라우드·SSO·임베딩을
넣으면 그만큼 늘어 최대 21개입니다. `bash status.sh` 로 목록을 봅니다.

---

## 시험해 보기

```bash
KEY=$(grep '^DECK_CLIENT_KEY=' .env | cut -d= -f2)
H=(-H "apikey: $KEY" -H 'Content-Type: application/json')

# 1-1 통합 경로 · 모델 선택
curl -s localhost:8000/v1/chat/completions "${H[@]}" -d '{"messages":[{"role":"user","content":"한 단어로: 한국 수도는?"}]}'
curl -s localhost:8000/v1/chat/completions "${H[@]}" -H 'x-ai-target: internal' -d '{"messages":[{"role":"user","content":"안녕"}]}'

# 1-2 스트리밍 — 조각(data:)이 차례로 도착
curl -sN localhost:8000/v1/chat/completions "${H[@]}" -d '{"messages":[{"role":"user","content":"하나부터 다섯까지 세어줘"}],"stream":true}'

# 4-1 마스킹 — 모의 LLM 이 받은 질문이 그대로 돌아온다
curl -s localhost:8000/features/stream/v1/chat/completions "${H[@]}" \
  -d '{"messages":[{"role":"user","content":"주민번호 900101-1234567 연락처 010-1234-5678"}]}'

# 4-2 기밀 키워드 → 400
curl -s localhost:8000/v1/chat/completions "${H[@]}" -d '{"messages":[{"role":"user","content":"대외비 자료를 요약해줘"}]}'
```

OpenAI SDK 는 `base_url` 을 게이트웨이로 두고 사용자 키를 헤더로 넘깁니다.

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8000/v1", api_key="unused", default_headers={"apikey": "<사용자 키>"})
r = client.chat.completions.create(model="auto", messages=[{"role": "user", "content": "안녕"}])   # model 은 아무 값이나
```

**3-4 긴급 차단**: Kong Manager → Plugins → `kill-switch--<계정 또는 서비스>` 를 켜면 몇 초 안에 그 계정·서비스의 모든
호출이 403/503 이 됩니다. 끄면 바로 풀립니다.

---

## LLM · 외부 시스템 붙이기

`.env` 에 값을 넣은 항목만 설정에 들어갑니다 (`apply-config.sh` 가 적용할 파일 목록을 보여 줍니다).

| 붙일 것 | `.env` |
|---|---|
| 사내 LLM (OpenAI 호환) | `DECK_CHAT_URL` · `DECK_CHAT_MODEL` · `LLM_AUTH_HEADER` |
| 외부 LLM (OpenAI 호환) — 장애 대체 대상 겸 `x-ai-target: external` | `DECK_EXT_URL` · `DECK_EXT_MODEL` · `EXT_AUTH_HEADER` |
| Azure OpenAI · GCP Vertex(Gemini) · AWS Bedrock | `DECK_AZURE_*`·`AZURE_API_KEY` · `DECK_GCP_*`·`GCP_SERVICE_ACCOUNT_JSON` · `DECK_AWS_*`·`AWS_*` |
| OCR · Agent | `DECK_OCR_URL` · `DECK_AGENT_A_URL` · `DECK_AGENT_B_URL` (비우면 모의 서버) |
| 사내 SSO (OIDC) | `DECK_OIDC_ISSUER` · `DECK_OIDC_CLIENT_ID` · `OIDC_CLIENT_SECRET` → `/sso/v1/chat/completions` |
| 중앙 로그 · 분산 추적 | `DECK_LOG_HTTP_URL` · `DECK_OTEL_ENDPOINT` |
| 임베딩 (의미 기반 가드·시맨틱 캐시) | `DECK_EMBED_URL` · `DECK_EMBED_MODEL` · `DECK_EMBED_DIMS` · `EMBED_AUTH_HEADER` |

```bash
bash stop.sh && bash start.sh     # 인증 헤더·키는 Kong 이 기동할 때 읽는다
bash apply-config.sh --dry-run    # 무엇이 바뀌는지 먼저 보기
bash apply-config.sh
bash verify.sh
```

- 인증 헤더·API 키는 설정에 값으로 들어가지 않고 Kong Vault(`{vault://env/...}`)로 참조됩니다 — Manager 에 노출되지 않습니다.
- **LLM 주소가 IP 여도 됩니다.** Kong 에는 `ip-10-1-2-3.kong-poc` 같은 이름으로 넘깁니다(아래 「Kong 3.16 에서 확인한 것」).
  이때 LLM 서버가 받는 `Host` 헤더도 그 이름이 되므로, Host 로 서비스를 가르는 서버(인그레스 등)는 이름 주소를 쓰세요.

---

## 라이선스

| 라이선스 상태 | Kong 동작 (실측) | 스크립트 |
|---|---|---|
| 유효 | 전부 동작 | — |
| 만료 후 유예 기간 (Kong 로그 기준 약 30일) | 전부 동작 — 설정 변경·로그인·Enterprise 플러그인 포함 | 경고 |
| 없음 · 유예 종료 | **읽기 전용** — 설정 쓰기 403. 기존 설정으로 프록시는 계속 처리, Manager 로그인·조회 가능 | `apply-config.sh` 가 멈춤 |

라이선스를 넣거나 바꾼 뒤에는 `bash stop.sh && bash start.sh` (Kong 은 기동할 때 라이선스를 읽습니다).
AI 플러그인(`ai-proxy-advanced`·`ai-rate-limiting-advanced`·`ai-custom-guardrail`·`ai-semantic-*`)은 라이선스에
**AI Gateway 권한**이 있어야 정식입니다. 권한이 없어도 동작은 하지만 호출마다 Kong 오류 로그에 경고가 남습니다(`verify.sh` 가 알려 줌).

---

## 스크립트

| 스크립트 | 하는 일 |
|---|---|
| `start.sh` | 설치(없으면)·기동. 여러 번 실행해도 안전. 파드를 다시 만들었거나 Kong 버전이 바뀌면 다시 설치하고 DB 를 맞춤 |
| `apply-config.sh` | `conf/` 를 Kong 에 적용. `--dry-run` 미리 보기 · `--no-features` 기능별 경로 빼기. `kong-poc` 태그가 붙은 것만 관리 |
| `verify.sh` | 환경·설치·접속·요구사항별 점검. `--full` 은 장기 연결·긴급 차단까지 실제로 |
| `verify-remote.py` | **파드 밖 PC 에서** 외부 주소로 요구사항 점검 (Python 표준 라이브러리만 — Windows·macOS·Linux). [VERIFY.md](VERIFY.md) 3절 |
| `status.sh` | 프로세스·경로 목록 |
| `logs.sh` | 요청 로그 요약 · `-f` 실시간 · `export DIR` · `admin`(설정 변경 이력) |
| `dump-config.sh` | 지금 설정을 `conf/backup/` 에 파일로 (Manager 에서 바꾼 것 포함) |
| `stop.sh` | 정지 (데이터는 남김) |
| `install.sh` | 프로그램만 설치 (`start.sh` 가 필요할 때 부름) |
| `kong-check.sh` | 설치 전 환경 점검 |

- DB·로그·pgvector 빌드 결과는 `data/`(`DATA_DIR`)에 둡니다. **파드를 다시 만들어도 남는 경로**여야 합니다.
  파드를 다시 만들면 `bash start.sh` 한 번으로 다시 설치하고 기존 데이터·설정으로 이어서 뜹니다 (약 1분).
- 포트: 프록시 `:8000` · Admin API `:8001` · Manager `:8002` · 지표 `:8100` · PostgreSQL `127.0.0.1:5432` · PII 가드 `127.0.0.1:18080` · 모의 서버 `127.0.0.1:18090`.

---

## 로그

| 로그 | 내용 | 저장 위치 | 보관 |
|---|---|---|---|
| **요청 로그** | 모든 호출 — 사용자, 경로, 상태, 모델, 토큰 수, 지연, 추적 ID, 마스킹 건수 | `data/logs/audit.log` (+ `DECK_LOG_HTTP_URL`) | 삭제할 때까지 |
| **관리 감사로그** | Admin API·Kong Manager 로 설정을 바꾼 이력 — 누가, 언제, 무엇을 | PostgreSQL (`audit_requests`) | 30일 후 자동 삭제 |
| Kong 오류 로그 | 기동·플러그인 오류 | `data/logs/kong-error.log` | 삭제할 때까지 |

**기록하지 않는 것**: 요청·응답 본문(`log_payloads: false`), 사용자 키(`hide_credentials`), 업스트림 인증 헤더, LLM 응답 헤더.

---

## Kong 3.16 에서 확인한 것

시험 중 확인한 동작과 이 저장소의 대응입니다.

| 확인한 동작 | 대응 |
|---|---|
| AI 플러그인의 LLM 주소(`upstream_url`)가 **IP 면** 장애 대체가 되지 않고, 서비스 주소와 다른 호스트로 보내지도 못함. 이름 주소는 정상 | IP 에 이름(`ip-a-b-c-d.kong-poc`)을 붙여 넘기고, 그 이름은 Kong 만 읽는 hosts 파일(`~/.kong-poc/hosts`)에 적음. 시스템 `/etc/hosts` 는 그대로 |
| 경로 기본값(`response_buffering: true`)이면 SSE 응답을 **다 모아 한 번에** 보냄 — 첫 토큰이 마지막 토큰과 같이 도착 | 채팅·Agent 경로는 `response_buffering: false`. 첫 조각 지연 2ms 안팎 |
| Kong 기동 직후 처음 20~30번 요청은 몇 ms 더 느림 (워커가 코드를 데우는 중 — 쉬기만 해서는 안 풀리고 요청이 지나가야 풀림) | `verify.sh` 는 지연을 재기 전에 30번 먼저 보낸다 |
| 의미 기반 가드(`ai-semantic-prompt-guard`)가 vault 로 넣은 벡터 DB 비밀번호를 읽지 못함 (`missing password`) | 벡터 DB(`kong-pgvector`)만 파드 안(127.0.0.1)에서 비밀번호 없이 접속. Kong DB 는 계속 비밀번호 |
| Kong 기본 PII 서비스(`ai-sanitizer` + PII 컨테이너)는 한국 개인정보 형식을 거의 못 잡고 컨테이너가 필요 | 4-1 은 `pre-function`(정규식), 문맥 판정은 PII 가드(`addons/pii-guard`) |
| `ai-custom-guardrail` 은 차단(block)만 하고 문장 일부를 바꾸지 못함 | 4-4 는 표준 문구로 대체, 4-5 는 `post-function` 으로 마스킹 |
| 요청 본문에 `model` 이 있으면 설정과 다른 이름은 400(`cannot use own model`), **같은 이름이어도 장애 대체가 일어나지 않음** (OpenAI SDK 는 항상 보냄) | 채팅 요청 공통 전처리(`00-base.yaml` 의 `chat-preprocess`)가 `model` 을 지움 — 끄지 말 것 |
| curl 로 큰 파일을 보내면 `Expect: 100-continue` 때문에 상한 초과가 413 이 아니라 417(화면엔 400)로 보임 | 정상 거절. 확인할 때는 `-H 'Expect:'` |

---

## 검증

고객 파드와 같은 조건으로 재현한 환경 — Ubuntu 22.04 · uid 3000 · sudo · JupyterLab + jupyter-server-proxy ·
4 vCPU / 8 GB · 8080 사용 중 · Kong·Release·PGDG·OpenAI 도메인 차단 — 에서 Kong 3.16.0.0 으로 확인했습니다.

| 항목 | 결과 |
|---|---|
| `verify.sh --full` (라이선스·사내 LLM·외부 LLM·임베딩 연결) | **OK 38 · 주의 2 · 불가 0** — 주의는 라이선스 만료 유예·AI Gateway 권한 없음 |
| 1-2 첫 토큰 지연 (게이트웨이가 더한 것, 10회 중앙값) | 1.5~2.3ms · Kong 재기동 직후 5~6ms |
| 1-4 장애 대체 | 주 모델 503·연결 거부 → 보조 모델 응답 (같은 호스트·다른 호스트의 실제 LLM 모두) |
| 통합 경로 스위치 | 답변 마스킹 켬·호출 한도 끔 → 적용 → 실제 LLM 답변 마스킹 확인 → 되돌림 |
| 파드 밖 PC 에서 `verify-remote.py --full` | **OK 21 · 주의 0 · 불가 0** — OpenAI SDK(일반·스트리밍·`x-ai-target`·차단 예외)도 확인 |
| 3.15.0.6 → 3.16.0.0 업그레이드 | 설치 파일 교체 후 `stop.sh`·`start.sh` — DB 자동 마이그레이션, 약 40초 |
| 파드 강제 재생성 | `start.sh` 한 번에 재설치 후 기존 DB·설정·로그로 기동 (약 1분) |

---

## 문제 해결

| 증상 | 원인 · 조치 |
|---|---|
| 외부 Manager 주소가 `upstream connect error … Connection refused` | Kong 이 8001·8002 를 파드 안에서만 받는 중 — `.env` 에 `MANAGER_URL`·`ADMIN_API_URL` 외부 주소, `JUPYTER_URL` 비움 → `bash stop.sh && bash start.sh` |
| Manager 로그인 후 목록이 비거나 401 | `MANAGER_URL`·`ADMIN_API_URL` 이 브라우저 접속 주소와 다름 |
| 비밀번호가 맞는데 로그인이 안 됨 | `.env` 값 뒤에 설명(`# …`)이 붙어 비밀번호의 일부로 읽힘 — 값 뒤 주석 제거 |
| `verify.sh` 가 Kong Manager 로그인 401 | Manager 에서 비밀번호를 바꿈 — `.env` 의 `KONG_MANAGER_PASSWORD` 에 새 비밀번호 (`KONG_ADMIN_PASSWORD` 는 그대로) |
| `apply-config.sh` 가 라이선스 때문에 멈춤 / 설정 변경 403 | 라이선스가 없거나 유예 기간도 끝남 — `secrets/license.json` 확인 후 `bash stop.sh && bash start.sh` |
| 통합 경로에 `"stream": true` 요청이 400 `response streaming is not enabled` | 답변 검사(`FEATURE_OUTPUT_GUARD`·`FEATURE_OUTPUT_MASK`)가 켜져 있음 — 정상 동작 |
| LLM 호출이 503 `name resolution failed` | LLM 주소의 호스트 이름을 파드에서 찾을 수 없음 — 주소 확인. IP 를 바꿨다면 `bash apply-config.sh` 가 Kong 에 새 이름을 반영 |
| `start.sh` 가 설치 중 멈춤 | `data/logs/install.log` 끝부분 확인 (apt 저장소 접속·디스크) |
| 임베딩 호출이 400 | 임베딩 서버가 `dimensions` 파라미터를 거부 — 게이트웨이의 `/ai/embed` 가 제거하므로 그 경로를 쓰는지 확인 |
