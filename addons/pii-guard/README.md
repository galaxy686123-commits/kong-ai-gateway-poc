# 한국어 PII 가드레일 (선택)

Kong 의 `ai-custom-guardrail` 플러그인이 호출하는 판정 서비스입니다.
주민등록번호(체크섬 검증)·외국인등록번호·여권·운전면허·계좌·카드·사업자등록번호 등
한국 고유 식별자를 탐지합니다.

`start.sh` 가 포트 18080 으로 자동 기동하고, 라이선스가 있으면 `/poc/pii/v1/chat/completions` 시나리오를
활성화합니다 (`ai-custom-guardrail` 은 Enterprise 플러그인).

- 파이썬 표준 라이브러리만 사용 — 패키지 설치 없이 파드의 `python3` 로 실행
- `.env` 의 `PII_LLM_ENABLED=true` 로 두면 정규식 외에 채팅 모델로 문맥 판정을 추가합니다
