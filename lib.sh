# shellcheck shell=bash
# shellcheck disable=SC2034   # 아래 변수들은 이 파일을 source 하는 스크립트가 쓴다
# 공통 함수 — 다른 스크립트가 source 한다. docker 없이 파드에 직접 설치한 Kong·PostgreSQL·PII 가드를 다룬다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

say()  { printf '\n▶ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\n✘ %s\n' "$*" >&2; exit 1; }

# ── 설정 파일 ─────────────────────────────────────────────────
# 처음에는 저장소의 .env 에 모든 설정을 둔다. 유지 폴더(DATA_DIR — bash set-data-dir.sh)를 정하면 설정의 원본은
# 유지 폴더의 settings.env 로 옮겨지고, 저장소의 .env 에는 그 위치(DATA_DIR) 한 줄만 남는다.
# 빌드하면 저장소 폴더는 스냅샷(읽기 전용)이 되므로, 바꿀 수 있어야 하는 것(설정·라이선스·DB·로그)은 전부 유지 폴더에 둔다.
ENV_FILE="$ROOT/.env"

read_env() {  # read_env <파일> — 실행하지 않고 KEY=VALUE 로만 읽는다 (공백·따옴표·줄끝 주석 허용)
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
  done < "$1"
}
env_get() { [ -f "$2" ] && ( unset "$1"; read_env "$2"; printf '%s' "${!1:-}" ); return 0; }   # env_get <키> <파일>
env_full() {  # 위치(DATA_DIR) 말고 다른 설정도 들어 있는 파일인지
  local keys
  keys=$(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$1" 2>/dev/null | grep -vE '^[[:space:]]*DATA_DIR(_REAL)?=') || true
  [ -n "$keys" ]
}
env_set() {  # env_set <키> <값> <파일> — 그 줄을 제자리에서 바꾸고(없으면 끝에 추가) 같은 키가 또 있으면 지운다
  local tmp
  tmp=$(mktemp "$3.XXXXXX") || return 1
  if K="$1" V="$2" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
       $0 ~ "^[[:space:]]*" k "=" { if (!done) { print k "=" v; done = 1 }; next }
       { print }
       END { if (!done) print k "=" v }' "$3" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$3"; then return 0; fi
  rm -f "$tmp"; return 1
}
write_pointer() {  # write_pointer <유지 폴더> — 저장소 .env 를 위치 한 줄짜리로 (저장소 폴더에 쓸 수 있을 때만)
  local tmp
  tmp=$(mktemp "$ROOT/.env.XXXXXX" 2>/dev/null) || return 1
  local real; real=$(cd "$1" 2>/dev/null && pwd -P) || real=$1
  if { echo "# kong-poc — 설정은 유지 폴더에 있습니다: $1/settings.env"
       echo "#   이 파일에는 그 위치만 둡니다. 값 바꾸기: bash set-env.sh <키> <값>"
       echo "DATA_DIR=$1"
       if [ "$real" != "$1" ]; then
         echo "# 위 경로가 바로가기(심볼릭 링크)를 거칠 때의 실제 위치 — 빌드한 새 환경에 바로가기가 없으면 이쪽을 쓴다"
         echo "DATA_DIR_REAL=$real"
       fi; } > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$ROOT/.env"; then return 0; fi
  rm -f "$tmp"; return 1
}
find_mounted_data() {  # find_mounted_data <원래 경로> — 이 환경에 붙은 저장소(마운트) 아래에서 같은 유지 폴더를 찾는다
  # 예) 원래 /project/work/datasets/DTS…/data/kong-poc → 이 환경에선 /datasets/DTS…/data/kong-poc
  #     원래 경로의 끝 2~4단(data/kong-poc · DTS…/data/kong-poc …)을 마운트 지점마다 붙여 보고 settings.env 가 있는 곳만
  local want=${1%/} m t s k n c found="" comps=()
  IFS=/ read -ra comps <<< "${want#/}"
  n=${#comps[@]}
  while read -r _ m t _; do
    case "$t" in proc|sysfs|devpts|cgroup|cgroup2|mqueue|devtmpfs|securityfs|debugfs|tracefs|pstore|bpf|autofs|fusectl|configfs|binfmt_misc|hugetlbfs|rpc_pipefs|nsfs) continue ;; esac
    [ "$m" != / ] || continue
    for k in 2 3 4; do
      [ "$n" -ge "$k" ] || continue
      s=$(IFS=/; printf '%s' "${comps[*]:$((n - k))}")
      c="$m/$s"
      if [ -f "$c/settings.env" ] && [[ " $found " != *" $c "* ]]; then found="$found $c"; fi
    done
  done < /proc/self/mounts
  printf '%s' "${found# }"
}
remember_real() {  # remember_real <유지 폴더> — 바로가기를 거치는 경로면 실제 위치를 저장소 .env 에 함께 적어 둔다
  local real
  real=$(cd "$1" 2>/dev/null && pwd -P) || return 0
  [ "$real" != "$1" ] || return 0
  [ "$(env_get DATA_DIR_REAL "$ROOT/.env")" != "$real" ] || return 0
  if env_full "$ROOT/.env" || [ ! -w "$ROOT" ]; then return 0; fi    # 전체 설정이면 settings_to_data 가 위치 파일을 새로 쓴다
  env_set DATA_DIR_REAL "$real" "$ROOT/.env" 2>/dev/null || true
}
settings_to_data() {  # settings_to_data <유지 폴더> — 저장소 .env 에 아직 전체 설정이 있으면 유지 폴더(settings.env)로 옮긴다
  local d=$1 repo="$ROOT/.env" dst="$1/settings.env" keep=""
  # 이전 방식(저장소 .env 가 원본이고 유지 폴더엔 .env 사본)에서 넘어올 때 — 사본은 이름만 바꾼다
  if [ ! -f "$dst" ] && [ -f "$d/.env" ]; then mv -f "$d/.env" "$dst" 2>/dev/null || true; fi
  env_full "$repo" || return 0                          # 저장소 .env 가 이미 위치 한 줄짜리
  if [ ! -f "$dst" ] || [ "$repo" -nt "$dst" ]; then   # 처음 옮기거나, 저장소 쪽을 더 최근에 고쳤으면 그것을 원본으로
    if [ -f "$dst" ] && ! cmp -s "$repo" "$dst"; then keep="$dst.before-$(date +%Y%m%d-%H%M%S)"; cp -p "$dst" "$keep" 2>/dev/null || keep=""; fi
    if ! (umask 077; cp "$repo" "$dst.tmp" && mv -f "$dst.tmp" "$dst") 2>/dev/null; then
      note "⚠ 유지 폴더($d)에 설정 파일을 쓰지 못해 저장소의 .env 를 그대로 씁니다"; return 0
    fi
  elif ! cmp -s "$repo" "$dst"; then                   # 유지 폴더 쪽이 더 최근 — 그것을 쓰고 저장소 쪽 내용은 보관만
    keep="$d/settings.env.from-repo-$(date +%Y%m%d-%H%M%S)"; (umask 077; cp "$repo" "$keep") 2>/dev/null || keep=""
  fi
  if write_pointer "$d"; then
    note "설정 파일을 유지 폴더로 옮겼습니다 → $dst  (저장소 .env 에는 위치만 남김 · 값 바꾸기: bash set-env.sh)"
  else note "⚠ 저장소 폴더에 쓸 수 없어 .env 를 그대로 둡니다 — 설정은 $dst 를 씁니다"; fi
  if [ -n "$keep" ]; then note "  내용이 달랐던 쪽은 보관해 둠: $keep"; fi
  return 0
}
license_to_data() {  # license_to_data <유지 폴더> — 라이선스의 원본도 유지 폴더로 (저장소에는 남기지 않는다 — 스냅샷에 들어가지 않게)
  local d=$1 repo="$ROOT/secrets/license.json" dst="$1/secrets/license.json"
  [ -f "$repo" ] || return 0
  if [ ! -f "$dst" ] || { ! cmp -s "$repo" "$dst" && [ "$repo" -nt "$dst" ]; }; then
    if ! { mkdir -p "$d/secrets" && chmod 700 "$d/secrets" && cp "$repo" "$dst.tmp" && chmod 600 "$dst.tmp" && mv -f "$dst.tmp" "$dst"; } 2>/dev/null; then
      note "⚠ 유지 폴더에 라이선스를 쓰지 못해 저장소의 secrets/license.json 을 씁니다"; return 0
    fi
    note "라이선스를 유지 폴더로 옮겼습니다 → $dst"
  fi
  if cmp -s "$repo" "$dst"; then rm -f "$repo" 2>/dev/null || true; fi
  return 0
}

repo_leftovers() {  # 저장소 폴더에 남은 DB 사본·설정 백업·비밀값 — 빌드하면 스냅샷에 그대로 들어간다
  local f out=""
  for f in "$ROOT"/data "$ROOT"/data.moved-* "$ROOT"/conf/backup "$ROOT"/conf/backup.moved-* "$ROOT"/.env.before-* "$ROOT"/secrets/*.json; do
    [ -e "$f" ] || continue
    [ "$f" != "${DATA_DIR:-}" ] || continue
    if [ -d "$f" ] && [ -z "$(ls -A "$f" 2>/dev/null)" ]; then continue; fi
    out="$out ${f#"$ROOT"/}"
  done
  if env_full "$ROOT/.env"; then out="$out .env(전체 설정)"; fi
  printf '%s' "${out# }"
}

load_env() {  # load_env [--no-check] — --no-check: 필수값 검사를 건너뛴다 (set-env.sh 로 빈 값을 채울 때)
  # 유지 폴더 위치 — 저장소 .env 의 DATA_DIR. 저장소에 .env 없이 빌드했다면 환경변수 KONG_POC_DATA_DIR 로 줄 수 있다
  local d=${KONG_POC_DATA_DIR:-} r f v val check=1
  if [ "${1:-}" = --no-check ]; then check=0; fi
  [ -n "$d" ] || d=$(env_get DATA_DIR "$ROOT/.env")
  d=${d%/}
  if [ -n "$d" ] && [ "$d" != "$ROOT/data" ]; then
    if [ ! -d "$d" ]; then
      # 빌드한 새 환경에는 주피터용 바로가기(예: /project/work/datasets)가 없을 수 있다 — 적어 둔 실제 위치로 간다
      r=$(env_get DATA_DIR_REAL "$ROOT/.env"); r=${r%/}
      if [ -n "$r" ] && [ -d "$r" ]; then
        note "유지 폴더 $d 가 이 환경에는 없어 실제 위치 $r 를 씁니다"; d=$r
        export KONG_POC_DATA_DIR=$d          # 이 스크립트가 부르는 다른 스크립트도 같은 위치를 쓴다 (안내는 한 번만)
      else
        # 빌드한 새 환경은 유지 폴더를 다른 경로로 붙일 수 있다 — 이 환경에 붙은 저장소에서 같은 폴더를 찾는다
        f=$(find_mounted_data "$d")
        if [ -n "$f" ] && [ "${f// /}" = "$f" ]; then
          note "유지 폴더 $d 가 이 환경에는 없어, 이 환경에 붙은 저장소에서 찾은 $f 를 씁니다"; d=$f
          export KONG_POC_DATA_DIR=$d
        else die "유지 폴더가 없습니다: $d${r:+ (실제 위치 $r 도 없음)}${f:+
  같은 폴더로 보이는 곳이 여러 개입니다: $f}
  이 환경에 유지 폴더(PV · 데이터셋)가 붙어 있는지 확인하세요. 붙은 곳이 다르면 명령 앞에 위치를 주세요:
    KONG_POC_DATA_DIR=<그 경로>/kong-poc bash run.sh"; fi
      fi
    fi
    remember_real "$d"
    settings_to_data "$d"
    if [ -f "$d/settings.env" ]; then ENV_FILE="$d/settings.env"; fi
  fi
  [ -f "$ENV_FILE" ] || die "설정 파일이 없습니다 ($ENV_FILE).  cp .env.example .env  후 값을 채우세요."
  read_env "$ENV_FILE"
  if [ -n "$d" ]; then export DATA_DIR="$d"; fi    # 위치는 저장소 .env(또는 환경변수)가 정한다
  export ENV_FILE
  : "${PROXY_PORT:=8000}" "${ADMIN_PORT:=8001}" "${MANAGER_PORT:=8002}"
  : "${MANAGER_URL:=http://localhost:${MANAGER_PORT}}" "${ADMIN_API_URL:=http://localhost:${ADMIN_PORT}}"
  # 외부 주소에 {ENV_ID} 가 있으면(빌드할 때마다 주소 속 ID 가 바뀌는 플랫폼) Manager 는 요청마다 주소를 맞춘다 (gui_by_host).
  # 여기서는 화면·점검에 보여 줄 주소만 이 환경의 ID(env_id — 파드 이름)로 채운다. 원래 틀은 *_URL_T 에 둔다.
  MANAGER_URL_T=""; ADMIN_API_URL_T=""; ENV_ID=""
  case "$MANAGER_URL $ADMIN_API_URL" in
    *"{ENV_ID}"*)
      MANAGER_URL_T=$MANAGER_URL; ADMIN_API_URL_T=$ADMIN_API_URL
      ENV_ID=$(env_id)
      MANAGER_URL=${MANAGER_URL//\{ENV_ID\}/${ENV_ID:-unknown}}; ADMIN_API_URL=${ADMIN_API_URL//\{ENV_ID\}/${ENV_ID:-unknown}} ;;
  esac
  export MANAGER_URL ADMIN_API_URL MANAGER_URL_T ADMIN_API_URL_T
  # 라이선스 — 따로 정하지 않았으면, 유지 폴더를 쓸 때는 그곳의 secrets/license.json
  case "${LICENSE_FILE:-}" in
    ""|./secrets/license.json|secrets/license.json|"$ROOT/secrets/license.json")
      LICENSE_FILE="$ROOT/secrets/license.json"
      if [ -n "$d" ] && [ "$d" != "$ROOT/data" ]; then
        license_to_data "$d"
        if [ -f "$d/secrets/license.json" ] || [ ! -f "$LICENSE_FILE" ]; then LICENSE_FILE="$d/secrets/license.json"; fi
      fi ;;
  esac
  [ "$check" = 1 ] || return 0
  for v in KONG_PG_PASSWORD KONG_ADMIN_PASSWORD KONG_SESSION_SECRET DECK_CHAT_URL DECK_CHAT_MODEL DECK_CLIENT_KEY; do
    val="${!v:-}"
    [ -n "$val" ] || die "설정 파일($ENV_FILE)의 $v 가 비어 있습니다."
    case "$val" in change-me*) die "설정 파일($ENV_FILE)의 $v 를 기본값에서 바꿔 주세요.";; esac
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
  : "${DATA_DIR:=$ROOT/data}"                # DB·로그 — 파드를 다시 만들어도 남는 곳 (bash set-data-dir.sh <유지 폴더>)
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

# ── 같은 유지 폴더를 두 환경에서 동시에 쓰지 않게 ──────────────────────
# 빌드한 새 환경과 개발 파드가 같은 유지 폴더를 붙이면, 두 PostgreSQL 이 같은 DB 파일을 쓰다가 DB 가 깨진다.
# PostgreSQL 의 잠금(postmaster.pid)은 같은 기계 안에서만 통하므로, 실행 중인 환경의 이름을 run.lock 에 적고
# 20초마다 갱신한다. 90초 넘게 갱신이 없으면 그 환경은 없어진 것으로 보고 이어받는다.
HOST_ID=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)
env_id() {  # 이 환경의 ID — KONG_POC_ENV_ID → 플랫폼의 INFER_SERVICE_ID → 호스트 이름(파드 이름)의 '영문 3자 + 숫자 10자리' 조각
  # 예) pjt20260101-abc2026100001-dp-1a2b3c4d5e-xyz12 → abc2026100001  (pjt20260101 은 숫자 8자리라 프로젝트 ID 로 보고 건너뜀)
  # 빌드한 새 환경은 외부 주소의 ID 가 파드 이름이 아니라 서비스 ID(INFER_SERVICE_ID, 대문자)다 — 소문자로 바꿔 쓴다.
  # 이 값은 화면·기록의 주소와 Kong 의 admin_gui_url(관리자 가입 링크·비밀번호 재설정 링크의 주소)에 쓰인다.
  local t
  if [ -n "${KONG_POC_ENV_ID:-}" ]; then printf '%s' "$KONG_POC_ENV_ID"; return 0; fi
  if [[ "${INFER_SERVICE_ID:-}" =~ ^[A-Za-z]{3}[0-9]{10}$ ]]; then printf '%s' "${INFER_SERVICE_ID,,}"; return 0; fi
  for t in ${HOST_ID//-/ }; do
    if [[ "$t" =~ ^[a-z]{3}[0-9]{10}$ ]]; then printf '%s' "$t"; return 0; fi
  done
  return 0
}
LOCK_STALE=90
lock_read() {  # → LOCK_HOST(실행 중인 환경 이름, 없으면 빈 값) · LOCK_AGE(마지막 갱신 뒤 지난 초)
  local h="" t=0
  if [ -f "$DATA_DIR/run.lock" ]; then { read -r h t < "$DATA_DIR/run.lock"; } 2>/dev/null || true; fi
  [[ "$t" =~ ^[0-9]+$ ]] || t=0
  LOCK_HOST=$h; LOCK_AGE=$(( $(date +%s) - t ))
}
lock_take() {  # lock_take <DB 폴더> — 다른 환경이 쓰는 중이면 멈추고, 아니면 이 환경 이름으로 잠그고 갱신 프로세스를 띄운다
  local pgd=$1 prev old p
  lock_read
  if [ -z "$LOCK_HOST" ]; then prev=none
  elif [ "$LOCK_HOST" = "$HOST_ID" ]; then prev=self
  elif [ "$LOCK_AGE" -lt "$LOCK_STALE" ]; then
    die "다른 환경($LOCK_HOST)이 이 유지 폴더로 실행 중입니다 (${LOCK_AGE}초 전 확인).
  같은 DB 를 두 곳에서 띄우면 DB 가 깨집니다 — 그쪽에서 먼저 bash stop.sh 로 내리세요.
  그 환경이 이미 없어졌다면 ${LOCK_STALE}초 뒤 다시 실행하면 이어받습니다."
  else prev=stale; note "이전 환경($LOCK_HOST)이 ${LOCK_AGE}초 동안 실행 기록을 갱신하지 않아 멈춘 것으로 보고 이어받습니다"; fi
  # 실행 기록 없이 DB 실행 표시만 남은 경우 — 예전 스크립트로 띄운 다른 환경이 아직 돌고 있을 수 있다
  if [ "$prev" = none ] && [ "$pgd" = "$DATA_DIR/pgdata" ] && [ -f "$pgd/postmaster.pid" ] && [ "${FORCE_UNLOCK:-0}" != 1 ]; then
    old=$(head -1 "$pgd/postmaster.pid" 2>/dev/null)
    if [ "$(cat "/proc/$old/comm" 2>/dev/null)" != postgres ]; then
      die "DB 가 다른 환경에서 아직 실행 중일 수 있습니다 — DB 폴더에 실행 표시(postmaster.pid)가 남아 있는데 실행 기록(run.lock)이 없습니다.
  예전 스크립트로 띄운 개발 파드가 있으면 그 파드에서 먼저:  bash stop.sh
  아무 데서도 돌고 있지 않은 게 확실하면:  FORCE_UNLOCK=1 bash start.sh"
    fi
  fi
  printf '%s %s\n' "$HOST_ID" "$(date +%s)" > "$DATA_DIR/run.lock.$$" && mv -f "$DATA_DIR/run.lock.$$" "$DATA_DIR/run.lock"
  p=$(cat "$RUN_DIR/lock.pid" 2>/dev/null) || true
  if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then
    LOCK_F="$DATA_DIR/run.lock" LOCK_H="$HOST_ID" setsid nohup bash -c \
      'while sleep 20; do printf "%s %s\n" "$LOCK_H" "$(date +%s)" > "$LOCK_F.$$" && mv -f "$LOCK_F.$$" "$LOCK_F"; done' \
      >/dev/null 2>&1 < /dev/null &
    echo $! > "$RUN_DIR/lock.pid"
  fi
}
lock_release() {  # stop.sh — 갱신 프로세스를 내리고, 이 환경의 기록이면 지운다
  local p
  p=$(cat "$RUN_DIR/lock.pid" 2>/dev/null) || true
  if [ -n "$p" ]; then kill "$p" 2>/dev/null || true; fi
  rm -f "$RUN_DIR/lock.pid"
  lock_read
  if [ "$LOCK_HOST" = "$HOST_ID" ]; then rm -f "$DATA_DIR/run.lock"; fi
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
  # 영역별 시험 경로(/poc/1~4)가 부를 LLM — 기본은 모의 LLM(결과가 늘 같음), FEATURE_UPSTREAM=llm 이면 사내 LLM
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
  unset KONG_NGINX_HTTP_INCLUDE KONG_NGINX_ADMIN_INCLUDE
  if [ -n "$MANAGER_URL_T" ]; then gui_by_host; fi
  if [ -n "$GUI_PATH" ]; then export KONG_ADMIN_GUI_PATH="$GUI_PATH"; else unset KONG_ADMIN_GUI_PATH; fi
  export KONG_NGINX_WORKER_PROCESSES="$KONG_WORKERS"
  ulimit -n "$(ulimit -Hn)" 2>/dev/null || true                   # 열 수 있는 파일 수를 허용된 최대로 (기본 1024 — 동시 연결 수 상한)
  export KONG_STATUS_LISTEN="0.0.0.0:$STATUS_PORT"                  # 3-3 지표 /metrics
  export KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE="${MAX_BODY_MB:-100}m"  # 1-3 대용량 업로드 상한 (경로별 상한은 설정에서)
  export KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE=8m                  # AI 요청 본문을 메모리에 담을 크기
  if [ -n "${DECK_OTEL_ENDPOINT:-}" ]; then                          # 3-2 분산 추적을 켰을 때만
    export KONG_TRACING_INSTRUMENTATIONS=all KONG_TRACING_SAMPLING_RATE=1.0
  else unset KONG_TRACING_INSTRUMENTATIONS KONG_TRACING_SAMPLING_RATE; fi
  # Kong 로그도 데이터 폴더에 — 파드를 다시 만들어도 남는다
  export KONG_PROXY_ERROR_LOG="$LOGS/kong-error.log" KONG_ADMIN_ERROR_LOG="$LOGS/kong-error.log" KONG_ADMIN_GUI_ERROR_LOG="$LOGS/kong-error.log" KONG_STATUS_ERROR_LOG="$LOGS/kong-error.log"
  export KONG_PROXY_ACCESS_LOG="$LOGS/kong-access.log" KONG_ADMIN_ACCESS_LOG="$LOGS/kong-admin-access.log" KONG_ADMIN_GUI_ACCESS_LOG="$LOGS/kong-manager-access.log"
  [ -f "$RUN_DIR/hosts" ] || kong_hosts || true                     # LLM 주소의 IP 에 붙인 이름 (위 kong_hosts)
  export KONG_DNS_HOSTSFILE="$RUN_DIR/hosts" KONG_RESOLVER_HOSTS_FILE="$RUN_DIR/hosts"
  # vault 참조 {vault://env/...} 가 읽는 값
  export LLM_AUTH_HEADER="${LLM_AUTH_HEADER:-Bearer none}"
  export EMBED_AUTH_HEADER="${EMBED_AUTH_HEADER:-Bearer none}"
  export EXT_AUTH_HEADER="${EXT_AUTH_HEADER:-Bearer none}"
  KONG_LICENSE_DATA="$(license_data)"
  if [ -n "$KONG_LICENSE_DATA" ]; then export KONG_LICENSE_DATA; else unset KONG_LICENSE_DATA; fi
}
# ── 주소가 빌드마다 바뀌는 플랫폼 — Manager 가 요청 주소에서 Admin API 주소를 만든다 ─────────────
# MANAGER_URL=https://manager-{ENV_ID}.도메인 · ADMIN_API_URL=https://adminapi-{ENV_ID}.도메인 처럼 적으면:
#  ① Manager 설정(kconfig.js)의 Admin API 주소를 요청한 호스트(manager-<ID>)에서 만들어 끼운다 (nginx map + sub_filter)
#  ② Admin API 는 manager-<아무 ID>.도메인 에서 온 브라우저 요청만 허용하고 그 출처를 그대로 돌려준다 (CORS — headers-more)
#  주소 속 ID 를 몰라도 되므로 개발 파드·빌드한 새 환경 어디서든 같은 설정으로 Manager 가 동작한다.
gui_by_host() {
  local ms ma mh as aa re_host re_origin admin_val dflt f1="$RUN_DIR/nginx-http-gui.conf" f2="$RUN_DIR/nginx-admin-cors.conf"
  ms=${MANAGER_URL_T%%://*}; ma=${MANAGER_URL_T#*://}; ma=${ma%%/*}; mh=${ma%%:*}   # 방식 · 호스트[:포트] · 호스트
  as=${ADMIN_API_URL_T%%://*}; aa=${ADMIN_API_URL_T#*://}; aa=${aa%%/*}
  re_host=$(printf '%s' "$mh" | sed -e 's/\./\\./g' -e 's/{ENV_ID}/(?<kp_id>[A-Za-z0-9-]+)/')      # 호스트 이름엔 점만 이스케이프하면 된다
  re_origin=$(printf '%s://%s' "$ms" "$ma" | sed -e 's/\./\\./g' -e 's/{ENV_ID}/[A-Za-z0-9-]+/')
  admin_val=${aa//\{ENV_ID\}/\$kp_id}
  dflt=${ADMIN_API_URL#*://}; dflt=${dflt%%/*}       # 틀에 안 맞는 호스트로 열면 — 이 환경의 ID 로 채운 주소
  cat > "$f1" <<CONF
# kong-poc (lib.sh gui_by_host) — 요청한 Manager 주소에서 Admin API 주소를 만든다
map \$host \$kong_poc_admin_api_host {
    "~^${re_host}\$" "${admin_val}";
    default "${dflt}";
}
map \$http_origin \$kong_poc_cors_origin {
    "~^${re_origin}\$" \$http_origin;
    default "";
}
sub_filter '__KONG_POC_ADMIN_API_HOST__' '\$kong_poc_admin_api_host';
sub_filter_once off;
sub_filter_types application/javascript;
CONF
  cat > "$f2" <<'CONF'
# kong-poc (lib.sh gui_by_host) — Manager 주소 틀에 맞는 출처만 허용하고 그대로 돌려준다
more_set_headers -s '200 201 204 400 401 403 404 405 409 500' 'Access-Control-Allow-Origin: $kong_poc_cors_origin';
more_set_headers -s '200 201 204 400 401 403 404 405 409 500' 'Vary: Origin';
CONF
  export KONG_NGINX_HTTP_INCLUDE="$f1" KONG_NGINX_ADMIN_INCLUDE="$f2"
  export KONG_ADMIN_GUI_API_URL="$as://__KONG_POC_ADMIN_API_HOST__"
}
kong_up() { kong health -p "$KONG_PREFIX" >/dev/null 2>&1; }
fix_log_path() {  # Kong 설정 속 요청 로그 위치가 이 환경에 없으면(유지 폴더가 다른 경로로 붙음) 설정을 다시 적용해 맞춘다
  local lp
  lp=$(admin '/plugins?name=file-log' | python3 -c 'import json, sys; d = json.load(sys.stdin).get("data") or []; print(d[0]["config"]["path"] if d else "")' 2>/dev/null) || lp=""
  if [ -z "$lp" ] || [ -d "$(dirname "$lp")" ]; then return 0; fi
  license_state
  case "$LIC_STATE" in
    valid|grace) say "요청 로그 위치($lp)가 이 환경에 없어 설정을 다시 적용합니다 → $LOGS/audit.log"; bash "$ROOT/apply-config.sh" ;;
    *) note "⚠ 요청 로그 위치($lp)가 이 환경에 없는데 라이선스가 없어 설정을 다시 적용하지 못했습니다" ;;
  esac
}
admin() {  # admin <경로> [curl 옵션...] — RBAC 토큰으로 Admin API 호출
  local p=$1; shift
  curl -s -m 10 -H "Kong-Admin-Token: $KONG_ADMIN_PASSWORD" "$@" "http://127.0.0.1:$ADMIN_PORT$p"
}
