#!/usr/bin/env bash
# stop.sh — Kong·PII 가드·모의 서버·Prometheus·Grafana·PostgreSQL 을 내린다. 데이터(DATA_DIR)는 남긴다.
source "$(dirname "$0")/lib.sh"
load_env; native_env
say "정지"
if kong_up; then kong stop -p "$KONG_PREFIX" >/dev/null 2>&1 && note "Kong 정지"; fi
if pii_running; then kill "$(pii_pid)" && note "PII 가드 정지"; fi
rm -f "$RUN_DIR/pii.pid"
if mock_running; then kill "$(mock_pid)" && note "모의 서버 정지"; fi
rm -f "$RUN_DIR/mock.pid"
if grafana_running; then kill "$(cat "$RUN_DIR/grafana.pid")" && note "Grafana 정지"; fi
rm -f "$RUN_DIR/grafana.pid"
prom_copy_stop   # 5분마다 지표 기록 사본을 만들던 프로세스
prom_was=0
if prom_running; then kill "$(cat "$RUN_DIR/prometheus.pid")"; prom_was=1; fi   # 내려가는 동안 PostgreSQL 을 먼저 내린다
PGD=$(pg_datadir)
if pg_ready; then "$PG_BIN/pg_ctl" -D "$PGD" -m fast -w stop >/dev/null && note "PostgreSQL 정지"; fi
if [ "$prom_was" = 1 ]; then
  for _ in $(seq 1 40); do prom_running || break; sleep 0.5; done
  # 20초 안에 안 내려가면 끊는다 — 기록은 갑자기 꺼진 것과 같아지고, 다음에 뜰 때 Prometheus 가 스스로 고친다
  if prom_running; then kill -9 "$(cat "$RUN_DIR/prometheus.pid")" 2>/dev/null || true; sleep 1; fi
  note "Prometheus 정지"
fi
rm -f "$RUN_DIR/prometheus.pid"
# 지표 기록 사본에 최근 기록까지 — 다시 빌드한 새 환경이 이어 쓴다. 실행 기록(run.lock)을 지우기 전에 해야 새 환경이 끝난 사본을 받는다
lock_read
if prom_persist && [ -d "$RUN_DIR/prometheus" ] && { [ -z "$LOCK_HOST" ] || [ "$LOCK_HOST" = "$HOST_ID" ] || [ "$LOCK_AGE" -ge "$LOCK_STALE" ]; }; then
  if prom_copy final >> "$LOGS/prometheus-copy.log" 2>&1; then note "지표 기록 사본 → $DATA_DIR/prometheus (최근 기록까지)"
  else note "지표 기록 사본을 다 남기지 못함 ($LOGS/prometheus-copy.log)"; fi
fi
lock_release     # 실행 기록을 지운다 — 이제 다른 환경(빌드한 새 환경 등)이 이 유지 폴더로 뜰 수 있다
note "데이터는 그대로: $DATA_DIR"
