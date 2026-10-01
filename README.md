# Kong AI Gateway PoC

docker 를 쓸 수 없는 **개발환경 파드(주피터)**에 Kong AI Gateway 를 직접 설치해 검증하는 저장소입니다.
Kubernetes 권한이나 컨테이너 실행 없이 **sudo · apt(Ubuntu 22.04) · GitHub** 만 있으면 됩니다.

```
              ┌──────────────────── 개발환경 파드 (Ubuntu 22.04) ────────────────────┐
 클라이언트 ──▶ │ Kong Gateway 3.15   :8000 프록시                                     │ ──▶ 채팅 모델
              │                     :8001 Admin API (RBAC)                           │ ──▶ 임베딩 모델
 브라우저 ────▶ │                     :8002 Kong Manager (로그인)                       │
              │        │                                  │                           │
              │ PostgreSQL 14 :5432                 PII 가드 :18080                   │
              │  ├ kong (설정)                       한국 개인정보 탐지                 │
              │  └ kong-pgvector (시맨틱 캐시)                                         │
              └──────────────────────────────────────────────────────────────────────┘
```

| 구성 | 내용 |
|---|---|
| Kong | Kong Gateway Enterprise 3.15.0.6 · traditional 모드 · 워커 2개 |
| 데이터베이스 | PostgreSQL 14 (Ubuntu 저장소) + pgvector 0.8.6 (GitHub 소스 빌드) |
| 설정 관리 | [decK](https://developer.konghq.com/deck/) 선언형 파일 (`conf/`) |
| 설치 파일 | `pkgs/` — Kong `.deb`(Ubuntu 22.04, 75.5 MB) · decK 1.65.1 · `SHA256SUMS` |
| 실행 | 컨테이너 없이 파드 안의 프로세스 3개 (PostgreSQL · Kong · PII 가드) |

Kong 패키지 저장소·GitHub Release 가 막힌 파드를 위해 설치 파일을 저장소에 넣었습니다. `git clone` 하나로 받습니다.

---

## 설치

### 1. 사전 점검

```bash
bash kong-check.sh
```

OS·자원·저장 공간·외부 접속·apt 저장소·주피터 프록시·포트 사용 여부를 한 화면에 보여 줍니다.

### 2. 받기 · 설정

```bash
cd /project/work/Kong                     # 파드를 다시 만들어도 남는 경로
git clone https://github.com/galaxy686123-commits/kong-ai-gateway-poc.git
cd kong-ai-gateway-poc
cp .env.example .env                      # 비밀번호·키 4개와 접속 주소를 채운다 (아래 「Kong Manager 접속」)
```

- `.env` 는 숨김 파일이라 주피터 탐색기에서 바로 안 열립니다. `sed` 로 고치거나 `env.txt` 로 복사해 편집한 뒤 `mv env.txt .env`.
- 라이선스는 주피터 탐색기로 `secrets/` 에 올리고 이름을 `license.json` 으로 (없으면 설치·접속 시험만 됨 — 아래 「라이선스」).

### 3. 기동 · 점검

```bash
bash start.sh                 # 설치 → DB → 마이그레이션 → PII 가드 → Kong → 설정 적용 (처음 약 2분)
bash start.sh --no-config     # 설정 적용 없이 설치·기동까지만
bash verify.sh                # 환경·설치·실행·접속·기능·로그 전체 점검 (화면 한 장)
```

`verify.sh` 의 요약이 **불가 0** 이면 됩니다.

### 4. Kong Manager 접속

Kong Manager 는 **브라우저가 Admin API(8001)를 직접 호출**하므로 8002 와 8001 이 둘 다 브라우저에서 닿아야 합니다.
`.env` 에 둘 중 한 가지를 설정합니다.

| 방식 | `.env` | 브라우저 주소 |
|---|---|---|
| **플랫폼이 8000·8001·8002 를 밖으로 연 경우** | `MANAGER_URL=<8002 주소>` · `ADMIN_API_URL=<8001 주소>` · `JUPYTER_URL=` (비움) | `MANAGER_URL` |
| 주피터를 거쳐 여는 경우 (`jupyter-server-proxy`) | `JUPYTER_URL=<주피터 주소>` | `<JUPYTER_URL>/proxy/absolute/8002/` |

- 계정: `kong_admin` / `.env` 의 `KONG_ADMIN_PASSWORD`
- 외부 포트 방식이면 Admin API·Manager 가 모든 주소(0.0.0.0)에서 받고, 주피터 방식이면 파드 안(127.0.0.1)에서만 받습니다.
- 접속 방식을 바꾼 뒤에는 `bash stop.sh && bash start.sh`.
- Admin API 를 스크립트로 부를 때는 `Kong-Admin-Token: <KONG_ADMIN_PASSWORD>` 헤더를 붙입니다.

---

## 라이선스

| 라이선스 상태 | Kong 동작 (실측) | `start.sh` |
|---|---|---|
| 유효 | 전부 동작 | 설정까지 적용 |
| 만료 후 유예 기간 (Kong 로그 기준 약 30일) | 전부 동작 — 설정 변경·로그인·Enterprise 플러그인 포함 | 경고 후 설정까지 적용 |
| 없음 · 유예 종료 | **읽기 전용** — 설정 쓰기 403. 기존 설정으로 프록시·가드는 계속 처리, Manager 로그인·조회 가능 | 설치·기동까지만 |

라이선스를 넣거나 바꾼 뒤에는 `bash stop.sh && bash start.sh` (Kong 은 기동할 때 라이선스를 읽습니다).
PII 가드(`ai-custom-guardrail`)·시맨틱 캐시(`ai-semantic-cache`)는 Enterprise 플러그인입니다.

---

## 스크립트

| 스크립트 | 하는 일 |
|---|---|
| `start.sh` | 기동. 여러 번 실행해도 안전. 프로그램이 없으면(파드 재생성) 먼저 다시 설치 |
| `verify.sh` | 전체 점검 |
| `status.sh` | 프로세스·라우트 상태 |
| `apply-config.sh` | `conf/` 변경을 Kong 에 반영 (decK). `kong-poc` 태그가 붙은 것만 관리해 Manager 에서 만든 설정은 건드리지 않음 |
| `dump-config.sh` | 지금 설정을 `conf/backup/` 에 파일로 받기 (Manager 에서 바꾼 것 포함) |
| `logs.sh` | 요청 로그 요약 · `-f` 실시간 · `export DIR` · `admin`(설정 변경 이력) |
| `stop.sh` | 정지 (데이터는 남김) |
| `install.sh` | 프로그램만 설치 (`start.sh` 가 필요할 때 부름) |
| `kong-check.sh` | 설치 전 환경 점검 |

### 데이터와 재시작

- DB·요청 로그·pgvector 빌드 결과는 `data/`(`DATA_DIR`)에 둡니다. **파드를 다시 만들어도 남는 경로**여야 합니다.
- 파드를 다시 만들면 apt 로 깐 프로그램은 사라지지만 `bash start.sh` 한 번이면 다시 설치하고 기존 데이터로 이어서 뜹니다 (약 1분).
- DB 를 NFS 에 만들 수 없으면(소유자·권한 변경 불가) 로컬 디스크로 대체하고 알려 줍니다.
- 포트: 프록시 `0.0.0.0:8000`, Admin API `:8001`, Manager `:8002`, PostgreSQL `127.0.0.1:5432`, PII 가드 `:18080`.

### LLM 붙이기

`DECK_CHAT_URL` 이 예시 주소면 `verify.sh` 는 LLM 항목만 [주의]로 표시합니다. 붙일 때는 `.env` 의
`DECK_CHAT_URL`·`DECK_CHAT_MODEL`·`LLM_AUTH_HEADER`(임베딩은 `DECK_EMBED_*`)를 채운 뒤:

```bash
bash stop.sh && bash start.sh     # 인증 헤더는 Kong 이 기동할 때 읽는다
bash apply-config.sh              # 주소·모델 반영 (임베딩을 채웠으면 시맨틱 캐시도 추가)
bash verify.sh
```

---

## 시나리오

라이선스가 있고 설정이 적용되면 다음 경로가 생깁니다.

| 경로 | 동작 | 적용 조건 |
|---|---|---|
| `/v1/chat/completions` | 사용자 키 인증 → **정규식 가드**(한국 개인정보 형식·프롬프트 주입 차단) → LLM | 항상 |
| `/poc/pii/v1/chat/completions` | **한국어 PII 가드** — 주민등록번호(체크섬)·계좌·여권 등 17종 탐지 시 차단 | PII 가드 실행 중 |
| `/poc/cache/v1/chat/completions` | **시맨틱 캐시** — 의미가 같은 질문은 LLM 호출 없이 응답 | `.env` 에 임베딩 모델 지정 |

```bash
KEY=<.env 의 DECK_CLIENT_KEY>

# 정상 요청
curl -s localhost:8000/v1/chat/completions -H "apikey: $KEY" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"한 단어로만: 한국 수도는?"}]}'

# 개인정보가 포함되면 400 으로 차단
curl -s localhost:8000/v1/chat/completions -H "apikey: $KEY" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"제 주민번호는 900101-1234567 입니다"}]}'

# 시맨틱 캐시 — 두 번째부터 응답 헤더 X-Cache-Status: Hit
curl -si localhost:8000/poc/cache/v1/chat/completions -H "apikey: $KEY" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"보험을 해지하면 환급금은 어떻게 계산되나요?"}]}' | grep -i x-cache-status
```

OpenAI SDK 에서는 `base_url` 을 게이트웨이로 두고 사용자 키를 헤더로 넘깁니다.

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8000/v1", api_key="unused",
                default_headers={"apikey": "<사용자 키>"})
```

---

## 로그

| 로그 | 내용 | 저장 위치 | 보관 |
|---|---|---|---|
| **요청 로그** | 모든 API 호출 — 사용자, 경로, 상태, 모델, 토큰 수, 캐시 결과, 지연, 요청 ID | `data/logs/audit.log` | 삭제할 때까지 |
| **관리 감사로그** | Admin API · Kong Manager 로 설정을 바꾼 이력 — 누가, 언제, 무엇을 | PostgreSQL (`audit_requests`) | 30일 후 자동 삭제 |
| Kong 오류 로그 | 기동·플러그인 오류 | `data/logs/kong-error.log` | 삭제할 때까지 |

```bash
bash logs.sh                  # 최근 요청 20건 요약
bash logs.sh -f               # 실시간
bash logs.sh export ~/logs    # 로그 파일을 꺼내 보관·제출
bash logs.sh admin            # 설정 변경 이력
```

요청 로그는 JSON 한 줄이 한 건이며 건당 약 2.8 KB 입니다. 파일이 자동으로 나뉘지 않으므로 오래 운영한다면 주기적으로 내보내고 비우세요.

**기록하지 않는 것**: 요청·응답 본문(`log_payloads: false`), 사용자 키(`hide_credentials`), 업스트림 인증 헤더(Kong 이 `REDACTED` 로 가림), LLM 응답 헤더(조직·프로젝트 ID·비용 같은 업스트림 내부 정보).

---

## 검증

고객 파드와 같은 조건으로 재현한 환경에서 확인했습니다 — Ubuntu 22.04 · uid 3000 · sudo · JupyterLab +
jupyter-server-proxy · 4 vCPU / 8 GB · 8080 사용 중 · nodesource apt 저장소 실패 · Kong/Release/PGDG/OpenAI 도메인 차단.

| 항목 | 결과 |
|---|---|
| 새 파드에서 clone · 설치 · 기동 | 약 2분 |
| `verify.sh` (라이선스·LLM 있음) | OK 20 · 불가 0 — 차단 401/400, PII 가드 400, LLM 200, 시맨틱 캐시 Miss 1.4초 → Hit 0.1초 |
| `verify.sh` (라이선스 없음, 설치·접속 시험) | OK 14 · 주의 2 · 불가 0 |
| 브라우저 | Manager 로그인 — 외부 포트 방식·주피터 프록시 방식 둘 다. 설정 생성/수정/삭제(201/200/204) |
| 파드 강제 재생성 | `start.sh` 한 번에 자동 재설치 후 기존 DB·설정·로그로 기동 (약 1분) |

---

## 설계 메모

- **PostgreSQL·Kong 은 파드 사용자 권한으로 실행합니다.** sudo 는 apt 설치에만 씁니다. DB 슈퍼유저는 파드 사용자만 쓰는
  소켓으로만 접속(trust)하고, TCP 접속은 비밀번호(scram)로 받습니다.
- **Kong 의 실행 파일 위치(prefix)는 로컬 디스크**(`~/.kong-poc`)에 둡니다 — 내부 통신용 유닉스 소켓을 NFS 에 두지 않기 위해서입니다.
- **pgvector 는 `OPTFLAGS=""`·`with_llvm=no` 로 빌드합니다.** 파드가 다른 CPU 의 노드로 옮겨가도 동작하고, clang 이 필요 없습니다.
  빌드 결과를 `data/` 에 남겨 두어 재설치 때는 복사만 합니다.
- **요청·응답 본문은 로그에 남기지 않습니다** (`log_payloads: false`). 토큰 수 등 통계는 기록합니다.
- **임베딩은 게이트웨이 자신의 `/ai/embed` 를 거칩니다.** 일부 임베딩 서버(vLLM 등)가 거부하는 `dimensions` 파라미터를 앞단에서 제거합니다.

## 문제 해결

| 증상 | 원인 · 조치 |
|---|---|
| 외부 Manager 주소가 `upstream connect error … Connection refused` | Kong 이 8001·8002 를 파드 안에서만 받는 중 — `.env` 에 `MANAGER_URL`·`ADMIN_API_URL` 외부 주소, `JUPYTER_URL` 비움 → `bash stop.sh && bash start.sh` |
| Manager 로그인 후 목록이 비거나 401 | `MANAGER_URL` · `ADMIN_API_URL` 이 브라우저 접속 주소와 다름 |
| Manager 에서 로그인이 안 됨 (비밀번호가 맞는데) | `.env` 값 뒤에 설명(`# …`)이 붙어 비밀번호의 일부로 읽힘 — 값 뒤 주석 제거 |
| 설정 변경이 `Enterprise license missing or expired` (403) | 라이선스가 없거나 유예 기간도 끝남 — `secrets/license.json` 확인 후 `bash stop.sh && bash start.sh` |
| `start.sh` 가 설치 중 멈춤 | `data/logs/install.log` 끝부분 확인 (apt 저장소 접속·디스크) |
| 요청이 `426 Please use HTTPS protocol` | 라우트에 `protocols: [http, https]` 가 빠짐 |
| 임베딩 호출이 400 | 임베딩 서버가 `dimensions` 파라미터를 거부 — `/ai/embed` 경유 확인 |
