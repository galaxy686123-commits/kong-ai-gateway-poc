#!/usr/bin/env bash
# native/install.sh — docker 없이 이 파드에 PostgreSQL·pgvector·Kong·decK 를 설치한다.
#   여러 번 실행해도 안전하다 (있는 것은 건너뜀).
#   파드를 다시 만들면 apt 로 깐 프로그램이 사라지는데, native/start.sh 가 알아서 이것을 다시 부른다.
source "$(dirname "$0")/lib.sh"
load_env; native_env

sudo -n true 2>/dev/null || die "sudo 를 비밀번호 없이 쓸 수 있어야 합니다 (apt 설치에 필요)."
APT=(sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Use-Pty=0)
LOG="$LOGS/install.log"; echo "== $(date '+%F %T') install.sh" >> "$LOG"
run() {  # 출력은 install.log 에 남기고, 실패하면 끝부분을 보여 주고 멈춘다
  "$@" >> "$LOG" 2>&1 || { tail -15 "$LOG" | sed 's/^/  | /'; die "실패: $*  (전체 로그 $LOG)"; }
}

# 설치 파일 저장소 확인 (Kong 은 Kong 패키지 저장소가 막혀 있어 GitHub 비공개 저장소로 받는다)
[ -f "$PKGS_DIR/$KONG_DEB" ] || die "Kong 설치 파일이 없습니다: $PKGS_DIR/$KONG_DEB
  설치 파일 저장소를 이 폴더 옆에 clone 하세요 (README 「직접 설치」 참조)."
if [ -f "$PKGS_DIR/SHA256SUMS" ]; then
  (cd "$PKGS_DIR" && sha256sum -c --quiet SHA256SUMS) || die "설치 파일이 손상되었습니다. 저장소를 다시 받으세요."
fi

apt_ready=0
apt_update() {  # 막힌 저장소(nodesource 등)가 섞여 있어도 Ubuntu 기본 저장소만 되면 된다
  [ "$apt_ready" = 1 ] && return 0
  "${APT[@]}" update >> "$LOG" 2>&1 || true
  grep -q 'Candidate: [0-9]' <<<"$(apt-cache policy "postgresql-$PG_VER" 2>/dev/null)" \
    || die "apt 로 PostgreSQL 을 찾을 수 없습니다. 'sudo apt-get update' 결과를 확인하세요."
  apt_ready=1
}

say "1/4 PostgreSQL $PG_VER"
if [ -x "$PG_BIN/postgres" ]; then note "설치돼 있음"
else
  apt_update
  # 기본 클러스터(5432)를 자동으로 만들지 않게 한다 — 데이터는 DATA_DIR 에 따로 만든다
  run "${APT[@]}" install postgresql-common
  run sudo sed -i 's/^#\?[[:space:]]*create_main_cluster.*/create_main_cluster = false/' /etc/postgresql-common/createcluster.conf
  run "${APT[@]}" install "postgresql-$PG_VER"
  note "설치 완료 ($("$PG_BIN/postgres" --version))"
fi

say "2/4 pgvector $PGVECTOR_TAG (시맨틱 캐시용)"
DIST="$DATA_DIR/pgvector-$PGVECTOR_TAG-pg$PG_VER"   # 빌드 결과를 남겨 두면 다음부터는 복사만 한다
if [ -f "/usr/share/postgresql/$PG_VER/extension/vector.control" ]; then note "설치돼 있음"
else
  if [ ! -f "$DIST/usr/share/postgresql/$PG_VER/extension/vector.control" ]; then
    apt_update
    run "${APT[@]}" install "postgresql-server-dev-$PG_VER" build-essential
    src="$DATA_DIR/src/pgvector"
    [ -d "$src/.git" ] || run git clone -q --depth 1 --branch "$PGVECTOR_TAG" https://github.com/pgvector/pgvector.git "$src"
    # OPTFLAGS=""  : 파드가 다른 CPU 의 노드로 옮겨가도 동작하도록 CPU 전용 최적화를 끈다
    # with_llvm=no : JIT 용 비트코드(clang 필요)는 만들지 않는다
    mk=(make -s -C "$src" OPTFLAGS="" with_llvm=no PG_CONFIG="$PG_BIN/pg_config")
    run "${mk[@]}"
    run "${mk[@]}" install DESTDIR="$DIST"
    note "빌드 완료 → $DIST"
  fi
  run sudo cp -R "$DIST/." /
  note "설치 완료"
fi

say "3/4 Kong Gateway $KONG_VER"
if [ "$(kong version 2>/dev/null | awk '{print $NF}')" = "$KONG_VER" ]; then note "설치돼 있음"
else
  apt_update
  run "${APT[@]}" install "$PKGS_DIR/$KONG_DEB"     # 의존 패키지는 apt 가 함께 받는다
  note "설치 완료 ($(kong version))"
fi

say "4/4 decK $DECK_VER (설정 적용 도구)"
if have deck && grep -q "$DECK_VER" <<<"$(deck version 2>/dev/null)"; then note "설치돼 있음"
else
  run tar -xzf "$PKGS_DIR/$DECK_TGZ" -C "$RUN_DIR" deck
  run sudo install -m 0755 "$RUN_DIR/deck" /usr/local/bin/deck && rm -f "$RUN_DIR/deck"
  note "설치 완료 ($(deck version))"
fi
