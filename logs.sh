#!/usr/bin/env bash
# logs.sh — 요청 로그(감사 추적) 보기·내보내기 (직접 설치 방식)
#   logs.sh              최근 20건 요약
#   logs.sh -f           실시간
#   logs.sh export DIR   로그 파일을 DIR 로 복사 (보관·제출용)
#   logs.sh admin        관리 작업 감사로그(설정 변경 이력, DB 저장)
source "$(dirname "$0")/lib.sh"
load_env; native_env
LOG="$LOGS/audit.log"
case "${1:-}" in
  -f)     tail -f "$LOG" ;;
  export) dir=${2:?"저장할 디렉토리를 지정하세요"}; mkdir -p "$dir"
          out="$dir/kong-audit-$(date +%Y%m%d-%H%M%S).log"
          cp "$LOG" "$out" && note "저장: $out ($(wc -l < "$out")건, $(du -h "$out" | cut -f1))" ;;
  admin)  # 설정을 바꾼 요청만 (조회 GET 제외). 30일 보관 후 자동 삭제.
          PGOPTIONS="-c client_min_messages=warning" "$PG_BIN/psql" -h "$RUN_DIR" -p "$PG_PORT" -U postgres -d kong \
            -P footer=off -c \
            "select to_char((request_timestamp at time zone 'UTC') at time zone 'Asia/Seoul', 'MM-DD HH24:MI:SS') as \"시각(KST)\",
                    rbac_user_name as 사용자,
                    method, path, status
               from audit_requests where method <> 'GET'
              order by request_timestamp desc limit 20" ;;
  *)      [ -s "$LOG" ] || { note "아직 기록된 요청이 없습니다."; exit 0; }
          python3 - "$LOG" <<'PY'
import json, sys, time
rows = open(sys.argv[1], encoding="utf-8").read().splitlines()[-20:]
print("  %-14s %-12s %4s  %-34s %-14s %6s  %s" % ("시각(KST)", "사용자", "상태", "경로", "모델", "토큰", "캐시"))
for line in rows:
    try: d = json.loads(line)
    except ValueError: continue
    ai = d.get("ai") or {}
    ai = ai.get("proxy") or next(iter(ai.values()), {}) if isinstance(ai, dict) else {}
    meta, usage, cache = ai.get("meta") or {}, ai.get("usage") or {}, ai.get("cache") or {}
    model = meta.get("response_model") or meta.get("request_model") or "-"
    if model == "UNSPECIFIED": model = "-"
    t = time.strftime("%m-%d %H:%M:%S", time.gmtime((d.get("started_at") or 0) / 1000 + 9 * 3600))
    print("  %-14s %-12s %4s  %-34s %-14s %6s  %s" % (t, (d.get("consumer") or {}).get("username", "-"),
          (d.get("response") or {}).get("status", "-"), ((d.get("request") or {}).get("uri") or "")[:34],
          model[:14], usage.get("total_tokens", "-"), cache.get("cache_status", "")))
PY
          ;;
esac
