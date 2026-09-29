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


check_license() {  # 없거나 만료면 중단, 30일 이내면 경고. python·jq 없이 동작한다.
  [ -f "$LICENSE_FILE" ] || die "Kong Enterprise 라이선스가 없습니다 ($LICENSE_FILE).
  라이선스 없이는 Admin API 쓰기가 막혀 설정을 하나도 적용할 수 없습니다."
  local exp today days
  exp=$(tr -d ' \n' < "$LICENSE_FILE" | grep -o '"license_expiration_date":"[0-9-]*"' | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' | head -1)
  [ -n "$exp" ] || die "라이선스 파일 형식을 읽을 수 없습니다 ($LICENSE_FILE)."
  today=$(date +%Y-%m-%d)
  [[ "$exp" < "$today" ]] && die "Kong Enterprise 라이선스가 만료되었습니다 (만료일 $exp)."
  if days=$(( ( $(date -d "$exp" +%s 2>/dev/null) - $(date +%s) ) / 86400 )) 2>/dev/null && [ "$days" -ge 0 ]; then
    if [ "$days" -le 30 ]; then note "⚠ 라이선스 만료 임박: $exp (D-$days)"; else note "라이선스 만료일 $exp (D-$days)"; fi
  else
    note "라이선스 만료일 $exp"
  fi
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
