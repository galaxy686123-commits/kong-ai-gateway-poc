# 모니터링 (요구사항 3-3) — Prometheus + Grafana

`MONITORING=on`(기본)이면 `start.sh` 가 파드 안에 두 프로그램을 띄웁니다.

| 프로그램 | 받는 곳 | 하는 일 |
|---|---|---|
| Prometheus (Ubuntu 저장소, apt) | `127.0.0.1:9090` (파드 안) | Kong 지표 `:8100/metrics` 를 15초마다 모으고 `alerts/kong-alerts.yml` 경보 규칙을 계산. 15일 · 2GB 보관 |
| Grafana 12.4.12 (`pkgs/` 에 포함) | `127.0.0.1:3000` → Kong 경로 **`/grafana`** | 대시보드 두 개 — 화면은 프록시 주소(8000)의 `/grafana/` |

대시보드 (`grafana/dashboards/`, 폴더 「Kong AI Gateway PoC」):

| 대시보드 | 내용 |
|---|---|
| **Kong AI Gateway PoC** (첫 화면) | 요청·LLM 요청·토큰 /분 · 게이트웨이 오버헤드와 LLM 지연(TTFT·TPOT) · 사용자·모델별 토큰·비용 · 정책 차단(400·401·403·429·503) · /poc 응답 코드(켠 플러그인이 막은 결과) · 라이선스 남은 날 |
| **Kong (official)** | Kong 공식 대시보드 그대로 — 요청·지연·대역폭·연결·메모리. [Kong/kong](https://github.com/Kong/kong/blob/master/kong/plugins/prometheus/grafana/kong-official.json) 의 `kong-official.json`(Apache-2.0, grafana.com 대시보드 7424 와 같은 계열)에서 데이터 원본만 연결. 업스트림 상태 패널은 이 번들이 업스트림을 쓰지 않아 비어 있음 |

- 로그인: `admin` / 설정 파일의 `GRAFANA_ADMIN_PASSWORD` (비어 있으면 처음 기동할 때 만들어 적음).
- 대시보드·데이터 원본은 이 폴더의 파일로 들어갑니다(`grafana/provisioning`, `grafana/dashboards`). 화면에서 고친 내용은 저장되지 않으니
  JSON 을 고쳐 다시 띄웁니다.
- 지표 기록(Prometheus)은 로컬 디스크(`~/.kong-poc/prometheus`)에서 돕니다 — Prometheus 저장소는 NFS 를 지원하지 않음.
  다시 빌드해도 그래프가 이어지게 유지 폴더의 `prometheus/` 에 사본을 두고(완성된 블록은 5분마다, 최근 기록은 종료할 때),
  새 환경이 뜰 때 되살립니다(`lib.sh` 의 `prom_copy` · `prom_restore`). 종료 신호 없이 끊기면 최근 기록(최대 약 3시간)은 빠집니다.
  보관은 `PROM_RETENTION`(15d) · `PROM_RETENTION_SIZE`(2GB) 가운데 먼저 닿는 쪽까지. `PROM_PERSIST=off` 면 사본 없음.
- Grafana 내부 DB 는 로컬 디스크(`~/.kong-poc/grafana-data`)에 둡니다 — 대시보드·데이터 원본은 파일로 다시 만들어지므로 잃는 것은
  화면에서 바꾼 설정(비밀번호 포함 — 로그인은 늘 설정 파일 값으로 돌아옴)뿐입니다.
- 외부로 나가는 호출(업데이트 확인·사용 통계·뉴스·플러그인 자동 설치)은 모두 끕니다.

## Grafana 설치 파일

`pkgs/grafana-12.4.12.slim.tar.xz.part-00` · `part-01` — Grafana OSS 12.4.12 공식 배포본
(`grafana-12.4.12.linux-amd64.tar.gz`, SHA-256 `4d6d433f…b83e55`)에서 크기를 줄인 것입니다.
GitHub 파일 크기 상한(100MB) 때문에 나눠 두었고, `install.sh` 가 합쳐 `pkgs/grafana.sha256` 으로 확인한 뒤 풉니다.

- 바꾼 것: 실행 파일의 디버그 정보 제거(`strip`), 소스맵(`*.map`)·`docs/` 삭제. 코드와 동작은 그대로입니다.
- 라이선스: Grafana OSS 는 GNU AGPL v3 입니다(묶음 안의 `LICENSE`). 소스: <https://github.com/grafana/grafana/tree/v12.4.12>
