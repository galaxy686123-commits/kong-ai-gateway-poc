# shellcheck shell=bash
# shellcheck disable=SC2034   # 아래 변수들은 이 파일을 source 하는 스크립트가 쓴다
# 공통 함수 — 다른 스크립트가 source 한다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

NET=kong-poc
C_PG=kong-poc-postgres
C_KONG=kong-poc-kong
C_PII=kong-poc-pii
PG_VOLUME=kong-poc-pgdata
LOG_VOLUME=kong-poc-logs

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
  : "${KONG_IMAGE:=kong/kong-gateway:3.15}" "${PG_IMAGE:=pgvector/pgvector:pg16}"
  : "${DECK_IMAGE:=kong/deck:v1.65.1}"      "${PY_IMAGE:=python:3.12-slim}"
  : "${PROXY_PORT:=8000}" "${ADMIN_PORT:=8001}" "${MANAGER_PORT:=8002}"
  : "${MANAGER_URL:=http://localhost:${MANAGER_PORT}}" "${ADMIN_API_URL:=http://localhost:${ADMIN_PORT}}"
  : "${LICENSE_FILE:=./secrets/license.json}"
  for v in KONG_PG_PASSWORD KONG_ADMIN_PASSWORD KONG_SESSION_SECRET DECK_CHAT_URL DECK_CHAT_MODEL DECK_CLIENT_KEY; do
    val="${!v:-}"
    [ -n "$val" ] || die ".env 의 $v 가 비어 있습니다."
    case "$val" in change-me*) die ".env 의 $v 를 기본값에서 바꿔 주세요.";; esac
  done
}

# 이미지가 로컬에 없으면 images/*.tar 에서 load, 그래도 없으면 pull
ensure_image() {
  local img=$1 tar
  docker image inspect "$img" >/dev/null 2>&1 && return 0
  tar="images/$(echo "$img" | tr '/:' '--').tar"
  if [ -f "$tar" ]; then note "load  $tar"; docker load -q -i "$tar" >/dev/null
  else note "pull  $img"; docker pull -q "$img" >/dev/null || die "$img 을 받을 수 없습니다. 인터넷 PC 에서 ./bundle.sh 로 반입하세요."
  fi
}

build() {  # 이름 Dockerfile [build-arg...] — 실패할 때만 출력을 보여준다
  local tag=$1 file=$2; shift 2
  local out; out=$(docker build -q -t "$tag" "$@" -f "$file" . 2>&1) || { echo "$out"; die "$tag 빌드 실패"; }
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }


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

check_license() {  # 컨테이너 방식: 설정을 적용해야 하므로 읽기 전용이 될 상태면 멈춘다
  license_state
  case "$LIC_STATE" in
    valid) if [ "$LIC_DAYS" -le 30 ]; then note "⚠ 라이선스 만료 임박: $LIC_MSG"; else note "라이선스 $LIC_MSG"; fi ;;
    grace) note "⚠ 라이선스 $LIC_MSG" ;;
    *)     die "Kong Enterprise $LIC_MSG.
  라이선스 없이는 Admin API 쓰기가 막혀 설정을 하나도 적용할 수 없습니다." ;;
  esac
}

license_data() {
  if [ -f "$LICENSE_FILE" ]; then cat "$LICENSE_FILE"
  else echo ""; fi
}

kong_env() {  # docker run 에 넘길 Kong 환경변수
  local lic; lic="$(license_data)"
  KONG_ENV=(
    -e KONG_DATABASE=postgres
    -e KONG_PG_HOST="$C_PG" -e KONG_PG_USER=kong -e KONG_PG_DATABASE=kong
    -e KONG_PG_PASSWORD="$KONG_PG_PASSWORD"
    -e KONG_PASSWORD="$KONG_ADMIN_PASSWORD"
    -e KONG_ENFORCE_RBAC=on
    -e KONG_AUDIT_LOG=on                     # 관리 작업(설정 변경) 감사로그 → DB, 30일 보관
    -e KONG_ADMIN_GUI_AUTH=basic-auth
    -e KONG_ADMIN_GUI_SESSION_CONF="{\"secret\":\"$KONG_SESSION_SECRET\",\"cookie_secure\":false}"
    -e KONG_ADMIN_LISTEN="0.0.0.0:8001"
    -e KONG_ADMIN_GUI_LISTEN="0.0.0.0:8002"
    -e KONG_ADMIN_GUI_URL="$MANAGER_URL"
    -e KONG_ADMIN_GUI_API_URL="$ADMIN_API_URL"
    -e KONG_PROXY_LISTEN="0.0.0.0:8000"
    -e KONG_NGINX_WORKER_PROCESSES=1
    -e KONG_PROXY_ACCESS_LOG=/dev/stdout -e KONG_PROXY_ERROR_LOG=/dev/stderr
    -e KONG_ADMIN_ACCESS_LOG=/dev/stdout -e KONG_ADMIN_ERROR_LOG=/dev/stderr
    # vault 참조 {vault://env/...} 가 읽는 값
    -e LLM_AUTH_HEADER="${LLM_AUTH_HEADER:-Bearer none}"
    -e EMBED_AUTH_HEADER="${EMBED_AUTH_HEADER:-Bearer none}"
    -e PGVECTOR_PASSWORD="$KONG_PG_PASSWORD"
  )
  [ -n "$lic" ] && KONG_ENV+=(-e KONG_LICENSE_DATA="$lic")
  return 0
}
