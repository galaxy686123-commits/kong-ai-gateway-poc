#!/usr/bin/env bash
# set-data-dir.sh — 파드를 다시 만들어도 남아야 하는 파일을 유지 폴더(쿠버네티스의 PV 같은 곳)에 둔다.
#   bash set-data-dir.sh <유지 폴더>           예) bash set-data-dir.sh /datasets/DT0000000000/data
#   bash set-data-dir.sh --check <유지 폴더>   옮기지 않고 위치·적합성만 확인
#
#   주피터 탐색기에 보이는 경로(/datasets/…)를 그대로 줘도 된다 — 주피터 최상위 폴더·/project·홈 아래에서 실제 위치를 찾는다.
#   <유지 폴더>/kong-poc/ 에 DB(Kong 설정·관리 감사로그·벡터 DB)·요청 로그·Kong 로그·pgvector 빌드 결과·
#   설정 백업·점검 기록을 둔다 (.env 의 DATA_DIR). .env·라이선스는 저장소에서 그대로 고쳐 쓰고,
#   스크립트를 돌릴 때마다 유지 폴더에 사본이 남는다.
#   파드를 다시 만들어 저장소를 새로 받았으면 같은 명령을 한 번 더 — 사본에서 .env·라이선스를 되살리고 기동한다.
#   여러 번 실행해도 안전하다. 옮기기 전 자리는 지우지 않고 이름만 바꿔 둔다 (<원래 이름>.moved-<시각>).
set -euo pipefail
ORIG_PWD=$PWD
cd "$(dirname "$0")"
say()  { printf '\n▶ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\n✘ %s\n' "$*" >&2; exit 1; }
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

say "2/4 설정 (.env · 라이선스)"
if [ -f "$T/.env" ]; then
  if [ ! -f .env ]; then
    cp "$T/.env" .env; chmod 600 .env; note ".env — 유지 폴더의 사본으로 되살림"
  elif cmp -s .env "$T/.env"; then note ".env — 유지 폴더 사본과 같음"
  elif grep -qxF "DATA_DIR=$T" .env; then note ".env — 저장소의 것을 그대로 씀 (유지 폴더 사본은 곧 갱신)"
  else
    # 유지 폴더에 이전 설치가 있다 — 그 DB 와 짝이 맞는 설정(비밀번호·토큰)으로 되살린다
    mv .env ".env.before-$now"; cp "$T/.env" .env; chmod 600 .env
    note ".env — 유지 폴더에 이전 설치의 설정이 있어 그것으로 되살림 (지금 있던 .env 는 .env.before-$now 로 보관)"
  fi
elif [ ! -f .env ]; then
  die ".env 가 없습니다 — cp .env.example .env 후 값을 채우고 다시 실행하세요 (README 「처음 설치」)"
else note ".env — 저장소의 것을 씀 (유지 폴더에 사본을 둠)"; fi
if [ ! -f secrets/license.json ] && [ -f "$T/secrets/license.json" ]; then
  mkdir -p secrets; cp "$T/secrets/license.json" secrets/license.json; note "라이선스 — 유지 폴더의 사본으로 되살림"
fi

source ./lib.sh
load_env; native_env
OLD=$DATA_DIR
case "$T/" in "$OLD/"?*) die "유지 폴더가 지금 데이터 폴더($OLD) 안에 있습니다 — 다른 곳을 지정하세요" ;; esac

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
  if grep -q '^DATA_DIR=' .env; then sed -i "s|^DATA_DIR=.*|DATA_DIR=$T|" .env
  else printf '\nDATA_DIR=%s\n' "$T" >> .env; fi
  note ".env 의 DATA_DIR=$T"
fi

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
   .env · secrets/license.json   설정·라이선스 사본 (스크립트를 돌릴 때마다 갱신)
 파드를 다시 만들었으면: 저장소를 받고 → bash set-data-dir.sh $1
 다음: bash verify.sh
──────────────────────────────────────────────
MSG
