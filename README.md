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

> **설정 파일** — 처음 설치할 때는 저장소의 `.env` 입니다. 유지 폴더를 정하면(`bash set-data-dir.sh`, 아래 「유지 폴더」)
> 설정 전체가 `<유지 폴더>/kong-poc/settings.env` 로 옮겨지고 저장소 `.env` 에는 그 위치 한 줄만 남습니다.
> 그 뒤로는 어디 있든 `bash set-env.sh <키> <값>` 으로 고칩니다. 이 문서의 「`.env` 의 …」는 그 설정 파일을 말합니다.

---

## 처음 설치

```bash
cd /project/work/flow                     # 파드를 다시 만들어도 남는 경로 (빌드하면 이 아래가 스냅샷이 됨)
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

- `.env` 는 숨김 파일이라 주피터 탐색기에서 바로 안 열립니다. 값 하나는 `bash set-env.sh <키> <값>` 으로 바꿉니다
  (비밀번호처럼 화면에 남기기 싫은 값은 `bash set-env.sh <키>` — 입력을 묻고 화면에 안 보임).
- **라이선스**: 주피터 탐색기로 아무 폴더에나 올린 뒤 `bash set-license.sh <올린 파일>` — 제자리에 넣어 줍니다.

```bash
bash start.sh          # 설치 → DB → 마이그레이션 → PII 가드·모의 서버 → Kong (처음 약 2분)
bash apply-config.sh   # 요구사항별 설정 적용 (라이선스 필요)
bash verify.sh         # 요구사항별 점검 — 요약이 「불가 0」이면 됩니다
```

파드를 다시 만들어도 남는 **유지 폴더(PV)**가 따로 있으면 `start.sh`·`apply-config.sh` 대신
`bash set-data-dir.sh <유지 폴더>` 하나로 설치·기동·설정 적용까지 합니다 (아래 「유지 폴더」).

`bash verify.sh --full` 은 70초 장기 연결·긴급 차단 켜고 끄기까지 실제로 해 봅니다 (약 2분).
항목별로 하나씩 보여 주는 방법과 **파드 밖(PC)에서 외부 주소로 검증하는 방법**은 [VERIFY.md](VERIFY.md) 에 있습니다.

### Kong Manager 접속

Kong Manager 는 **브라우저가 Admin API(8001)를 직접 부르므로** 8002 와 8001 이 둘 다 브라우저에서 닿아야 합니다.

| 방식 | `.env` | 브라우저 주소 |
|---|---|---|
| **플랫폼이 8000·8001·8002 를 밖으로 연 경우** | `MANAGER_URL=<8002 주소>` · `ADMIN_API_URL=<8001 주소>` · `JUPYTER_URL=` (비움) | `MANAGER_URL` |
| 주피터를 거쳐 여는 경우 (`jupyter-server-proxy`) | `JUPYTER_URL=<주피터 주소>` | `<JUPYTER_URL>/proxy/absolute/8002/` |

계정은 `kong_admin` / 설정 파일의 `KONG_ADMIN_PASSWORD`. 접속 방식을 바꾼 뒤에는 `bash stop.sh && bash start.sh`.

Manager 화면에서 비밀번호를 바꾸면 **로그인 비밀번호만** 바뀌고, 스크립트가 쓰는 Admin API 토큰은 처음 값(`KONG_ADMIN_PASSWORD`)
그대로입니다. `KONG_ADMIN_PASSWORD` 는 고치지 말고, 새 비밀번호는 `KONG_MANAGER_PASSWORD` 에 넣으세요(`verify.sh` 의 로그인 점검용).
아래 명령을 실행하고 묻는 곳에 새 비밀번호를 입력합니다 (화면에 안 보임).

```bash
bash set-env.sh KONG_MANAGER_PASSWORD
```

**관리자 추가** — Kong Manager 왼쪽 **Teams** → **Admins** → **+ Invite Admin** 에서 이메일·사용자 이름을 넣고 **Add/Edit Roles** 로
워크스페이스(`default`)와 역할을 고른 뒤 **Invite Admin**. 메일 발송은 꺼져 있으므로(`smtp_mock`) 초대 목록(Invited)에서 그 관리자를 열고
**Generate registration link** 로 만든 가입 링크(72시간 유효)를 본인에게 전합니다. 본인이 링크에서 비밀번호를 정하면 바로 로그인됩니다.

| 역할 | 할 수 있는 것 |
|---|---|
| `super-admin` | 전부 — 관리자 초대·역할 관리 포함 |
| `admin` | 관리자·역할 관리(RBAC)를 뺀 전부 — 경로·플러그인·사용자 편집 |
| `read-only` | 보기만 |

관리자는 DB 에 저장되므로 다시 빌드해도 남고, 번들 설정 적용(`apply-config.sh`)도 건드리지 않습니다.

---

## 요구사항 → 설정

| ID | 요구사항 | Kong 구현 | 설정 파일 | 점검 경로 (`verify.sh`) |
|---|---|---|---|---|
| 1-1 | 멀티 모델 단일 엔드포인트 | 같은 주소 `/v1/chat/completions` — 두 LLM 이면 요청의 `model` 로 선택(`ai-proxy-advanced` `model_alias`) · 헤더 `x-ai-target` 로도 선택 | 00 · 10 · 11 · 12 · 13 · 14 · 15 | 통합 경로·대상별·모델별 실제 호출 |
| 1-2 | 스트리밍 · 첫 토큰 지연 10ms 이내 | SSE 를 조각마다 바로 전달 (`response_buffering: false`) | 모든 채팅 경로 | ① `/poc/1` — LLM 직접 호출과 10회 비교 |
| 1-3 | OCR 10MB+ · Agent 장기 연결 | 업로드 상한 50MB(`request-size-limiting`) · 응답 대기 600초 | 40 | `/ocr` 12MB · `/agents/a` 70초 |
| 1-4 | 장애 시 대체 모델 (SD-04-17) | 우선순위 분산 + 실패 시 다음 모델 (`ai-proxy-advanced` priority·failover) | 11 · 20 | ① `/poc/1` + 헤더 `X-Mock-Down` 으로 주 모델 장애 |
| 2-1 | SSO · 부서별 API 키 (SD-01-3) | 부서별 사용자·키(`key-auth`) · 사내 IdP 토큰(`openid-connect`) | 00 · 20 · 50 | ② `/poc/2` 키 없음·틀린 키 401 · 부서 키 200 |
| 2-2 | 키별 Agent 접근 통제 403 (PD-05-31) | 부서 그룹별 허용(`acl`) | 00 · 40 | team-a 키로 agent-b → 403 |
| 2-3 | 호출 수 한도 429 (RL-08-81) | 사용자별 분당·일일 호출 수(`rate-limiting`) | 10 · 20 | ② `/poc/2` 분당 3회 |
| 2-4 | 토큰·비용 한도 429 | 사용자별 분당 토큰·예상 비용(`ai-rate-limiting-advanced` — `total_tokens`·`cost`) | 10 · 20 | ② `/poc/2` 분당 40토큰 · 예상 비용 0.1 |
| 3-1 | 감사 로그 (MN-02-76) | 요청마다 한 줄(`file-log`) + 중앙 저장소 전송(`http-log`) · 관리 작업 이력(DB) | 00 · 61 | ③ `/poc/3` 추적 ID 로 기록 찾기 |
| 3-2 | Correlation ID 분산 추적 (MN-06-86) | `X-Correlation-ID`(`correlation-id`) · OpenTelemetry(`opentelemetry`) | 00 · 60 | Agent 까지 같은 ID |
| 3-3 | 이상 징후 경보 (MN-03-79) | 사용자·경로별 지표(`prometheus`) + 경보 규칙 예시 | 00 · `alerts/` | `:8100/metrics` |
| 3-4 | Kill-Switch (MN-01-73) | 계정·서비스마다 꺼 둔 `request-termination` — Manager 에서 켜면 즉시 차단 | 00 · 10 · 20 · 40 | ③ `/poc/3` 스위치를 `--full` 에서 켰다 끔 |
| 4-1 | 개인정보 마스킹 (PO-02-59) | 주민·카드·전화·계좌·이메일 → `[주민등록번호]` 등 (`pre-function`) | 00 | ④ `/poc/4` 모의 LLM 이 받은 질문 확인 |
| 4-2 | 기밀 키워드 외부 전송 차단 (PO-02-60) | `대외비`·`기밀` 등 → 외부로 갈 수 있는 경로에서 400 (`ai-prompt-guard`) | 10 · 12 · 20 | ④ `/poc/4` |
| 4-3 | 프롬프트 인젝션 차단 (PO-01-57) | 정규식(`ai-prompt-guard`) + 의미 기반(`ai-semantic-prompt-guard`) | 10 · 20 · 21 · 70 | ④ `/poc/4` — 의미 기반은 임베딩이 있을 때 |
| 4-4 | 유해 답변 → 표준 문구 (PO-05-65) | 키워드(PII 가드 `ai-custom-guardrail`) + 의미 기반(`ai-semantic-response-guard`) | 10 · 20 · 21 | ④ `/poc/4` — 의미 기반은 임베딩이 있을 때 |
| 4-5 | 답변 속 내부 IP·키·DB 정보 마스킹 (PO-06-67) | 답변의 사설 IP·API 키·DB 접속 정보 → `[내부IP]`·`***` (`post-function`) | 10 · 20 | ④ `/poc/4` — 모의 LLM 이 「점검 결과」 질문에 내부 정보를 섞어 답함 |

킥오프 자료 기준 네 영역 17개입니다 — ① 서비스 등록·연동(1-1~1-4) · ② 접근·사용량 제어(2-1~2-4) · ③ 이력·감사(3-1~3-4) ·
④ 가드레일(4-1~4-5). 예전 2-3 의 토큰 한도는 2-4(토큰·비용)로 나눴습니다.

설정 파일 번호: `00-base` 공통 · `10-llm` 통합 경로 · `11-target-*` 통합 경로의 LLM(장애 대체) · `12`~`15` 모델 선택 ·
`20-areas` 영역별 시험 경로 · `21-areas-semantic` 영역 ④ 의미 기반 가드 · `40-ocr-agents` · `50-sso` · `60-otel` ·
`61-http-log` · `70-semantic` 임베딩 기능.

> **3-1 위변조 방지**: 게이트웨이는 모든 요청을 즉시 중앙 저장소로 보냅니다(`DECK_LOG_HTTP_URL`). 위변조 불가는 받는 쪽
> 보관 정책(WORM 버킷·SIEM)으로 완성합니다. 파드 안 파일(`data/logs/audit.log`)은 보조 기록입니다.

---

## 통합 경로와 영역별 시험 경로

### 통합 경로 `/v1/chat/completions`

모든 기능을 **겹쳐 붙이고** `.env` 의 스위치로 필요한 것만 켭니다. 실제 서비스와 같은 모습으로 시험할 때 씁니다.

| 스위치 (`.env`) | 기본 | 기능 |
|---|---|---|
| `FEATURE_MASKING` | on | 4-1 개인정보 마스킹 (모든 채팅 경로) |
| `FEATURE_ACL` | on | 2-2 허용 그룹만 |
| `FEATURE_RATE_LIMIT` | on | 2-3 호출 수 (`DECK_RPM`·`DECK_RPD`) |
| `FEATURE_TOKEN_LIMIT` | on | 2-4 토큰 (`DECK_TPM`) |
| `FEATURE_PROMPT_GUARD` | on | 4-2 기밀 키워드 · 4-3 인젝션 |
| `FEATURE_OUTPUT_GUARD` | off | 4-4 유해 답변 → 표준 문구 |
| `FEATURE_OUTPUT_MASK` | off | 4-5 답변 속 시스템 정보 마스킹 |
| `FEATURE_SEMANTIC_GUARD` | off | 4-3 의미 기반 가드 (임베딩 모델 필요) |
| `FEATURE_SEMANTIC_CACHE` | off | 시맨틱 캐시 (임베딩 모델 필요) |

스위치를 바꾼 뒤 `bash apply-config.sh`. **답변 검사(OUTPUT_GUARD·OUTPUT_MASK)를 켜면 통합 경로는 스트리밍 요청을 받지
않습니다** — 조각으로 나뉜 답은 검사할 수 없어서입니다 (`"stream": true` 요청은 400).
Kong Manager 에서 플러그인을 직접 켜고 꺼도 되지만, 다음 `apply-config.sh` 때 `.env` 값으로 돌아갑니다.
기능 플러그인은 모두 **경로(Route)에** 붙어 있습니다(전역 플러그인·계정 긴급 차단 제외) — Kong Manager 의 Routes → 경로 → Plugins 에서
그 경로에 걸리는 기능을 한 화면에 봅니다. (2026-10-06 판부터. 예전 판은 서비스에 붙어 있었고, 새 판을 적용하면 경로로 옮겨집니다 —
이름 있는 플러그인(긴급 차단 스위치 등)은 `apply-config.sh` 가 먼저 지우고 다시 만들므로 켜 둔 스위치는 꺼짐으로 돌아갑니다.)

**요청 본문의 `model` 은 게이트웨이가 지우고 설정된 모델을 씁니다** — OpenAI SDK 처럼 `model` 을 항상 보내는 앱도
그대로 붙습니다. 예외: LLM 을 둘 이상 넣으면 통합 경로에서는 `model` 이 등록된 LLM 의 모델 이름일 때 그 LLM 을 고릅니다
(아래 「모델 선택」). 클라이언트가 보낸 이름은 요청 로그의 `client_model` 에 남습니다.

통합 경로의 LLM: 사내 LLM(`DECK_CHAT_URL`) → 실패하면(503·429·5xx·연결 실패·시간 초과) 외부 LLM(`DECK_EXT_URL`, 또는
`FALLBACK=azure` 면 Azure)으로 같은 요청을 다시 보냅니다. 클라이언트는 응답 헤더 `X-Kong-LLM-Model` 로 실제 모델을 봅니다.

### 모델 선택 — 요청의 `model` · 헤더 `x-ai-target`

**OpenAI 호환 LLM 을 둘 이상 넣으면 통합 경로가 요청의 `model` 로 LLM 을 고릅니다** — 앱은 OpenAI 방식 그대로 `model` 에
모델 이름만 바꿔 넣으면 됩니다. LLM 자리: 1 사내 `DECK_CHAT_*` · 2 외부 `DECK_EXT_*` · **3번부터 `DECK_LLM<n>_*`** (번호를 늘려 계속).
`apply-config.sh` 가 통합 경로의 대상 파일(`11-target-*.yaml`) 끝에 LLM 마다 대상(`model_alias` = 모델 이름)을 붙여 적용합니다
(Kong Manager 의 Routes → `llm` → AI Proxy Advanced 에서 보임).

| 요청의 `model` | 답하는 LLM |
|---|---|
| 없음 · 등록되지 않은 이름 (예: SDK 기본값 `gpt-4o`) | 사내 LLM — 실패하면 외부 LLM 으로 장애 대체 (1-4) |
| 등록된 LLM 의 모델 이름 (`DECK_CHAT_MODEL` · `DECK_EXT_MODEL` · `DECK_LLM<n>_MODEL`) | 그 LLM 만 (`model_alias`) |

- 이름을 지정한 요청은 그 LLM 이 실패해도 다른 LLM 으로 넘어가지 않습니다(502). 장애 대체는 `model` 이 없거나 다른 이름일 때만입니다.
- 등록되지 않은 이름은 `chat-preprocess` 가 지웁니다 — 남겨 두면 400(`cannot use own model`)이 납니다.
- Kong 3.16 실측: 별칭(`model_alias`)이 없는 대상끼리 기본 묶음이고 별칭마다 따로 묶입니다. 기본 묶음이 없으면 `model` 없는 요청이
  500(`no targets configured for model alias: <default>`)이 되므로 기본 대상(1·2순위)은 그대로 두고 별칭 대상을 덧붙입니다.

**LLM 추가하기** — 빌드 없이 설정 값만 넣습니다 (3번부터 번호를 하나씩 늘림):

```bash
bash set-env.sh DECK_LLM3_URL 'https://llm3.example.internal/v1/chat/completions'
bash set-env.sh DECK_LLM3_MODEL 'your-third-model'
bash set-env.sh LLM3_AUTH_HEADER                 # 'Bearer 키' 입력 — 화면에 안 보임
bash stop.sh && bash start.sh && bash apply-config.sh   # 빌드한 새 환경이면 bash remote.sh restart · bash remote.sh apply
```

빼려면 그 LLM 의 `DECK_LLM<n>_URL` 을 비우고(`bash set-env.sh DECK_LLM3_URL ''`) 적용합니다. 모델 이름이 비어 있으면 적용이 멈추고 알려 줍니다.

**헤더 `x-ai-target`** 으로도 고를 수 있습니다: `internal`(사내 LLM 만 · 기밀 키워드 허용) · `external` · `azure` · `gcp` · `aws`.
`.env` 에 값이 있는 대상만 만들어집니다. 외부로 나가는 대상은 기밀 키워드를 차단합니다. 헤더로 고른 경로에서는 `model` 을 보지 않습니다.

### 영역별 시험 경로 `/poc/<영역>/v1/chat/completions`

검증 항목의 네 영역마다 경로 하나에 **그 영역의 플러그인만** 붙였습니다. Kong Manager 의 Routes 목록이 네 영역과 1:1 로 맞고,
Routes → `poc-…` → Plugins 에서 그 영역의 플러그인이 보입니다.
LLM 은 기본으로 **모의 LLM**(받은 질문을 그대로 답함)이라 결과가 늘 같고, LLM 이 실제로 무엇을 받았는지(마스킹 결과 등) 답변으로
바로 보입니다. `FEATURE_UPSTREAM=llm` 이면 사내 LLM 으로 보냅니다.

| 경로 | 영역 | 붙은 것 | 확인하는 항목 |
|---|---|---|---|
| `/poc/1` | ① 서비스 등록·연동 | 키 · `ai-proxy-advanced`(주 모델 → 보조 모델) | 1-2 스트리밍 · 1-4 장애 대체(헤더 `X-Mock-Down: mock-llm`) |
| `/poc/2` | ② 접근·사용량 제어 | 키 · 그룹 허용 · 호출 수(분당 3회·하루 1000회) · 토큰(분당 40)·예상 비용(분당 0.1) | 2-1 · 2-3 · 2-4 |
| `/poc/3` | ③ 이력·감사 | 키 · 긴급 차단 스위치(`kill-switch--poc-3`) — 로그·추적·지표는 전역 | 3-1 · 3-2 · 3-4 |
| `/poc/4` | ④ 가드레일 | 키 · 정규식 가드 · 키워드 답변 검사 · 답변 속 내부 정보 마스킹 (+ 임베딩이 있으면 의미 기반 질문·답변 가드) | 4-1 ~ 4-5 |

한도는 바로 확인되게 낮춘 시험값입니다(통합 경로의 한도는 `DECK_RPM`·`DECK_RPD`·`DECK_TPM`). 2-4 의 비용은 `/poc/2` 의
시험용 예시 단가(100만 토큰당 입력 1000·출력 2000)로 계산하며, 응답 헤더 `X-AI-RateLimit-Remaining-minute-policy-2` 에
남은 값이 보입니다(비용은 다음 요청부터 반영 — Kong 동작). 다른 경로를 쓰는 항목: 1-1 헤더 `x-ai-target` · 1-3 `/ocr`·`/agents` ·
2-1 SSO `/sso` · 2-2 `/agents`. 시험이 끝나면 `bash apply-config.sh --no-areas` 로 지웁니다.

**경로 수**: 기본 9개 (통합 1 · 사내 전용 1 · 영역 4 · OCR 1 · Agent 2). `.env` 에 외부 LLM·클라우드·SSO·임베딩을
넣으면 그만큼 늘어 최대 15개입니다. `bash status.sh` 로 목록을 봅니다.

---

## 시험해 보기

```bash
KEY=$(bash set-env.sh --get DECK_CLIENT_KEY)
H=(-H "apikey: $KEY" -H 'Content-Type: application/json')

# 1-1 통합 경로 · 모델 선택
curl -s localhost:8000/v1/chat/completions "${H[@]}" -d '{"messages":[{"role":"user","content":"한 단어로: 한국 수도는?"}]}'
curl -s localhost:8000/v1/chat/completions "${H[@]}" -H 'x-ai-target: internal' -d '{"messages":[{"role":"user","content":"안녕"}]}'

# 1-2 스트리밍 — 조각(data:)이 차례로 도착
curl -sN localhost:8000/v1/chat/completions "${H[@]}" -d '{"messages":[{"role":"user","content":"하나부터 다섯까지 세어줘"}],"stream":true}'

# 4-1 마스킹 — 모의 LLM 이 받은 질문이 그대로 돌아온다
curl -s localhost:8000/poc/4/v1/chat/completions "${H[@]}" \
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
| 두 번째 LLM (OpenAI 호환) — 장애 대체 대상 · 요청의 `model` 로 선택 · `x-ai-target: external` | `DECK_EXT_URL` · `DECK_EXT_MODEL` · `EXT_AUTH_HEADER` |
| 세 번째부터 LLM (OpenAI 호환) — 요청의 `model` 로 선택 | `DECK_LLM<n>_URL` · `DECK_LLM<n>_MODEL` · `LLM<n>_AUTH_HEADER` (n = 3, 4, …) |
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
| `run.sh` | **빌드한 새 환경의 시작 명령** — 설치(없으면)·기동 후 계속 떠 있으면서 멈춘 것을 다시 띄움. 종료 신호를 받으면 차례로 내림 (아래 「빌드해서 새 환경으로 돌리기」) |
| `remote.sh` | 빌드한 새 환경에 일을 맡김 — `status` · `apply` · `restart` · `verify` (같은 유지 폴더를 붙인 개발 파드에서) |
| `set-env.sh` | 설정 값 하나 바꾸기 — `bash set-env.sh <키> <값>` (설정 파일이 어디 있든 찾아서 고침) · `<키>` 만 주면 입력을 물음 |
| `set-license.sh` | 받은 라이선스 파일을 제자리에 넣기 — `bash set-license.sh <파일>` |
| `apply-config.sh` | `conf/` 를 Kong 에 적용. `--dry-run` 미리 보기 · `--no-areas` 영역별 시험 경로 빼기. `kong-poc` 태그가 붙은 것만 관리 |
| `verify.sh` | 환경·설치·접속·요구사항별 점검. `--full` 은 장기 연결·긴급 차단까지 실제로 |
| `verify-remote.py` | **파드 밖 PC 에서** 외부 주소로 요구사항 점검 (Python 표준 라이브러리만 — Windows·macOS·Linux). [VERIFY.md](VERIFY.md) 3절 |
| `status.sh` | 프로세스·경로 목록 |
| `logs.sh` | 요청 로그 요약 · `-f` 실시간 · `export DIR` · `admin`(설정 변경 이력) |
| `set-data-dir.sh` | **유지 폴더(PV) 지정** — 설정·라이선스·DB·로그·백업·점검 기록을 그 폴더로 옮긴다(저장소 `.env` 에는 위치만). 파드를 다시 만든 뒤 되살릴 때도 이것 하나 |
| `dump-config.sh` | 지금 설정을 `<데이터 폴더>/backup/` 에 파일로 (Manager 에서 바꾼 것 포함) |
| `stop.sh` | 정지 (데이터는 남김) |
| `install.sh` | 프로그램만 설치 (`start.sh` 가 필요할 때 부름) |
| `kong-check.sh` | 설치 전 환경 점검 |

- 포트: 프록시 `:8000` · Admin API `:8001` · Manager `:8002` · 지표 `:8100` · PostgreSQL `127.0.0.1:5432` · PII 가드 `127.0.0.1:18080` · 모의 서버 `127.0.0.1:18090`.

### 유지 폴더 (파드를 다시 만들어도 남길 파일)

기본으로는 DB·로그를 저장소 안 `data/` 에 둡니다. 플랫폼에 **파드를 다시 만들어도 남는 폴더(쿠버네티스의 PV 같은 곳)**가
따로 있으면 그곳을 지정합니다 — 처음 설치할 때든, 이미 쓰던 중이든 같은 명령입니다.

```bash
bash set-data-dir.sh --check <유지 폴더>   # 먼저 확인만 — 실제 위치·DB 를 둘 수 있는 저장소인지 (아무것도 바꾸지 않음)
bash set-data-dir.sh <유지 폴더>           # 예) bash set-data-dir.sh /datasets/DT0000000000/data
```

| `<유지 폴더>/kong-poc/` | 내용 |
|---|---|
| `pgdata/` | DB — Kong 설정 전체 · 관리 감사로그 · 벡터 DB(의미 기반 가드·캐시) |
| `logs/` | Kong 로그 전부 (아래 「로그」 표) · PostgreSQL · PII 가드 로그 |
| `backup/` · `reports/` | 설정 백업(`dump-config.sh`) · 점검 기록(`verify.sh` 를 돌릴 때마다 저장) |
| `settings.env` · `secrets/license.json` | 설정·라이선스 **원본** — `bash set-env.sh` · `bash set-license.sh` 로 고침. 저장소 `.env` 에는 이 폴더 위치 한 줄만 |
| `run.lock` · `requests/` | 지금 이 폴더로 돌고 있는 환경의 기록(20초마다 갱신) · `remote.sh` 가 맡긴 일과 결과 |
| `pgvector-*/` · `src/` | pgvector 빌드 결과 — 다시 설치할 때 빌드 없이 복사만 |

- **주피터 탐색기에 보이는 경로를 그대로 줘도 됩니다.** 탐색기의 `/datasets/…` 는 주피터 최상위 폴더 기준이라 파드 안의 절대 경로와
  다를 수 있어, 주피터 최상위 폴더 · `/project` · 홈 아래에서 찾고 없으면 깊이 6 까지 검색합니다 (찾은 위치를 알려 줌).
- 옮기기 전에 그 폴더가 DB 를 둘 수 있는지 확인하고(권한 700 · 파드와 함께 사라지는 overlay 나 오브젝트 스토리지(FUSE)·네트워크 공유가
  아닌지), 안 되면 아무것도 옮기지 않습니다. 실행 중이면 잠시 내렸다가 옮긴 뒤 다시 띄우고 설정까지 다시 적용합니다.
- 원래 자리는 지우지 않고 `data.moved-<시각>` 으로 남겨 둡니다 — 확인 후 지워도 됩니다.
- **파드를 다시 만들었으면**: 저장소를 받고(`git clone`) → `bash set-data-dir.sh <같은 유지 폴더>` 하나로 유지 폴더의 설정·DB 를 쓰도록
  위치를 적고 프로그램을 다시 설치해 기동합니다. `cp .env.example .env` 는 하지 마세요(새 비밀번호가 생겨 기존 DB 와 맞지 않음 —
  했더라도 유지 폴더의 설정을 쓰고 새로 만든 것은 `settings.env.from-repo-<시각>` 으로 보관합니다).
- 예전 방식(저장소 `.env` 가 원본, 유지 폴더엔 사본)으로 쓰던 저장소는 새 버전을 받은 뒤 아무 스크립트나 한 번(`bash status.sh`) 실행하면
  설정·라이선스가 유지 폴더로 옮겨집니다.
- 포트: 프록시 `:8000` · Admin API `:8001` · Manager `:8002` · 지표 `:8100` · PostgreSQL `127.0.0.1:5432` · PII 가드 `127.0.0.1:18080` · 모의 서버 `127.0.0.1:18090`.

### 빌드해서 새 환경으로 돌리기

플랫폼이 저장소 폴더를 **스냅샷(읽기 전용)으로 굳혀 새 환경을 띄우는** 경우입니다. 스냅샷에는 저장소 폴더만 들어가고,
apt 로 설치한 Kong·PostgreSQL 은 들어가지 않습니다 → 새 환경이 뜰 때 `run.sh` 가 다시 설치합니다(처음 약 2분).
바뀌는 것(설정·라이선스·DB·로그)은 전부 유지 폴더에 있으므로 새 환경도 **같은 유지 폴더를 같은 경로로** 붙여야 합니다.

**빌드 전 (개발 파드에서)**

```bash
cd /project/work/flow/kong-ai-gateway-poc
bash status.sh        # 「설정 파일」·「라이선스」가 유지 폴더 경로인지 확인 (예전 방식이면 이때 옮겨짐)
bash verify.sh        # 「빌드 준비 — 저장소 폴더에 DB 사본·비밀값 없음」이 OK 인지
bash stop.sh          # 반드시 내린다 — 같은 DB 를 두 곳에서 띄우면 DB 가 깨진다
```

- `verify.sh` 가 「빌드 전에 저장소 폴더에서 치울 것」을 알려 주면 지우고 빌드합니다. 유지 폴더로 옮기기 전 자리(`data.moved-<시각>`)는
  **옛 DB 사본 전체**라 스냅샷에 들어가면 안 됩니다 (지금 DB 는 유지 폴더에 있으니 지워도 됨).
- 저장소를 다른 위치로 옮겨 쓰기 시작했으면 **옛 위치의 저장소는 지우세요.** 예전 스크립트는 실행 기록을 몰라서, 그곳에서
  `start.sh` 를 실행하면 새 환경이 쓰는 DB 를 함께 띄워 DB 가 깨질 수 있습니다.

**빌드 설정**

| 항목 | 값 |
|---|---|
| 시작 명령 | `run.sh` — 끝나지 않고 계속 떠 있음. 플랫폼이 시작 스크립트(예: flow 폴더의 `run-application.sh`)를 부르면 그 안에 `exec bash "$(dirname "$0")/kong-ai-gateway-poc/run.sh"` (`exec` 라야 종료 신호가 run.sh 에 닿아 DB 까지 정상 종료) |
| 실행 사용자 | 개발 파드와 같은 사용자(uid) — DB 폴더의 주인이 같아야 DB 가 뜸 |
| 유지 폴더 | 쓰기 가능하게 붙어 있어야 함 — 경로는 달라도 됨 (아래) |
| 필요 권한 | sudo(비밀번호 없이) · Ubuntu 저장소(apt) 접속 — 프로그램 재설치에 필요 |
| 포트 | 8000(프록시) · 8001(Admin API) · 8002(Manager) · 8100(지표) |
| 복제본 | 1개 — 같은 DB 를 둘 이상이 쓸 수 없음 |

새 환경의 외부 주소가 개발 파드와 다르면 빌드 전에 바꿔 둡니다:
`bash set-env.sh MANAGER_URL <8002 외부 주소>` · `bash set-env.sh ADMIN_API_URL <8001 외부 주소>`.
**환경마다(빌드할 때마다) 주소 속 ID 가 바뀌면** 그 자리를 `{ENV_ID}` 로 적어 둡니다. 그러면 Kong 이 **요청마다**
브라우저가 연 Manager 주소(`manager-<ID>.도메인`)에서 Admin API 주소(`adminapi-<ID>.도메인`)를 만들어 Manager 에 알려 주고,
Admin API 는 `manager-<아무 ID>.도메인` 에서 온 요청만 허용합니다 — ID 를 몰라도 되므로 다시 빌드해도 설정을 고칠 필요가 없고,
개발 파드와 새 환경이 같은 설정 파일을 그대로 씁니다. (nginx `map`·`sub_filter`·`more_set_headers`, `lib.sh` 의 `gui_by_host`)

```bash
bash set-env.sh MANAGER_URL 'https://manager-{ENV_ID}.<플랫폼 도메인>'
bash set-env.sh ADMIN_API_URL 'https://adminapi-{ENV_ID}.<플랫폼 도메인>'
```

`verify.sh` 는 이 동작을 직접 시험합니다(「외부 주소 자동」). 화면·기록에 보여 주는 주소와 Kong 의 `admin_gui_url` 은
`KONG_POC_ENV_ID` → 플랫폼의 `INFER_SERVICE_ID`(빌드한 새 환경의 서비스 ID, 소문자로) → 파드 이름의 `영문 3자 + 숫자 10자리` 조각
(없으면 `unknown`) 순서로 채웁니다. Manager 화면 동작에는 쓰이지 않지만, **관리자 가입 링크·비밀번호 재설정 링크의 주소**가
이 값으로 만들어집니다 — 링크의 주소가 브라우저의 Manager 주소와 다르면 앞부분(`https://manager-…`)만 바꿔 열면 됩니다.

**새 환경이 뜬 뒤 (개발 파드에서)** — 새 환경에 터미널이 없어도 유지 폴더를 거쳐 일을 맡길 수 있습니다.

```bash
bash remote.sh status     # 새 환경의 프로세스·라우트
bash remote.sh verify     # 새 환경 안에서 전체 점검 (결과가 이 화면에 나옴)
bash set-env.sh FEATURE_SEMANTIC_CACHE on && bash remote.sh apply      # 설정을 바꾸고 적용
bash set-license.sh <새 라이선스 파일> && bash remote.sh restart         # 라이선스 교체
```

- 새 환경에서는 저장소가 다른 곳(예: `/infer-model/<모델>/source/flow/kong-ai-gateway-poc`)에 놓여도 됩니다 — 스크립트가 자기 위치를 찾습니다.
- 유지 폴더도 다른 경로로 붙어도 됩니다. ① 저장소 `.env` 의 `DATA_DIR` → ② 바로가기를 푼 실제 위치(`DATA_DIR_REAL`) → ③ 이 환경에 붙은 저장소(마운트)
  아래에서 같은 폴더(`…/data/kong-poc/settings.env`) 순서로 찾고, 경로가 바뀌었으면 Kong 설정 속 요청 로그 위치도 맞춥니다.
  끝내 못 찾으면 `run.sh` 가 **환경 정보**(호스트 이름·사용자·sudo·외부 접속·붙은 저장소·폴더 목록)를 남기고 멈춥니다 — 그 기록으로 다음 조치를 정합니다.
  위치를 직접 줄 때는 `KONG_POC_DATA_DIR=<붙은 경로>/kong-poc bash run.sh`.
- 개발 파드에서 `start.sh` 를 실행하면 「다른 환경이 이 유지 폴더로 실행 중」이라며 멈춥니다(실행 기록 `run.lock`). 개발 파드에서
  다시 띄우려면 새 환경을 먼저 내리세요. 새 환경이 없어졌는데 기록만 남았으면 90초 뒤 이어받습니다.
- 다시 빌드하면 플랫폼이 새 환경을 띄울 때 이전 환경이 아직 내려가는 중일 수 있습니다. 새 환경의 `run.sh` 는 실패하지 않고
  이전 환경이 실행 기록을 지우거나(정상 종료) 90초 넘게 갱신하지 않을 때까지 기다렸다가(최대 10분) 이어받습니다.
  이전 환경이 `exec bash run.sh` 로 떠 있었다면 종료 신호에 DB 까지 정상 종료하고 기록을 지우므로 바로 이어받습니다.
- `conf/*.yaml`·스크립트를 고치면 다시 빌드해야 새 환경에 들어갑니다. 설정 값(`settings.env`)만 바꾸는 건 빌드 없이 `remote.sh` 로 됩니다.
- 처음 만든 DB(빈 유지 폴더)로 뜨면 `run.sh` 가 요구사항 설정까지 한 번 적용합니다. 이미 설정이 있으면 건드리지 않습니다
  (Manager 에서 바꾼 값을 지키려고).

---

## 로그

| 로그 | 내용 | 저장 위치 | 보관 |
|---|---|---|---|
| **요청 상세 로그** | 모든 호출 1건 = JSON 한 줄 — 사용자(부서 키), 경로·서비스, 상태, 단계별 지연(Kong·LLM), 모델, 토큰 수, 추적 ID, 접속 IP, 마스킹 건수, 클라이언트가 보낸 모델 이름 | `logs/audit.log` (+ 중앙 저장소 `DECK_LOG_HTTP_URL`) | 삭제할 때까지 |
| **관리 감사로그** | Admin API·Kong Manager 로 설정을 바꾼 이력 — 누가, 언제, 무엇을 (비밀번호 변경 포함) | DB (`audit_requests` — `pgdata/` 와 함께 유지) | 30일 후 자동 삭제 |
| Kong 접속 로그 | 프록시·Admin API·Manager 의 요청 한 줄 기록 (nginx 형식) | `logs/kong-access.log` · `kong-admin-access.log` · `kong-manager-access.log` | 삭제할 때까지 |
| Kong 오류 로그 | 기동·플러그인 오류·경고 | `logs/kong-error.log` | 삭제할 때까지 |

위치는 데이터 폴더(`DATA_DIR` — 기본 `data/`, 유지 폴더를 지정했으면 `<유지 폴더>/kong-poc/`) 기준입니다.

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
| 외부 Manager 주소가 `upstream connect error … Connection refused` | Kong 이 8001·8002 를 파드 안에서만 받는 중 — `bash set-env.sh MANAGER_URL <외부 주소>` · `ADMIN_API_URL` 도 같은 방법, `bash set-env.sh JUPYTER_URL ''` → `bash stop.sh && bash start.sh` |
| Manager 로그인 후 목록이 비거나 401 | `MANAGER_URL`·`ADMIN_API_URL` 이 브라우저 접속 주소와 다름 |
| 비밀번호가 맞는데 로그인이 안 됨 | 설정 파일의 값 뒤에 설명(`# …`)이 붙어 비밀번호의 일부로 읽힘 — 값 뒤 주석 제거 (`bash set-env.sh <키>` 로 다시 넣기) |
| `verify.sh` 가 Kong Manager 로그인 401 | Manager 에서 비밀번호를 바꿈 — `bash set-env.sh KONG_MANAGER_PASSWORD` 로 새 비밀번호 (`KONG_ADMIN_PASSWORD` 는 그대로) |
| `apply-config.sh` 가 라이선스 때문에 멈춤 / 설정 변경 403 | 라이선스가 없거나 유예 기간도 끝남 — `bash set-license.sh <파일>` 후 `bash stop.sh && bash start.sh` (`bash status.sh` 에 라이선스 위치·만료일) |
| `start.sh` 가 「다른 환경이 이 유지 폴더로 실행 중」 | 빌드한 새 환경 등이 같은 DB 를 쓰는 중 — 그쪽을 먼저 내리거나 `bash remote.sh …` 로 그쪽에 맡김. 그 환경이 없어졌으면 90초 뒤 이어받음 |
| `start.sh` 가 「실행 표시(postmaster.pid)가 남아 있는데 실행 기록이 없습니다」 | 예전 스크립트로 띄운 개발 파드가 아직 돌 수 있음 — 그 파드에서 `bash stop.sh`. 아무 데서도 안 도는 게 확실하면 `FORCE_UNLOCK=1 bash start.sh` |
| 통합 경로에 `"stream": true` 요청이 400 `response streaming is not enabled` | 답변 검사(`FEATURE_OUTPUT_GUARD`·`FEATURE_OUTPUT_MASK`)가 켜져 있음 — 정상 동작 |
| LLM 호출이 503 `name resolution failed` | LLM 주소의 호스트 이름을 파드에서 찾을 수 없음 — 주소 확인. IP 를 바꿨다면 `bash apply-config.sh` 가 Kong 에 새 이름을 반영 |
| `start.sh` 가 설치 중 멈춤 | `data/logs/install.log` 끝부분 확인 (apt 저장소 접속·디스크) |
| 임베딩 호출이 400 | 임베딩 서버가 `dimensions` 파라미터를 거부 — 게이트웨이의 `/ai/embed` 가 제거하므로 그 경로를 쓰는지 확인 |
