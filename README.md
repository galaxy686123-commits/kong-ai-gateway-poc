# Kong AI Gateway PoC

Kong AI Gateway 를 **컨테이너 실행이 가능한 개발환경 하나**에 올려 검증하기 위한 저장소입니다.
Kubernetes 권한이 없어도, 파드 안에서 도커를 쓸 수 있으면 됩니다.

```
                 ┌─────────────────────────────────────────────┐
 클라이언트 ────▶ │ Kong Gateway  :8000 프록시                   │ ───▶ 채팅 모델
                 │               :8001 Admin API (RBAC)        │ ───▶ 임베딩 모델
 관리자 브라우저 ─▶ │               :8002 Kong Manager (로그인)    │
                 └───────┬───────────────────────┬─────────────┘
                         │                       │
                 ┌───────▼────────┐      ┌───────▼────────┐
                 │ PostgreSQL     │      │ PII 가드레일    │  (선택)
                 │ ├ kong         │      │ 한국 개인정보   │
                 │ └ kong-pgvector│      │ 탐지            │
                 └────────────────┘      └────────────────┘
```

| 구성 | 내용 |
|---|---|
| 모드 | traditional (단일 노드) + PostgreSQL |
| Kong | Kong Gateway Enterprise 3.15 · 워커 1개 |
| 데이터베이스 | PostgreSQL 16 + pgvector — Kong 설정(`kong`)과 벡터 저장소(`kong-pgvector`) |
| 설정 관리 | [decK](https://docs.konghq.com/deck/) 선언형 파일 (`conf/`) |
| 필요 자원 | 약 2 vCPU / 4 GB |

---

## 시작하기

### 1. 환경 점검

```bash
git clone https://github.com/galaxy686123-commits/kong-ai-gateway-poc.git && cd kong-ai-gateway-poc
./check-env.sh
```

도커 실행 방식, 외부 접속 범위, 바인드 마운트·포트 연결 여부를 한 번에 확인하고
어느 경로로 진행할지 알려 줍니다. **결과 전체를 담당자에게 전달해 주세요.**

파드에 **docker 가 없으면** 대신 `bash kong-check.sh` 를 실행합니다. 관리자 권한(sudo)·apt 저장소·
외부 접속·저장 공간을 보고 Kong·PostgreSQL 을 파드에 직접 설치할 수 있는지 확인합니다.

### 2. 설정

```bash
cp .env.example .env        # 값 채우기 — 비밀번호, LLM 주소·모델, 사용자 키
cp <라이선스> secrets/license.json   # 필수. 없거나 만료되면 설치가 멈춥니다
```

`.env` 와 `secrets/` 는 git 에 올라가지 않습니다.

### 3. 기동

```bash
./start.sh
```

처음 실행하면 이미지를 받고, 데이터베이스를 초기화하고(관리자 계정 생성 포함),
`conf/` 의 설정을 적용합니다. 이후에는 여러 번 실행해도 안전합니다.

---

## 시나리오

| 경로 | 동작 | 적용 조건 |
|---|---|---|
| `/v1/chat/completions` | 사용자 키 인증 → **정규식 가드**(한국 개인정보 형식·프롬프트 주입 차단) → LLM | 항상 |
| `/poc/cache/v1/chat/completions` | **시맨틱 캐시** — 의미가 같은 질문은 LLM 호출 없이 응답 | `.env` 에 임베딩 모델 지정 |
| `/poc/pii/v1/chat/completions` | **한국어 PII 가드** — 주민등록번호(체크섬)·계좌·여권 등 탐지 시 차단 | `addons/pii-guard/app.py` 존재 |

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

### 검증 결과

| 시나리오 | 결과 |
|---|---|
| 사용자 키 없이 호출 | 401 |
| 정상 질문 | 200 · 약 2.7초 |
| 주민등록번호 · 프롬프트 주입 | 400 차단 |
| PII 가드 — 주민등록번호 | 400 · `개인정보 탐지(1종): 주민등록번호(형식일치·체크섬불일치)` |
| 시맨틱 캐시 — 첫 질문 | Miss · 1.56초 |
| 시맨틱 캐시 — 같은 질문 | **Hit · 0.06초** |
| 시맨틱 캐시 — 표현만 바꾼 질문 | **Hit · 0.05초** |
| 재기동 후 같은 질문 | Hit · 0.1초 (저장 데이터 유지) |

---

## Kong Manager

브라우저에서 `.env` 의 `MANAGER_URL`(기본 `http://localhost:8002`)로 접속합니다.

- 계정: `kong_admin` / `.env` 의 `KONG_ADMIN_PASSWORD`
- Kong Manager 는 **브라우저가 Admin API(`:8001`)를 직접 호출**합니다.
  파드 밖에서 접속한다면 `:8002` 와 `:8001` 이 **둘 다** 브라우저에서 닿아야 하며,
  `.env` 의 `MANAGER_URL` · `ADMIN_API_URL` 을 실제 접속 주소로 바꿔야 합니다.
- Admin API 는 RBAC 로 보호됩니다. 스크립트나 도구로 호출할 때는
  `Kong-Admin-Token: <KONG_ADMIN_PASSWORD>` 헤더를 붙입니다.

---

## 로그

두 가지 로그를 남깁니다. 별도 로그 저장소는 필요 없습니다.

| 로그 | 내용 | 저장 위치 | 보관 |
|---|---|---|---|
| **요청 로그** | 모든 API 호출 — 사용자, 경로, 상태, 모델, 토큰 수, 캐시 결과, 지연, 요청 ID | 파일 (`/var/log/kong-poc/audit.log`) | 삭제할 때까지 |
| **관리 감사로그** | Admin API · Kong Manager 로 설정을 바꾼 이력 — 누가, 언제, 무엇을 | PostgreSQL (`audit_requests`) | 30일 후 자동 삭제 |

```bash
./logs.sh                  # 최근 요청 20건 요약
./logs.sh -f               # 실시간
./logs.sh export ~/logs    # 로그 파일을 꺼내 보관·제출
./logs.sh admin            # 설정 변경 이력
```

요청 로그는 JSON 한 줄이 한 건이며 **건당 약 2.8 KB** 입니다(1만 건에 약 28 MB).
기본적으로 도커 볼륨 `kong-poc-logs` 에 쌓이고, `.env` 의 `LOG_DIR` 에 경로를 지정하면
그곳에 씁니다. 파일이 자동으로 나뉘지 않으므로 오래 운영한다면 주기적으로 내보내고 비우세요.

**기록하지 않는 것**

- 요청·응답 **본문** — 개인정보가 로그에 쌓이지 않도록 (`log_payloads: false`)
- **사용자 키** — 인증 플러그인이 전달 전에 제거 (`hide_credentials`)
- **업스트림 인증 헤더** — Kong 이 `REDACTED` 로 가림
- **LLM 응답 헤더** — 업스트림 내부 정보(조직·프로젝트 ID, 호출 비용)가 담겨 제외

---

## 운영

| 명령 | 동작 |
|---|---|
| `./start.sh` | 기동 (이미 떠 있으면 건너뜀) |
| `./stop.sh` | 정지 — 데이터는 남음 |
| `./stop.sh --purge` | 정지 + 데이터 삭제 (되돌릴 수 없음) |
| `./status.sh` | 컨테이너·라우트 상태 |
| `./apply-config.sh` | `conf/` 의 설정을 반영 |
| `./dump-config.sh` | 현재 설정 전체를 `conf/backup/` 에 백업 |
| `./bundle.sh` | (인터넷 PC) 이미지 tar·번들 생성, `--push` 로 GHCR 업로드 |
| `./fetch-images.sh` | GitHub Release 에서 이미지 tar 내려받기 |
| `./logs.sh` | 요청 로그·설정 변경 이력 보기, 내보내기 |

### 설정 변경

`conf/` 의 파일을 고친 뒤 `./apply-config.sh` 를 실행합니다.
decK 는 `kong-poc` 태그가 붙은 항목만 관리하므로, **Kong Manager 에서 직접 만든 설정은
지워지지 않습니다.** Manager 에서 바꾼 내용은 `./dump-config.sh` 로 백업해 두세요.

### 데이터 보존

데이터베이스는 기본적으로 도커 볼륨(`kong-poc-pgdata`)에 저장됩니다.
개발환경이 재시작될 때 도커 저장소까지 초기화되는 플랫폼이라면 `.env` 의 `PG_DATA_DIR` 에
재시작 후에도 남는 경로를 지정하세요. 저장소가 초기화되더라도 `./start.sh` 가 데이터베이스를
다시 만들고 `conf/` 의 설정을 적용하므로, 잃는 것은 Manager 에서 바꾼 내용과 캐시뿐입니다.

---

## 이미지 경로

`./check-env.sh` 가 파드에서 접속되는 곳을 보고 아래 네 가지 중 하나를 안내합니다.

| 경로 | 파드에서 열려 있어야 할 곳 | 방법 |
|---|---|---|
| 1. Docker Hub | `registry-1.docker.io` · `production.cloudflare.docker.com` | `./start.sh` 가 바로 받음 |
| 2. GHCR | `ghcr.io` | 인터넷 PC 에서 GHCR 에 올리고, 파드는 거기서 받음 |
| 3. GitHub Release | `github.com` · `release-assets.githubusercontent.com` | 이미지 tar 를 Release 에 올리고, 파드가 내려받음 |
| 4. 물리 반입 | 없음 | 번들 파일을 반입 |

GitHub 은 실제 파일을 **github.com 이 아닌 별도 도메인**에서 내려줍니다.
github.com 만 허용된 환경이라면 경로 2·3 이 안 될 수 있으니 점검 결과를 확인하세요.

### 경로 2 — GHCR

```bash
# 인터넷 PC
docker login ghcr.io
./bundle.sh --push ghcr.io/<계정>        # 올린 뒤 .env 에 넣을 이미지 이름을 알려 줌

# 파드
echo <토큰> | docker login ghcr.io -u <계정> --password-stdin   # 비공개 패키지일 때
# .env 에 KONG_IMAGE=ghcr.io/<계정>/kong-gateway:3.15 등 4줄 추가
./start.sh
```

### 경로 3 — GitHub Release

```bash
# 인터넷 PC
./bundle.sh                               # images/*.tar 4개 생성 → Release 에 첨부

# 파드
./fetch-images.sh https://github.com/<계정>/<저장소>/releases/download/<태그>
./start.sh
```

### 경로 4 — 물리 반입

```bash
# 인터넷 PC
./bundle.sh                               # → kong-poc-bundle-<날짜>.tar.gz (약 0.9 GB)

# 반입 후 파드
tar xzf kong-poc-bundle-<날짜>.tar.gz && cd kong-ai-gateway-poc
cp .env.example .env && ./start.sh
```

`./start.sh` 는 이미지를 **로컬 → `images/*.tar` → 레지스트리** 순서로 찾으므로,
경로 3·4 에서는 인터넷 없이도 동작합니다.

### 검증

Docker Hub 을 차단하고, 도커 데몬을 별도 컨테이너로 분리해 바인드 마운트가 되지 않는
환경을 만들어 경로 4 로 설치해 보았습니다.

- `./check-env.sh` 가 Docker Hub 차단과 바인드 마운트 불가를 감지하고 경로 2 를 안내
- `./start.sh` 가 tar 에서 이미지를 불러와 **53초 만에 기동**, 설정 21개 적용
- 모든 시나리오가 위 「검증 결과」와 같은 결과

---

## 설계 메모

- **설정을 이미지로 빌드해 전달합니다.** 도커 데몬이 별도 컨테이너인 플랫폼에서는
  개발환경의 파일을 컨테이너에 연결(바인드 마운트)할 수 없는 경우가 있어,
  PostgreSQL 초기화 스크립트·decK 설정·PII 가드 코드를 작은 이미지로 빌드합니다.
  빌드는 패키지 설치 없이 파일 복사만 하므로 인터넷 없이도 됩니다.
- **워커 수를 1로 고정합니다.** `auto` 로 두면 컨테이너 한도가 아니라 노드의 전체 코어 수만큼
  워커가 떠서 메모리 한도를 넘길 수 있습니다.
- **요청·응답 본문은 로그에 남기지 않습니다** (`log_payloads: false`). 개인정보가 로그 저장소에
  쌓이는 것을 막기 위해서입니다. 토큰 수 등 통계는 기록합니다.
- **임베딩은 게이트웨이 자신의 `/ai/embed` 를 거칩니다.** 일부 임베딩 서버(vLLM 등)는
  `dimensions` 파라미터를 거부하는데, 이 경로 앞단에서 그 파라미터를 제거합니다.

## 문제 해결

| 증상 | 원인 · 조치 |
|---|---|
| 요청이 `426 Please use HTTPS protocol` | 라우트에 `protocols: [http, https]` 가 빠짐 |
| Manager 로그인 후 목록이 비거나 401 | `MANAGER_URL` · `ADMIN_API_URL` 이 브라우저 접속 주소와 다름 |
| 임베딩 라우트 생성 시 `category 'text/generation' cannot be used` | 임베딩 `ai-proxy` 에 `genai_category: text/embeddings` 누락 |
| 임베딩 호출이 400 | 임베딩 서버가 `dimensions` 파라미터를 거부 — `/ai/embed` 경유 확인 |
| `Enterprise license missing or expired` (403) | 라이선스가 없거나 만료되면 Admin API 쓰기가 전부 막혀 **설정이 하나도 적용되지 않습니다.** `./start.sh` 가 기동 전에 라이선스를 검사해 멈춥니다 — `secrets/license.json` 확인 |
