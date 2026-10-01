#!/usr/bin/env bash
# stop.sh — Kong·PII 가드·모의 서버·PostgreSQL 을 내린다. 데이터(DATA_DIR)는 남긴다.
source "$(dirname "$0")/lib.sh"
load_env; native_env
say "정지"
if kong_up; then kong stop -p "$KONG_PREFIX" >/dev/null 2>&1 && note "Kong 정지"; fi
if pii_running; then kill "$(pii_pid)" && note "PII 가드 정지"; fi
rm -f "$RUN_DIR/pii.pid"
if mock_running; then kill "$(mock_pid)" && note "모의 서버 정지"; fi
rm -f "$RUN_DIR/mock.pid"
PGD=$(pg_datadir)
if pg_ready; then "$PG_BIN/pg_ctl" -D "$PGD" -m fast -w stop >/dev/null && note "PostgreSQL 정지"; fi
note "데이터는 그대로: $DATA_DIR"
