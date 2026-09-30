#!/usr/bin/env bash
# native/status.sh — 프로세스·라우트 상태 (직접 설치 방식). 자세한 점검은 native/verify.sh
source "$(dirname "$0")/lib.sh"
load_env; native_env
say "프로세스"
if pg_ready; then note "PostgreSQL   실행 중 (127.0.0.1:$PG_PORT, $(pg_datadir))"; else note "PostgreSQL   멈춤"; fi
if pii_running; then note "PII 가드     실행 중 (127.0.0.1:$PII_PORT)"; else note "PII 가드     멈춤"; fi
if kong_up; then note "Kong         실행 중 (프록시 :$PROXY_PORT · Admin 127.0.0.1:$ADMIN_PORT · Manager 127.0.0.1:$MANAGER_PORT)"
else note "Kong         멈춤"; exit 0; fi
say "라우트"
admin /routes | python3 -c '
import json, sys
for r in sorted(json.load(sys.stdin).get("data", []), key=lambda r: r.get("name") or ""):
    print("  %-26s %s" % (r.get("name"), ", ".join(r.get("paths") or [])))'
