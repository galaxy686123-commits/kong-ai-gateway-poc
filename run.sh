#!/usr/bin/env bash
# run.sh — 빌드한 새 환경의 시작 명령. 빠진 프로그램 설치 → 기동 → 떠 있는 동안 지키고, 종료 신호를 받으면 차례로 내린다.
#   플랫폼의 시작 명령에:  bash /project/work/flow/kong-ai-gateway-poc/run.sh
#   이 명령은 끝나지 않는다 (명령이 끝나면 환경이 끝난 것으로 보는 플랫폼이 많다). 개발 파드에서는 start.sh·stop.sh 를 쓴다.
#   떠 있는 동안 같은 유지 폴더를 붙인 개발 파드에서  bash remote.sh status|apply|restart|verify  로 일을 맡길 수 있다.
source "$(dirname "$0")/lib.sh"
load_env; native_env
set +e

say "환경 확인 — $HOST_ID · $(id -un) (uid $(id -u))"
note "저장소    $ROOT $([ -w "$ROOT" ] && echo '(쓰기 가능)' || echo '(읽기 전용 — 빌드 스냅샷)')"
note "유지 폴더 $DATA_DIR $(df -PTh "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print "(" $2 " · " $5 " 남음)"}')"
note "설정 파일 $ENV_FILE"
if sudo -n true 2>/dev/null; then note "sudo      됨"; else note "sudo      안 됨 — 빠진 프로그램을 설치할 수 없습니다"; fi

stop_all() { say "종료 신호 — 차례로 내립니다"; bash "$ROOT/stop.sh"; exit 0; }
trap stop_all TERM INT

bash "$ROOT/start.sh" || { note "기동 실패 — 위 메시지를 확인하세요 (로그 $LOGS)"; exit 1; }

# 처음 만든 DB 라 설정이 비어 있으면 요구사항 설정을 한 번 넣는다 (이미 있으면 그대로 — Manager 에서 바꾼 값을 지키려고)
n=$(admin /routes | python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("data") or []))' 2>/dev/null)
if [ "$n" = 0 ]; then
  license_state
  case "$LIC_STATE" in
    valid|grace) say "처음 만든 DB — 요구사항 설정을 적용합니다"; bash "$ROOT/apply-config.sh" ;;
    *) note "라이선스가 없어 설정 적용은 건너뜀 — bash set-license.sh 로 넣은 뒤 bash remote.sh restart · bash remote.sh apply" ;;
  esac
fi
# 유지 폴더가 개발 파드와 다른 경로로 붙었으면(바로가기 없음) Kong 설정 속 요청 로그 위치를 이 환경의 경로로 맞춘다
lp=$(admin '/plugins?name=file-log' | python3 -c 'import json, sys; d = json.load(sys.stdin).get("data") or []; print(d[0]["config"]["path"] if d else "")' 2>/dev/null)
if [ "$n" != 0 ] && [ -n "$lp" ] && [ ! -d "$(dirname "$lp")" ]; then
  license_state
  case "$LIC_STATE" in
    valid|grace) say "요청 로그 위치($lp)가 이 환경에 없어 설정을 다시 적용합니다 → $LOGS/audit.log"; bash "$ROOT/apply-config.sh" ;;
    *) note "⚠ 요청 로그 위치($lp)가 이 환경에 없는데 라이선스가 없어 설정을 다시 적용하지 못했습니다" ;;
  esac
fi

REQ="$DATA_DIR/requests"
mkdir -p "$REQ/done"
handle() {  # 개발 파드가 remote.sh 로 맡긴 일 — 정해진 것만 한다
  local f=$1 id cmd out
  id=$(basename "$f" .req); cmd=$(head -1 "$f" 2>/dev/null); rm -f "$f"
  out="$REQ/done/$id.log"
  note "$(date '+%F %T') 요청: $cmd"
  {
    case "$cmd" in
      status)      bash "$ROOT/status.sh" ;;
      apply)       bash "$ROOT/apply-config.sh" ;;
      apply-dry)   bash "$ROOT/apply-config.sh" --dry-run ;;
      restart)     bash "$ROOT/stop.sh" && bash "$ROOT/start.sh" ;;
      verify)      bash "$ROOT/verify.sh" ;;
      verify-full) bash "$ROOT/verify.sh" --full ;;
      *)           echo "모르는 요청: $cmd"; false ;;
    esac
    echo "== 끝 — 종료 코드 $? · $(date '+%F %T') · $HOST_ID"
  } > "$out.tmp" 2>&1
  mv -f "$out.tmp" "$out"
}

say "실행 중 — 이 명령이 떠 있는 동안 Kong 이 돕니다 (개발 파드에서 확인: bash remote.sh status)"
tick=0
while :; do
  sleep 3 & wait $!
  for f in "$REQ"/*.req; do [ -f "$f" ] && handle "$f"; done
  tick=$((tick + 1)); [ $((tick % 5)) = 0 ] || continue          # 약 15초마다 상태 확인
  if ! kong_up || ! pg_ready || { [ -f "$PII_APP" ] && ! pii_running; }; then
    note "$(date '+%F %T') 멈춘 프로그램이 있어 다시 띄웁니다"
    if ! bash "$ROOT/start.sh" > "$LOGS/run-restart.log" 2>&1; then
      tail -5 "$LOGS/run-restart.log" | sed 's/^/  | /'
      note "다시 띄우지 못해 종료합니다 ($LOGS/run-restart.log)"
      bash "$ROOT/stop.sh"; exit 1
    fi
  fi
done
