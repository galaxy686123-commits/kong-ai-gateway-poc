#!/usr/bin/env bash
# status.sh — 프로세스·라우트 상태 (직접 설치 방식). 자세한 점검은 verify.sh
source "$(dirname "$0")/lib.sh"
load_env; native_env
say "위치"
note "설정 파일  $ENV_FILE"
license_state; note "라이선스   $LICENSE_FILE — $LIC_MSG"
note "유지 폴더  $DATA_DIR"
lock_read
note "코드       $(code_where)"
if [ "$ROOT" != "$DATA_DIR/code" ] && [ -f "$DATA_DIR/code/run.sh" ]; then
  if [ "$LOCK_HOST" = "$HOST_ID" ] && [ ! -w "$ROOT" ]; then   # 빌드한 새 환경인데 사본이 아니라 스냅샷으로 도는 중
    note "           유지 폴더의 코드 사본($(code_info "$DATA_DIR/code"))이 있지만 빌드 스냅샷으로 도는 중 — 사본이 연속 $(cat "$DATA_DIR/code-fails" 2>/dev/null || echo 0)회 기동에 실패함. 고쳐서 bash remote.sh update, 또는 bash remote.sh rollback"
  else note "           유지 폴더에 코드 사본 있음 — $(code_info "$DATA_DIR/code") (빌드한 새 환경은 이 코드로 돈다)"; fi
fi
if [ -z "$LOCK_HOST" ]; then note "실행 환경  없음 (실행 기록 없음)"
elif [ "$LOCK_HOST" = "$HOST_ID" ]; then note "실행 환경  이 환경 ($HOST_ID)"
elif [ "$LOCK_AGE" -lt "$LOCK_STALE" ]; then note "실행 환경  다른 환경 $LOCK_HOST (${LOCK_AGE}초 전 확인) — 그쪽 일은 bash remote.sh 로 맡긴다"
else note "실행 환경  없음 (마지막 기록 $LOCK_HOST, ${LOCK_AGE}초 전 — 멈춤)"; fi
say "프로세스"
if pg_ready; then note "PostgreSQL   실행 중 (127.0.0.1:$PG_PORT, $(pg_datadir))"; else note "PostgreSQL   멈춤"; fi
if pii_running; then note "PII 가드     실행 중 (127.0.0.1:$PII_PORT)"; else note "PII 가드     멈춤"; fi
if mock_running; then note "모의 서버    실행 중 (127.0.0.1:$MOCK_PORT — 시험용)"; else note "모의 서버    멈춤"; fi
if mon_on; then
  if prom_running; then note "Prometheus   실행 중 (127.0.0.1:$PROM_PORT — Kong 지표 수집)"; else note "Prometheus   멈춤"; fi
  if grafana_running; then note "Grafana      실행 중 (127.0.0.1:$GRAFANA_PORT — 프록시의 /grafana)"; else note "Grafana      멈춤"; fi
fi
if kong_up; then note "Kong         실행 중 (프록시 :$PROXY_PORT · Admin $BIND:$ADMIN_PORT · Manager $BIND:$MANAGER_PORT · 지표 :$STATUS_PORT)"
else note "Kong         멈춤"; exit 0; fi
say "라우트"
admin /routes | python3 -c '
import json, sys
for r in sorted(json.load(sys.stdin).get("data", []), key=lambda r: r.get("name") or ""):
    print("  %-26s %s" % (r.get("name"), ", ".join(r.get("paths") or [])))'
