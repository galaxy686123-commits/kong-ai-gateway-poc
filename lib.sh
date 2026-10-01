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
KONG_VER=3.15.0.6
KONG_DEB=kong-enterprise-edition_${KONG_VER}_amd64.deb
DECK_VER=1.65.1
DECK_TGZ=deck_${DECK_VER}_linux_amd64.tar.gz

native_env() {  # load_env 다음에 부른다
  : "${PKGS_DIR:=$ROOT/pkgs}"               # 설치 파일 (Kong .deb · decK) — 저장소에 포함
  : "${DATA_DIR:=$ROOT/data}"                # DB·로그 — 파드를 다시 만들어도 남는 곳에 둔다
  : "${RUN_DIR:=$HOME/.kong-poc}"            # 실행 중에만 필요한 파일(소켓·pid) — 로컬 디스크
  : "${PG_PORT:=5432}" "${PII_PORT:=18080}" "${KONG_WORKERS:=2}"
  LOGS=$DATA_DIR/logs
  KONG_PREFIX=$RUN_DIR/kong
  PII_APP=$ROOT/addons/pii-guard/app.py
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
  export KONG_PROXY_ERROR_LOG="$LOGS/kong-error.log" KONG_ADMIN_ERROR_LOG="$LOGS/kong-error.log"
  # vault 참조 {vault://env/...} 가 읽는 값
  export LLM_AUTH_HEADER="${LLM_AUTH_HEADER:-Bearer none}"
  export EMBED_AUTH_HEADER="${EMBED_AUTH_HEADER:-Bearer none}"
  export PGVECTOR_PASSWORD="$KONG_PG_PASSWORD"
  KONG_LICENSE_DATA="$(license_data)"
  if [ -n "$KONG_LICENSE_DATA" ]; then export KONG_LICENSE_DATA; else unset KONG_LICENSE_DATA; fi
}
kong_up() { kong health -p "$KONG_PREFIX" >/dev/null 2>&1; }
admin() {  # admin <경로> [curl 옵션...] — RBAC 토큰으로 Admin API 호출
  local p=$1; shift
  curl -s -m 10 -H "Kong-Admin-Token: $KONG_ADMIN_PASSWORD" "$@" "http://127.0.0.1:$ADMIN_PORT$p"
}
