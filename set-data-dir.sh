#!/usr/bin/env bash
# set-data-dir.sh — 파드를 다시 만들어도 남아야 하는 파일을 유지 폴더(쿠버네티스의 PV 같은 곳)에 둔다.
#   bash set-data-dir.sh <유지 폴더>           예) bash set-data-dir.sh /datasets/DT0000000000/data
#   bash set-data-dir.sh --check <유지 폴더>   옮기지 않고 위치·적합성만 확인
#
#   주피터 탐색기에 보이는 경로(/datasets/…)를 그대로 줘도 된다 — 주피터 최상위 폴더·/project·홈 아래에서 실제 위치를 찾는다.
#   <유지 폴더>/kong-poc/ 에 설정(settings.env)·라이선스(secrets/)·DB(Kong 설정·관리 감사로그·벡터 DB)·요청 로그·
#   Kong 로그·pgvector 빌드 결과·설정 백업·점검 기록을 둔다. 저장소의 .env 에는 그 위치(DATA_DIR) 한 줄만 남는다
#   → 빌드해서 저장소 폴더가 스냅샷(읽기 전용)이 돼도 설정을 바꾸고 라이선스를 갈 수 있다.
#   파드를 다시 만들어 저장소를 새로 받았으면 같은 명령을 한 번 더 — 유지 폴더의 설정·DB 로 다시 설치·기동한다.
#   여러 번 실행해도 안전하다. 옮기기 전 자리는 지우지 않고 이름만 바꿔 둔다 (<원래 이름>.moved-<시각>).
set -euo pipefail
ORIG_PWD=$PWD
cd "$(dirname "$0")"
source ./lib.sh     # 함수만 읽는다 (say·note·die·env_full·env_get·env_set·write_pointer·lock_read …)
now=$(date +%Y%m%d-%H%M%S)

CHECK=0; if [ "${1:-}" = --check ]; then CHECK=1; shift; fi
[ $# -eq 1 ] || die "유지 폴더를 지정하세요.  예) bash set-data-dir.sh /datasets/DT0000000000/data   (옮기지 않고 확인만: --check)"

# 실제 위치 찾기 — 주피터 탐색기의 경로는 주피터 최상위 폴더 기준이라 파드 안의 절대 경로와 다를 수 있다
find_dir() {  # find_dir <경로> [noscan]
  local w=$1 rel=${1#/} c p roots=()
  if [[ "$w" = /* ]]; then [ -d "$w" ] && { (cd "$w" && pwd); return 0; }
  elif [ -d "$ORIG_PWD/$w" ]; then (cd "$ORIG_PWD/$w" && pwd); return 0; fi
  for p in $(pgrep -u "$(id -u)" -f jupyter 2>/dev/null); do    # 주피터가 띄워진 폴더 = 탐색기의 최상위
    c=$(ps -o args= -p "$p" 2>/dev/null | grep -oE -- '--(ServerApp\.root_dir|NotebookApp\.notebook_dir|notebook-dir)[= ][^ ]+' | head -1 | sed -E 's/^--[^= ]+[= ]//') || true
    [ -n "$c" ] && roots+=("$c")
    c=$(readlink "/proc/$p/cwd" 2>/dev/null) && roots+=("$c")
  done
  roots+=("$ORIG_PWD" /project "$HOME" /mnt /data /workspace)
  for c in "${roots[@]}"; do [ -d "$c/$rel" ] && { (cd "$c/$rel" && pwd); return 0; }; done
  [ "${2:-}" = noscan ] && return 1
  c=$(timeout 60 find / -maxdepth 6 -type d -path "*/$rel" -not -path '/proc/*' -not -path '/sys/*' 2>/dev/null | head -1) || true
  [ -n "$c" ] && { echo "$c"; return 0; }
  return 1
}
want=${1%/}
if ! base=$(find_dir "$want"); then
  # 이름을 잘못 쳤을 때가 많다 — 있는 상위 폴더까지 거슬러 올라가 그 안의 실제 이름을 보여 준다
  hint=""; p=${want%/*}
  while [ -n "$p" ] && [ "$p" != "$want" ]; do
    if pb=$(find_dir "$p" noscan); then
      names=$(find "$pb" -mindepth 1 -maxdepth 1 -type d -printf '%f  ' 2>/dev/null | head -c 300)
      hint="
  가장 가까운 폴더 $pb 안에 있는 것: ${names:-(비어 있음)}— 이름(글자)을 확인하세요"
      break
    fi
    [ "$p" = "${p%/*}" ] && break
    p=${p%/*}
  done
  die "폴더를 찾을 수 없습니다: $want$hint
  파드 안의 실제 위치 확인:  df -h | grep -i datasets"
fi
[ "$base" = "$want" ] || note "찾은 위치: $base"

fstype=$(df -PT "$base" 2>/dev/null | awk 'NR==2 {print $2}')
avail=$(df -Ph "$base" 2>/dev/null | awk 'NR==2 {print $4}')
case "$fstype" in
  overlay|tmpfs) die "$base 는 파드를 다시 만들면 사라지는 곳입니다 ($fstype) — PV 로 연결된 폴더를 지정하세요" ;;
  fuse*|*s3*|cifs|smb*|9p)
    die "$base ($fstype) 에는 DB 를 두면 위험합니다 — 오브젝트 스토리지·네트워크 공유는 DB 가 필요한 파일 잠금·동기화를 보장하지 않습니다. 아무것도 옮기지 않았습니다. 이 화면을 담당자에게 보내 주세요" ;;
esac
# DB(PostgreSQL)는 소유자가 자신이고 권한이 700 인 폴더에서만 뜬다 — 옮기기 전에 시험 폴더로 확인한다
t="$base/.kong-poc-check-$$"
if ! { mkdir "$t" && chmod 700 "$t" && echo ok > "$t/f"; } 2>/dev/null \
   || [ "$(stat -c '%u %a' "$t" 2>/dev/null)" != "$(id -u) 700" ]; then
  rm -rf "$t" 2>/dev/null || true
  die "이 폴더에는 DB 를 둘 수 없습니다 (쓰기 권한 또는 소유자·권한 700 지정 불가 · $fstype) — 아무것도 옮기지 않았습니다. 이 화면을 담당자에게 보내 주세요"
fi
rm -rf "$t"
T="$base/kong-poc"
mnt=$(df -P "$base" 2>/dev/null | awk 'NR==2 {print $6}')
if [ "$CHECK" = 1 ]; then
  note "확인 완료 — $base ($fstype · 마운트 $mnt · $avail 남음): DB·로그를 둘 수 있습니다$([ -d "$T/pgdata" ] && echo " · 이미 kong-poc/ 에 DB 있음")"
  # 지금 데이터 폴더와 같은 저장소인지 — 다른 마운트(PV)면 파드를 다시 만들어도 남는 곳이 따로 있다는 뜻
  cur=$(grep -s '^DATA_DIR=' .env | tail -1 | cut -d= -f2-); cur=${cur:-$PWD/data}
  cmnt=$(df -P "$cur" 2>/dev/null | awk 'NR==2 {print $6}')
  note "지금 데이터 폴더 $cur — 마운트 ${cmnt:-?}$([ -n "$cmnt" ] && { [ "$cmnt" = "$mnt" ] && echo ' (같은 저장소)' || echo ' (다른 저장소)'; })"
  note "옮기려면:  bash set-data-dir.sh $want"
  exit 0
fi

say "1/4 유지 폴더 — $T"
mkdir -p "$T" && chmod 700 "$T" 2>/dev/null || true
note "쓰기·권한 확인 — $fstype · 마운트 $mnt · $avail 남음"

say "2/4 설정 (settings.env · 라이선스)"
# 설정의 원본은 유지 폴더의 settings.env — 저장소 .env 에는 위치만 둔다 (빌드하면 저장소 폴더는 읽기 전용)
S="$T/settings.env"
if [ ! -f "$S" ] && [ -f "$T/.env" ]; then mv -f "$T/.env" "$S"; fi        # 이전 방식의 사본은 이름만 바꾼다
cur=$(env_get DATA_DIR .env); cur=${cur%/}
# 어느 설정을 쓸지 — T: 유지 폴더의 것(그 DB 와 짝) · REPO: 저장소 .env 의 내용 · CUR: 지금 유지 폴더의 것을 함께 옮김
if [ -f "$S" ]; then
  if [ ! -f .env ] || ! env_full .env || cmp -s .env "$S"; then use=T; note "설정 — 유지 폴더의 것을 씀 ($S)"
  elif [ "$cur" = "$T" ]; then use=REPO; note "설정 — 이 유지 폴더를 쓰는 중에 저장소 .env 를 고쳤음 → 그 내용으로 갱신"
  else
    # 유지 폴더에 이전 설치가 있다 — 그 DB 와 짝이 맞는 설정(비밀번호·토큰)을 쓰고, 저장소 쪽 내용은 유지 폴더에 보관
    use=T; (umask 077; cp .env "$T/settings.env.from-repo-$now")
    note "설정 — 유지 폴더에 이전 설치의 설정이 있어 그것을 씀 (저장소 .env 내용은 $T/settings.env.from-repo-$now 에 보관)"
  fi
elif [ -f .env ] && env_full .env; then use=REPO; note "설정 — 저장소 .env 를 유지 폴더로 옮김"
elif [ -n "$cur" ] && [ -f "$cur/settings.env" ]; then use=CUR; note "설정 — 지금 유지 폴더($cur)의 것을 함께 옮김"
else die "설정이 없습니다 — cp .env.example .env 후 값을 채우고 다시 실행하세요 (README 「처음 설치」)"; fi
REPO_COPY=""
trap 'rm -f "$REPO_COPY"' EXIT
if [ "$use" = REPO ]; then REPO_COPY=$(mktemp); cp .env "$REPO_COPY"; fi    # 아래 load_env 가 .env 를 위치 한 줄로 바꿔도 내용은 남게
if [ "$use" = T ] && [ "$cur" != "$T" ]; then
  # 유지 폴더의 설정으로 바꾼다 — 지금 떠 있는 서비스는 지금 설정으로 먼저 내린다
  if [ -f .env ] && (load_env && native_env && { pg_ready || kong_up || pii_running || mock_running; }) >/dev/null 2>&1; then
    note "서비스를 잠시 내립니다 (설정을 바꾸기 전)"; bash ./stop.sh >/dev/null || true
  fi
  write_pointer "$T" || die "저장소 .env 에 쓸 수 없습니다 — 저장소 폴더가 읽기 전용(빌드 스냅샷)이면 개발 파드에서 실행하세요"
fi

load_env; native_env
OLD=$DATA_DIR
case "$T/" in "$OLD/"?*) die "유지 폴더가 지금 데이터 폴더($OLD) 안에 있습니다 — 다른 곳을 지정하세요" ;; esac
# 다른 환경(빌드한 새 환경 등)이 지금 데이터 폴더로 돌고 있으면 옮길 수 없다
lock_read
if [ -n "$LOCK_HOST" ] && [ "$LOCK_HOST" != "$HOST_ID" ] && [ "$LOCK_AGE" -lt "$LOCK_STALE" ]; then
  die "다른 환경($LOCK_HOST)이 지금 데이터 폴더($OLD)로 실행 중이라 옮길 수 없습니다 — 그쪽을 먼저 내리세요"
fi

say "3/4 DB·로그 옮기기"
if [ "$OLD" = "$T" ]; then
  note "이미 유지 폴더를 쓰는 중"
else
  if pg_ready || kong_up || pii_running || mock_running; then
    note "서비스를 잠시 내립니다 (DB 를 쓰는 중에는 옮길 수 없음)"; bash ./stop.sh >/dev/null
  fi
  if [ -f "$T/pgdata/PG_VERSION" ]; then
    note "유지 폴더에 이미 DB 가 있어 그것을 씁니다 — 원래 자리($OLD)는 건드리지 않음"
  else
    # 옮길 것: 원래 데이터 폴더 전체(DB·로그·빌드 결과) + 로컬 디스크로 대체돼 있던 DB + 예전 설정 백업
    if [ -d "$OLD" ] && [ -n "$(ls -A "$OLD" 2>/dev/null)" ]; then
      cp -a "$OLD/." "$T/"; mv "$OLD" "$OLD.moved-$now"
      note "옮김: $OLD → $T  (원래 자리는 $OLD.moved-$now 로 남겨 둠 — 확인 후 지워도 됨)"
    fi
    if [ ! -f "$T/pgdata/PG_VERSION" ] && [ -f "$RUN_DIR/pgdata/PG_VERSION" ]; then
      cp -a "$RUN_DIR/pgdata" "$T/pgdata"; mv "$RUN_DIR/pgdata" "$RUN_DIR/pgdata.moved-$now"
      note "옮김: 로컬 디스크의 DB → $T/pgdata"
    fi
    [ -f "$T/pgdata/PG_VERSION" ] || note "옮길 DB 없음 — 처음 기동할 때 유지 폴더에 새로 만듭니다"
  fi
  if [ -d conf/backup ] && [ -n "$(ls -A conf/backup 2>/dev/null)" ]; then
    mkdir -p "$T/backup"; cp -a conf/backup/. "$T/backup/"; mv conf/backup "conf/backup.moved-$now"
    note "옮김: 설정 백업 conf/backup → $T/backup"
  fi
fi
# 설정 파일을 유지 폴더에 두고, 저장소 .env 는 위치 한 줄짜리로
if [ "$use" = REPO ]; then
  if [ -f "$S" ] && ! cmp -s "$REPO_COPY" "$S"; then cp -p "$S" "$S.before-$now"; fi
  (umask 077; cp "$REPO_COPY" "$S.tmp") && mv -f "$S.tmp" "$S"
elif [ "$use" = CUR ] && [ ! -f "$S" ]; then (umask 077; cp "$cur/settings.env" "$S"); fi
[ -f "$S" ] || die "유지 폴더에 설정 파일이 없습니다 ($S)"
env_set DATA_DIR "$T" "$S"
write_pointer "$T" || die "저장소 .env 에 쓸 수 없습니다 — 저장소 폴더가 읽기 전용(빌드 스냅샷)이면 개발 파드에서 실행하세요"
note "설정 파일 $S  (저장소 .env 에는 위치만 · 값 바꾸기: bash set-env.sh)"
license_to_data "$T"
if [ -f "$T/secrets/license.json" ]; then note "라이선스 $T/secrets/license.json"
else note "라이선스 없음 — 받으면 bash set-license.sh <파일>"; fi
load_env; native_env      # 바뀐 위치(설정 파일·라이선스)로 다시 읽는다

say "4/4 기동 · 설정 적용"
bash ./start.sh | sed '/^──/,$d'       # 끝의 안내 상자는 아래에 따로 보여 준다
license_state
case "$LIC_STATE" in
  # 요청 로그 파일 위치가 Kong 설정에 들어 있으므로 옮긴 뒤에는 설정을 다시 적용한다
  valid|grace) bash ./apply-config.sh | sed -n '/^▶ 적용$/,$p' ;;
  *) note "라이선스가 없어 설정 적용은 건너뜀 — 라이선스를 넣은 뒤 bash apply-config.sh" ;;
esac

cat <<MSG

──────────────────────────────────────────────
 유지 폴더  $T
   pgdata/    DB — Kong 설정 · 관리 감사로그 · 벡터 DB
   logs/      요청 로그(audit.log) · Kong · PostgreSQL 로그
   backup/    설정 백업 (bash dump-config.sh)
   reports/   점검 기록 (bash verify.sh 를 돌릴 때마다)
   prometheus/  지표 기록 사본 — 다시 빌드한 새 환경이 되살려 Grafana 그래프가 이어짐 (15일 · 2GB 까지)
   settings.env · secrets/license.json   설정·라이선스 원본 (bash set-env.sh · bash set-license.sh)
 파드를 다시 만들었으면: 저장소를 받고 → bash set-data-dir.sh $1
 다음: bash verify.sh
──────────────────────────────────────────────
MSG
