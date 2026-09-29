#!/usr/bin/env bash
# check-env.sh — 개발환경 파드에서 Kong PoC 를 올릴 수 있는지 한 번에 점검한다.
#
#   ./check-env.sh              # 결과 전체를 복사해서 전달해 주세요
#   LLM_URL=http://<주소>/v1/models ./check-env.sh   # LLM 엔드포인트 도달도 함께 확인
#
# 점검만 하며 설정을 바꾸지 않는다. 시험용 컨테이너·이미지는 끝나면 지운다.
set -u

PASS=0; WARN=0; FAIL=0
ok()   { printf '  [ OK ] %s\n' "$*"; PASS=$((PASS+1)); }
warn() { printf '  [주의] %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '  [불가] %s\n' "$*"; FAIL=$((FAIL+1)); }
info() { printf '         %s\n' "$*"; }
sec()  { printf '\n== %s ==\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# HTTP 상태 코드만 받는다. 응답이 오면 "도달 가능"(401·403·404 도 도달한 것).
http_code() {
  if have curl; then
    # 실패해도 curl 이 000 을 찍는다. 뒤에 무엇을 덧붙이지 말고 마지막 세 글자만 쓴다.
    c=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null) || true
    c=${c: -3}; [[ "$c" =~ ^[0-9]{3}$ ]] || c=000; echo "$c"
  elif have wget; then wget -q -T 8 -S --spider "$1" 2>&1 | awk '/HTTP\//{c=$2} END{print c?c:"000"}'
  elif have python3; then python3 - "$1" <<'PY'
import sys, urllib.request, urllib.error
try:
    print(urllib.request.urlopen(sys.argv[1], timeout=8).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print("000")
PY
  else echo "도구없음"; fi
}

sec "1. 기본 정보"
# shellcheck disable=SC1091
[ -r /etc/os-release ] && . /etc/os-release
info "OS     : ${PRETTY_NAME:-알 수 없음}"
info "커널   : $(uname -r)"
info "사용자 : $(id)"
info "호스트 : $(hostname)"

sec "2. 이 파드에 할당된 자원"
cpu=""; mem=""
if [ -f /sys/fs/cgroup/cpu.max ]; then                      # cgroup v2
  read -r q p < /sys/fs/cgroup/cpu.max
  [ "$q" != "max" ] && cpu=$(awk -v q="$q" -v p="$p" 'BEGIN{printf "%.1f", q/p}')
  m=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
  [ "$m" != "max" ] && mem=$m
elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then       # cgroup v1
  q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us); p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
  [ "$q" -gt 0 ] 2>/dev/null && cpu=$(awk -v q="$q" -v p="$p" 'BEGIN{printf "%.1f", q/p}')
  m=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)
  [ "${#m}" -lt 16 ] && mem=$m
fi
if [ -n "$cpu" ]; then
  awk -v c="$cpu" 'BEGIN{exit !(c>=2)}' && ok "CPU 한도 ${cpu} vCPU (필요 2 이상)" || warn "CPU 한도 ${cpu} vCPU — 2 vCPU 이상 권장"
else info "CPU 한도 없음 (노드 코어 $(nproc 2>/dev/null)개를 공유)"; fi
if [ -n "$mem" ]; then
  gib=$(awk -v m="$mem" 'BEGIN{printf "%.1f", m/1073741824}')
  awk -v g="$gib" 'BEGIN{exit !(g>=4)}' && ok "메모리 한도 ${gib} GiB (필요 4 이상)" || warn "메모리 한도 ${gib} GiB — 4 GiB 이상 권장"
else info "메모리 한도 없음"; fi
info "※ 도커 데몬이 별도 컨테이너(사이드카)라면 Kong 은 그쪽 한도를 따릅니다."

sec "3. 컨테이너 실행 환경"
DOCKER_OK=0
if have docker; then
  sv=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
  if [ -n "$sv" ]; then
    ok "도커 데몬 연결됨 (서버 $sv)"; DOCKER_OK=1
    dname=$(docker info --format '{{.Name}}' 2>/dev/null)
    if [ "$dname" = "$(hostname)" ]; then
      ok "도커 데몬이 이 파드 안에 있음 (컨테이너가 파드 자원·수명 안에서 실행됨)"
    else
      warn "도커 데몬 호스트명($dname) ≠ 파드($(hostname)) — 노드의 도커를 빌려 쓰는 구조일 수 있음"
      info "이 경우 컨테이너가 파드 밖에서 실행되며 파드를 지워도 남습니다."
    fi
    docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless \
      && warn "rootless 도커 — 포트·네트워크 제약이 있을 수 있음"
    info "도커 저장 위치: $(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  else
    bad "docker 명령은 있으나 데몬에 연결되지 않음 → 컨테이너 실행 불가"
  fi
  docker compose version >/dev/null 2>&1 && info "docker compose 있음" || info "docker compose 없음 (필요 없음 — 스크립트가 docker 명령만 사용)"
elif have podman; then
  warn "docker 는 없고 podman 만 있음 — docker 호환 여부 추가 확인 필요"
else
  bad "docker·podman 모두 없음 → 컨테이너 실행 불가"
fi

sec "4. 외부 접속"
HUB_OK=0; GHCR_OK=0; REL_OK=0
probe() {  # 이름 URL — 응답이 오면(401·403·404 포함) 접속되는 것
  c=$(http_code "$2")
  case "$c" in 000|도구없음) bad "$1 — 접속 안 됨 ($2)"; return 1;;
               *)          ok  "$1 — 접속 됨 (HTTP $c)";  return 0;; esac
}
probe "GitHub (코드 받기)"                https://github.com
probe "GitHub Release 파일 저장소"         https://release-assets.githubusercontent.com && REL_OK=1
probe "GitHub 컨테이너 레지스트리 (GHCR)"   https://ghcr.io/v2/ && GHCR_OK=1
probe "Docker Hub 레지스트리"              https://registry-1.docker.io/v2/ \
  && probe "Docker Hub 이미지 저장소"        https://production.cloudflare.docker.com && HUB_OK=1
if [ -n "${LLM_URL:-}" ]; then probe "LLM 엔드포인트" "$LLM_URL"; fi

sec "5. 컨테이너 실제 실행 시험"
BIND_OK=0; PORT_OK=0; BUILD_OK=0
if [ "$DOCKER_OK" = 1 ]; then
  # 시험용 초소형 이미지: Docker Hub 가 막혀 있으면 GHCR 의 공개 이미지를 쓴다
  TEST_IMG=""
  for cand in busybox:1.36 ghcr.io/containerd/busybox:1.36; do
    if docker image inspect "$cand" >/dev/null 2>&1 || docker pull -q "$cand" >/dev/null 2>&1; then
      TEST_IMG=$cand; break
    fi
  done
  if [ -n "$TEST_IMG" ]; then
    ok "이미지 받기 성공 ($TEST_IMG)"
  else
    bad "시험용 이미지를 받을 수 없음 (Docker Hub·GHCR 모두 실패)"
  fi
  if [ -n "$TEST_IMG" ]; then
    docker run --rm "$TEST_IMG" true >/dev/null 2>&1 && ok "컨테이너 실행 성공" || bad "컨테이너 실행 실패"

    # 바인드 마운트: 이 파드의 파일이 컨테이너 안에서 보이는가
    probe_dir="$PWD/.kong-poc-probe"; mkdir -p "$probe_dir"; echo visible > "$probe_dir/f"
    if [ "$(docker run --rm -v "$probe_dir:/p:ro" "$TEST_IMG" cat /p/f 2>/dev/null)" = visible ]; then
      ok "바인드 마운트 동작 (파드의 파일을 컨테이너에 연결 가능)"; BIND_OK=1
    else
      warn "바인드 마운트 안 됨 — 설정은 이미지 빌드로 전달합니다 (스크립트가 자동 처리)"
    fi
    rm -rf "$probe_dir"

    # 이미지 빌드: 설정 파일을 담은 작은 이미지를 만든다
    if printf "FROM %s\nRUN echo built > /built\n" "$TEST_IMG" | docker build -q -t kong-poc-probe:build - >/dev/null 2>&1; then
      ok "이미지 빌드 성공"; BUILD_OK=1; docker rmi -f kong-poc-probe:build >/dev/null 2>&1
    else
      bad "이미지 빌드 실패"
    fi

    # 포트 노출: 컨테이너 포트를 이 파드의 localhost 로 부를 수 있는가
    docker rm -f kong-poc-probe-http >/dev/null 2>&1
    if docker run -d --rm --name kong-poc-probe-http -p 18080:80 "$TEST_IMG" httpd -f -p 80 -h / >/dev/null 2>&1; then
      sleep 2
      c=$(http_code http://127.0.0.1:18080/)
      if [ "$c" != 000 ]; then ok "포트 연결 — 파드 localhost:18080 으로 접근됨"; PORT_OK=1
      else warn "포트 연결 — localhost 로 접근 안 됨 (컨테이너가 파드 밖에서 실행되는 구조일 수 있음)"; fi
      docker rm -f kong-poc-probe-http >/dev/null 2>&1
    else
      bad "포트를 연 컨테이너 실행 실패"
    fi
  else
    warn "시험용 이미지가 없어 실행 시험을 건너뜀 — 이미지 반입 후 다시 실행하세요"
  fi
else
  info "도커를 쓸 수 없어 건너뜀"
fi

sec "6. 저장 공간"
df -h "$HOME" "$PWD" 2>/dev/null | awk 'NR==1 || !seen[$0]++' | sed 's/^/         /'
info "마운트된 볼륨(재시작해도 남을 가능성이 있는 곳):"
mount 2>/dev/null | awk '$3 ~ /^\/(home|data|workspace|mnt|opt|root)/ {print "           " $3 "  (" $5 ")"}' | sort -u | head -8
info "※ 어느 경로가 파드 재시작 후에도 남는지 플랫폼 관리자에게 확인해 주세요."

sec "요약"
printf '  OK %d · 주의 %d · 불가 %d\n' "$PASS" "$WARN" "$FAIL"
if [ "$DOCKER_OK" != 1 ]; then
  echo "  → 이 파드에서는 컨테이너를 실행할 수 없습니다. 다른 설치 방식이 필요합니다."
elif [ "$HUB_OK" = 1 ]; then
  echo "  → 이미지 경로 1 (Docker Hub): 파드에서 바로 받습니다.            ./start.sh"
elif [ "$GHCR_OK" = 1 ]; then
  echo "  → 이미지 경로 2 (GHCR): GitHub 레지스트리에 올린 이미지를 받습니다.  README 「이미지 경로」 참조"
elif [ "$REL_OK" = 1 ]; then
  echo "  → 이미지 경로 3 (GitHub Release): 이미지 tar 를 내려받아 불러옵니다.  README 「이미지 경로」 참조"
else
  echo "  → 이미지 경로 4 (물리 반입): 인터넷 PC 에서 ./bundle.sh 로 만든 번들을 반입합니다."
fi
if [ "$DOCKER_OK" = 1 ]; then
  [ "$BUILD_OK" != 1 ] && echo "  ✘ 이미지 빌드가 되지 않아 ./start.sh 가 동작하지 않습니다. 담당자에게 결과를 전달해 주세요."
  [ "$BIND_OK"  != 1 ] && echo "  ※ 바인드 마운트가 안 되지만 설정은 이미지 빌드로 전달하므로 설치에는 지장 없습니다."
  [ "$PORT_OK"  != 1 ] && echo "  ※ 포트 연결이 안 되면 게이트웨이를 파드 밖에서 호출할 수 없습니다."
fi
exit 0
