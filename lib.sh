# shellcheck shell=bash
# shellcheck disable=SC2034   # 아래 변수들은 이 파일을 source 하는 스크립트가 쓴다
# 공통 함수 — 다른 스크립트가 source 한다. docker 없이 파드에 직접 설치한 Kong·PostgreSQL·PII 가드를 다룬다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

say()  { printf '\n▶ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\n✘ %s\n' "$*" >&2; exit 1; }

load_env() {
  [ -f .env ] || die ".env 가 없습니다.  cp .env.example .env  후 값을 채우세요."
  # .env 를 실행하지 않고 KEY=VALUE 로만 읽는다 (공백·따옴표·줄끝 주석 허용)
  local line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    v="${v%%[[:space:]]#*}"                      # 값 뒤 " # 주석" 제거
    v="${v%"${v##*[![:space:]]}"}"                # 끝 공백 제거
    if [[ "$v" =~ ^\"(.*)\"$ ]] || [[ "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
    export "$k=$v"
  done < .env
  : "${PROXY_PORT:=8000}" "${ADMIN_PORT:=8001}" "${MANAGER_PORT:=8002}"
  : "${MANAGER_URL:=http://localhost:${MANAGER_PORT}}" "${ADMIN_API_URL:=http://localhost:${ADMIN_PORT}}"
  : "${LICENSE_FILE:=./secrets/license.json}"
  for v in KONG_PG_PASSWORD KONG_ADMIN_PASSWORD KONG_SESSION_SECRET DECK_CHAT_URL DECK_CHAT_MODEL DECK_CLIENT_KEY; do
    val="${!v:-}"
    [ -n "$val" ] || die ".env 의 $v 가 비어 있습니다."
    case "$val" in change-me*) die ".env 의 $v 를 기본값에서 바꿔 주세요.";; esac
  done
}

# 라이선스 상태 → LIC_STATE(valid|grace|expired|missing), LIC_MSG, LIC_DAYS(남은 날, 만료면 음수)
# Kong 은 만료일 자정에 만료되고, 그 뒤 유예 기간(Kong 로그 기준 약 30일) 동안은 모든 기능이 그대로 동작한다.
# 라이선스가 없거나 유예 기간도 지나면 읽기 전용 — 기존 설정으로 프록시는 되지만 설정을 바꿀 수 없다.
LIC_GRACE_DAYS=30
license_state() {  # python·jq 없이 동작한다
  LIC_STATE=missing; LIC_DAYS=""; LIC_MSG="라이선스 없음 ($LICENSE_FILE)"
  [ -f "$LICENSE_FILE" ] || return 0
  local exp end
  exp=$(tr -d ' \n' < "$LICENSE_FILE" | grep -o '"license_expiration_date":"[0-9-]*"' | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | head -1)
  if [ -z "$exp" ]; then LIC_MSG="라이선스 파일 형식을 읽을 수 없음 ($LICENSE_FILE)"; return 0; fi
  LIC_DAYS=$(( ( $(date -d "$exp" +%s) - $(date -d "$(date +%F)" +%s) ) / 86400 ))
  end=$(date -d "$exp + $LIC_GRACE_DAYS days" +%F)
  if [ "$LIC_DAYS" -ge 0 ]; then LIC_STATE=valid; LIC_MSG="만료일 $exp (D-$LIC_DAYS)"
  elif [ $(( -LIC_DAYS )) -le "$LIC_GRACE_DAYS" ]; then
    LIC_STATE=grace; LIC_MSG="만료됨 ($exp) — 유예 기간이라 $end 까지는 모두 동작, 그 뒤 읽기 전용"
  else LIC_STATE=expired; LIC_MSG="만료됨 ($exp, 유예 기간도 $end 에 끝남) — 읽기 전용"; fi
}

license_data() {
  if [ -f "$LICENSE_FILE" ]; then cat "$LICENSE_FILE"
  else echo ""; fi
}

PG_VER=14                                   # Ubuntu 22.04 기본 저장소의 PostgreSQL
PG_BIN=/usr/lib/postgresql/$PG_VER/bin
PGVECTOR_TAG=v0.8.6                         # GitHub 에서 소스를 받아 빌드 (apt 에 없음)
KONG_VER=3.16.0.0
KONG_DEB=kong-enterprise-edition_${KONG_VER}_amd64.deb
DECK_VER=1.65.1
DECK_TGZ=deck_${DECK_VER}_linux_amd64.tar.gz

native_env() {  # load_env 다음에 부른다
  : "${PKGS_DIR:=$ROOT/pkgs}"               # 설치 파일 (Kong .deb · decK) — 저장소에 포함
  : "${DATA_DIR:=$ROOT/data}"                # DB·로그 — 파드를 다시 만들어도 남는 곳에 둔다
  : "${RUN_DIR:=$HOME/.kong-poc}"            # 실행 중에만 필요한 파일(소켓·pid) — 로컬 디스크
  : "${PG_PORT:=5432}" "${PII_PORT:=18080}" "${MOCK_PORT:=18090}" "${STATUS_PORT:=8100}" "${KONG_WORKERS:=2}"
  LOGS=$DATA_DIR/logs
  KONG_PREFIX=$RUN_DIR/kong
  PII_APP=$ROOT/addons/pii-guard/app.py
  MOCK_APP=$ROOT/addons/mock/app.py
  mkdir -p "$LOGS" "$RUN_DIR"; chmod 700 "$RUN_DIR"

  # 주피터를 거쳐 Kong Manager 를 연다 (jupyter-server-proxy).
  #   Manager 화면: <주피터>/proxy/absolute/8002  — 경로를 그대로 넘기므로 Kong 이 같은 경로로 서비스
  #   Admin API   : <주피터>/proxy/8001           — 앞 경로를 떼고 넘기므로 Admin API 경로 그대로
  #   플랫폼이 포트를 밖으로 열어 주는 경우엔 JUPYTER_URL 을 비우고 MANAGER_URL·ADMIN_API_URL 에 그 주소를 넣는다.
  #   바깥 연결은 파드 IP 로 들어오므로 그때는 Admin API·Manager 를 모든 주소(0.0.0.0)에서 받는다.
  GUI_PATH=""; BIND=127.0.0.1
  if [ -n "${JUPYTER_URL:-}" ]; then
    JUPYTER_URL=${JUPYTER_URL%/}
    GUI_PATH="/proxy/absolute/$MANAGER_PORT"
    MANAGER_URL="$JUPYTER_URL$GUI_PATH"
    ADMIN_API_URL="$JUPYTER_URL/proxy/$ADMIN_PORT"
  else
    MANAGER_URL=${MANAGER_URL%/}; ADMIN_API_URL=${ADMIN_API_URL%/}
    case "$MANAGER_URL" in http*://localhost*|http*://127.0.0.1*) ;; *) BIND=0.0.0.0 ;; esac
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }
# 파드를 다시 만들면 apt 로 깐 프로그램은 사라진다 → 하나라도 없으면 install.sh 를 다시 돌린다
installed() {
  [ -x "$PG_BIN/postgres" ] && [ -f "/usr/share/postgresql/$PG_VER/extension/vector.control" ] \
    && have deck && [ "$(kong version 2>/dev/null | awk '{print $NF}')" = "$KONG_VER" ]
}

# ── PostgreSQL (ds_user 권한으로 실행, 데이터는 DATA_DIR) ─────────────
psql_su() { PGOPTIONS="-c client_min_messages=warning" "$PG_BIN/psql" -h "$RUN_DIR" -p "$PG_PORT" -U postgres -v ON_ERROR_STOP=1 -qAt "$@"; }
pg_ready() { "$PG_BIN/pg_isready" -q -h "$RUN_DIR" -p "$PG_PORT" 2>/dev/null; }

pg_datadir() {  # 이미 초기화된 곳이 있으면 그곳, 아니면 DATA_DIR 에 만들 수 있는지 본다
  local d="$DATA_DIR/pgdata" l="$RUN_DIR/pgdata"
  if [ -f "$d/PG_VERSION" ]; then echo "$d"; return; fi
  if [ -f "$l/PG_VERSION" ]; then echo "$l"; return; fi
  { mkdir -p "$d" && chmod 700 "$d"; } 2>/dev/null || true
  # NFS 에 따라 소유자·권한을 바꿀 수 없으면 PostgreSQL 이 거부한다 → 로컬 디스크로 대체
  if [ "$(stat -c '%u %a' "$d" 2>/dev/null)" = "$(id -u) 700" ]; then echo "$d"
  else rmdir "$d" 2>/dev/null; echo "$l"; fi
}

# ── 한국어 PII 가드 ────────────────────────────────────────────
pii_pid()     { cat "$RUN_DIR/pii.pid" 2>/dev/null; }
pii_running() { local p; p=$(pii_pid) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# ── 시험용 모의 서버 (가짜 LLM·OCR·Agent·로그/추적 수신 — verify.sh 가 쓴다) ──
mock_pid()     { cat "$RUN_DIR/mock.pid" 2>/dev/null; }
mock_running() { local p; p=$(mock_pid) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# ── conf/*.yaml 의 ${{ env "DECK_…" }} 값 — apply-config.sh·verify.sh 가 같은 값을 쓴다 ──
deck_env() {
  # 이 파드 안의 주소
  DECK_AUDIT_LOG="$LOGS/audit.log"; DECK_PG_HOST=127.0.0.1; DECK_PG_PORT="$PG_PORT"
  DECK_PII_URL="http://127.0.0.1:$PII_PORT/check"; DECK_KONG_LOOPBACK="http://127.0.0.1:$PROXY_PORT"
  DECK_MOCK_URL="http://127.0.0.1:$MOCK_PORT"
  # 정책 기본값 — .env 에서 바꿀 수 있다
  : "${DECK_RPM:=60}" "${DECK_RPD:=5000}" "${DECK_TPM:=20000}" "${DECK_OCR_MAX_MB:=50}"
  : "${DECK_DLP_PATTERN:=(?i)(?:대외비|기밀|사내\s*한정|confidential)}"
  : "${DECK_BLOCK_MESSAGE:=보안 정책에 따라 표시할 수 없습니다.}"
  : "${DECK_OCR_URL:=$DECK_MOCK_URL/ocr}" "${DECK_AGENT_A_URL:=$DECK_MOCK_URL/agents/a}" "${DECK_AGENT_B_URL:=$DECK_MOCK_URL/agents/b}"
  : "${DECK_AZURE_API_VERSION:=2024-06-01}" "${DECK_GCP_LOCATION:=asia-northeast3}" "${DECK_EMBED_DIMS:=1024}"
  # 통합 경로 기능 스위치 — .env 의 FEATURE_xxx=on/off → DECK_ON_xxx=true/false
  local f d v
  for f in MASKING:on ACL:on RATE_LIMIT:on TOKEN_LIMIT:on PROMPT_GUARD:on OUTPUT_GUARD:off OUTPUT_MASK:off \
           SEMANTIC_GUARD:off SEMANTIC_CACHE:off; do
    d=${f#*:}; f=${f%%:*}; v="FEATURE_$f"
    case "${!v:-$d}" in on|true|yes|1) printf -v "DECK_ON_$f" true ;; *) printf -v "DECK_ON_$f" false ;; esac
  done
  # 답변을 다 받아 검사·수정하는 기능을 켜면 통합 경로는 스트리밍 요청을 받지 않는다 (조각으로 나뉜 답은 검사할 수 없다)
  DECK_LLM_STREAMING=allow
  if [ "$DECK_ON_OUTPUT_GUARD" = true ] || [ "$DECK_ON_OUTPUT_MASK" = true ]; then DECK_LLM_STREAMING=deny; fi
  # 기능별 경로가 부를 LLM — 기본은 모의 LLM(결과가 늘 같음), FEATURE_UPSTREAM=llm 이면 사내 LLM
  if [ "${FEATURE_UPSTREAM:-mock}" = llm ]; then
    DECK_FEATURE_URL="$DECK_CHAT_URL"; DECK_FEATURE_MODEL="$DECK_CHAT_MODEL"; DECK_FEATURE_AUTH="{vault://env/llm-auth-header}"
  else
    DECK_FEATURE_URL="$DECK_MOCK_URL/v1/chat/completions"; DECK_FEATURE_MODEL=mock-llm; DECK_FEATURE_AUTH="Bearer mock"
  fi
  # SSO 토큰 캐시용 고정값 — 세션 비밀값에서 만들어 동기화마다 바뀌지 않게
  DECK_OIDC_SALT=$(printf '%s' "$KONG_SESSION_SECRET" | sha256sum | cut -c1-32)
  local v; for v in $(compgen -v DECK_); do export "${v?}"; done
}

# ── LLM 주소가 IP 일 때 ───────────────────────────────────────────
# Kong 3.16 의 AI 플러그인(ai-proxy·ai-proxy-advanced)은 LLM 주소(upstream_url)가 IP 면 그 호스트로 보내지 않고
# (서비스 주소의 호스트로 감) 장애 대체도 하지 않는다. 이름 주소는 정상 동작한다.
# → IP 에는 이름(ip-10-1-2-3.kong-poc)을 붙여 Kong 에 넘기고, 그 이름은 Kong 만 읽는 hosts 파일에 적는다.
#   시스템 /etc/hosts 는 건드리지 않는다. LLM 서버가 받는 Host 헤더도 이 이름이 된다.
AI_URL_VARS="DECK_CHAT_URL DECK_EXT_URL DECK_EMBED_URL DECK_FEATURE_URL DECK_MOCK_URL"
ip_name() { printf 'ip-%s.kong-poc' "${1//./-}"; }
url_ip()  { [[ "$1" =~ ^[a-z]+://([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)([:/]|$) ]] && printf '%s' "${BASH_REMATCH[1]}"; }
ai_url() {  # URL 의 호스트가 IP 면 이름으로 바꾼 URL
  local ip; ip=$(url_ip "$1") || { printf '%s' "$1"; return 0; }
  printf '%s' "${1/"://$ip"/"://$(ip_name "$ip")"}"
}
kong_hosts() {  # Kong 용 hosts 파일을 새로 쓴다 — 내용이 바뀌었을 때만 참(0). 바뀌면 Kong 을 reload 해야 읽는다
  local f="$RUN_DIR/hosts" new ip v
  new=$(cat /etc/hosts 2>/dev/null
        echo "# kong-poc — LLM 주소의 IP 에 붙인 이름 (lib.sh 의 kong_hosts 가 만든다)"
        { for v in DECK_CHAT_URL DECK_EXT_URL DECK_EMBED_URL; do ip=$(url_ip "${!v:-}") && echo "$ip $(ip_name "$ip")"; done
          echo "127.0.0.1 $(ip_name 127.0.0.1)"; } | sort -u)
  if [ -f "$f" ] && [ "$(cat "$f")" = "$new" ]; then return 1; fi
  printf '%s\n' "$new" > "$f"
}

# ── Kong (ds_user 권한으로 실행, prefix 는 로컬 디스크) ────────────────
kong_env() {
  local secure=false; case "$MANAGER_URL" in https:*) secure=true;; esac
  export KONG_PREFIX
  export KONG_DATABASE=postgres KONG_PG_HOST=127.0.0.1 KONG_PG_PORT="$PG_PORT"
  export KONG_PG_USER=kong KONG_PG_DATABASE=kong KONG_PG_PASSWORD
  export KONG_PASSWORD="$KONG_ADMIN_PASSWORD"      # 최초 마이그레이션 때 kong_admin 비밀번호
  export KONG_ENFORCE_RBAC=on
  export KONG_AUDIT_LOG=on                           # 관리 작업(설정 변경) 감사로그 → DB, 30일 보관
  export KONG_ADMIN_GUI_AUTH=basic-auth
  export KONG_ADMIN_GUI_SESSION_CONF="{\"secret\":\"$KONG_SESSION_SECRET\",\"cookie_secure\":$secure}"
  export KONG_PROXY_LISTEN="0.0.0.0:$PROXY_PORT"
  # Admin API·Manager — 주피터 프록시 경유면 파드 안(127.0.0.1)만, 플랫폼 포트 노출이면 모든 주소
  export KONG_ADMIN_LISTEN="$BIND:$ADMIN_PORT"
  export KONG_ADMIN_GUI_LISTEN="$BIND:$MANAGER_PORT"
  export KONG_ADMIN_GUI_URL="$MANAGER_URL" KONG_ADMIN_GUI_API_URL="$ADMIN_API_URL"
  if [ -n "$GUI_PATH" ]; then export KONG_ADMIN_GUI_PATH="$GUI_PATH"; else unset KONG_ADMIN_GUI_PATH; fi
  export KONG_NGINX_WORKER_PROCESSES="$KONG_WORKERS"
  ulimit -n "$(ulimit -Hn)" 2>/dev/null || true                   # 열 수 있는 파일 수를 허용된 최대로 (기본 1024 — 동시 연결 수 상한)
  export KONG_STATUS_LISTEN="0.0.0.0:$STATUS_PORT"                  # 3-3 지표 /metrics
  export KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE="${MAX_BODY_MB:-100}m"  # 1-3 대용량 업로드 상한 (경로별 상한은 설정에서)
  export KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=8m                  # AI 요청 본문을 메모리에 담을 크기
  if [ -n "${DECK_OTEL_ENDPOINT:-}" ]; then                          # 3-2 분산 추적을 켰을 때만
    export KONG_TRACING_INSTRUMENTATIONS=all KONG_TRACING_SAMPLING_RATE=1.0
  else unset KONG_TRACING_INSTRUMENTATIONS KONG_TRACING_SAMPLING_RATE; fi
  export KONG_PROXY_ERROR_LOG="$LOGS/kong-error.log" KONG_ADMIN_ERROR_LOG="$LOGS/kong-error.log"
  [ -f "$RUN_DIR/hosts" ] || kong_hosts || true                     # LLM 주소의 IP 에 붙인 이름 (위 kong_hosts)
  export KONG_DNS_HOSTSFILE="$RUN_DIR/hosts" KONG_RESOLVER_HOSTS_FILE="$RUN_DIR/hosts"
  # vault 참조 {vault://env/...} 가 읽는 값
  export LLM_AUTH_HEADER="${LLM_AUTH_HEADER:-Bearer none}"
  export EMBED_AUTH_HEADER="${EMBED_AUTH_HEADER:-Bearer none}"
  export EXT_AUTH_HEADER="${EXT_AUTH_HEADER:-Bearer none}"
  KONG_LICENSE_DATA="$(license_data)"
  if [ -n "$KONG_LICENSE_DATA" ]; then export KONG_LICENSE_DATA; else unset KONG_LICENSE_DATA; fi
}
kong_up() { kong health -p "$KONG_PREFIX" >/dev/null 2>&1; }
admin() {  # admin <경로> [curl 옵션...] — RBAC 토큰으로 Admin API 호출
  local p=$1; shift
  curl -s -m 10 -H "Kong-Admin-Token: $KONG_ADMIN_PASSWORD" "$@" "http://127.0.0.1:$ADMIN_PORT$p"
}
