# 한국어 PII 가드

Kong 의 `ai-custom-guardrail` 플러그인이 호출하는 판정 서비스입니다. `start.sh` 가 `127.0.0.1:18080` 으로 띄웁니다.

| 검사 | 쓰는 곳 |
|---|---|
| **질문** — 주민등록번호(체크섬)·외국인등록번호·여권·운전면허·계좌·카드·사업자등록번호 등 한국 고유 식별자 | (선택) 질문 차단용 |
| **답변** (`source: OUTPUT`) — 유해 표현 목록(`.env` 의 `PII_HARMFUL_WORDS`, 쉼표 구분)에 걸리면 차단 | 4-4 유해 답변 → 표준 문구 (통합 경로의 `FEATURE_OUTPUT_GUARD` · `/features/output-guard`) |

- 파이썬 표준 라이브러리만 사용 — 패키지 설치 없이 파드의 `python3` 로 실행
- `.env` 의 `PII_LLM_ENABLED=true` 와 `PII_LLM_URL`·`PII_LLM_MODEL` 을 넣으면 정규식 외에 채팅 모델로 문맥 판정(이름+계약 정보 결합 등)을 더합니다
- 질문 속 개인정보를 **가리는**(마스킹) 4-1 은 이 서비스가 아니라 Kong 의 `pre-function` 이 합니다 (`conf/00-base.yaml`)
