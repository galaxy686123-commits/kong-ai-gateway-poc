#!/usr/bin/env bash
# kong-check.sh — docker 가 없는 개발환경 파드에서 Kong·PostgreSQL 을 직접 설치할 수 있는지 점검한다.
#   bash kong-check.sh     (화면 한 장 분량 — 캡처해서 전달)
# 조회만 한다. sudo apt-get update 로 패키지 목록을 받는 것만 예외.
set -u
ok(){ printf '  [ OK ] %s\n' "$*"; }
no(){ printf '  [ X  ] %s\n' "$*"; }
i(){ printf '         %s\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
yn(){ if have "$1"; then printf O; else printf X; fi; }
mask(){ sed -E 's#(://)[^/@[:space:]]+@#\1***@#g'; }
code(){
  if have curl; then
    c=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$1" 2>/dev/null) || true
  else
    c=$(python3 -c '
import sys, urllib.request, urllib.error
try:
    print(urllib.request.urlopen(sys.argv[1], timeout=6).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
' "$1" 2>/dev/null)
  fi
  c=${c: -3}; [[ "$c" =~ ^[0-9]{3}$ ]] || c=000; echo "$c"
}
net(){ c=$(code "$2"); if [ "$c" = 000 ]; then no "$1 - 접속 안 됨"; else ok "$1 - 접속 됨 (HTTP $c)"; fi; }

echo "== 1. OS / 자원 =="
. /etc/os-release 2>/dev/null
i "OS: ${PRETTY_NAME:-?} / $(uname -m) / glibc $(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}') / PID1 $(cat /proc/1/comm 2>/dev/null)"
i "사용자: $(id | cut -c1-110)"
cpu=없음; mem=없음
if [ -f /sys/fs/cgroup/cpu.max ]; then
  read -r q p < /sys/fs/cgroup/cpu.max
  [ "$q" = max ] || cpu=$(awk -v q="$q" -v p="$p" 'BEGIN{printf "%.1f vCPU", q/p}')
  m=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  [ "${m:-max}" = max ] || mem=$(awk -v m="$m" 'BEGIN{printf "%.1f GiB", m/1073741824}')
elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
  q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us); p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
  [ "$q" -gt 0 ] 2>/dev/null && cpu=$(awk -v q="$q" -v p="$p" 'BEGIN{printf "%.1f vCPU", q/p}')
  m=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
  [ "${#m}" -lt 16 ] && mem=$(awk -v m="$m" 'BEGIN{printf "%.1f GiB", m/1073741824}')
fi
i "CPU 한도 $cpu (노드 코어 $(nproc)) / 메모리 한도 $mem / /dev/shm $(df -hP /dev/shm 2>/dev/null | awk 'NR==2{print $2}')"

echo "== 2. 저장 공간 =="
for d in "$PWD" "${HOME:-/}" / /tmp; do
  df -hPT "$d" 2>/dev/null | awk -v d="$d" 'NR==2{printf "         %-24s 여유 %6s / %-6s 마운트 %s (%s)\n", d, $5, $3, $7, $2}'
done | awk '{m=$(NF-1)} seen[m]++==0'
i "마운트된 볼륨: $(awk '{ if ($2 == "/" || $2 ~ "^/(proc|sys|dev|run|etc|var/run)(/|$)") next; if ($3 ~ "^(proc|sysfs|cgroup2?|tmpfs|devpts|mqueue|overlay|autofs|securityfs|debugfs|tracefs|fusectl|configfs|pstore|bpf|hugetlbfs|binfmt_misc|nsfs)$") next; print $2 "(" $3 ")" }' /proc/mounts 2>/dev/null | sort -u | head -n 6 | paste -sd' ' -)"
if sudo -n touch /usr/local/.kong-poc-test 2>/dev/null; then
  sudo -n rm -f /usr/local/.kong-poc-test; ok "루트 파일시스템에 설치 가능 (/usr/local 쓰기 됨)"
else
  no "루트 파일시스템에 쓸 수 없음 - apt 설치 불가"
fi
f=$(mktemp ./.kong-poc-x.XXXXXX 2>/dev/null) && {
  printf 'exit 0\n' > "$f"; chmod +x "$f"
  if "$f" 2>/dev/null; then i "작업 폴더에서 프로그램 실행: 가능"; else i "작업 폴더에서 프로그램 실행: 금지(noexec)"; fi
  rm -f "$f"
}

echo "== 3. 도구 =="
py=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)
i "curl $(yn curl) / wget $(yn wget) / git $(yn git) / tar $(yn tar) / gpg $(yn gpg) / python3 ${py:-X} ($(command -v python3))"
idx=$( { pip3 config list 2>/dev/null; env | grep -E '^PIP_(EXTRA_)?INDEX_URL='; } | grep -iE 'index[-_]url' | sed -E "s/^[^=]*=//; s/^['\"]//; s/['\"]\$//" | mask | paste -sd' ' -)
i "pip 저장소: ${idx:-기본 (pypi.org)}"
if python3 -c 'import jupyter_server_proxy' 2>/dev/null; then
  ok "jupyter-server-proxy 있음 - 브라우저에서 <주피터 주소>/proxy/8002/ 로 Kong Manager 접속 가능"
else
  no "jupyter-server-proxy 없음 - Kong Manager 를 브라우저로 열 방법이 따로 필요"
fi

echo "== 4. 외부 접속 =="
net "GitHub"                     https://github.com
net "GitHub Release 파일"         https://release-assets.githubusercontent.com
net "Kong 패키지 저장소"           https://packages.konghq.com
net "PostgreSQL 공식 apt 저장소"   https://apt.postgresql.org
net "PyPI"                       https://pypi.org/simple/
net "Docker Hub"                 https://registry-1.docker.io/v2/
net "OpenAI API"                 https://api.openai.com/v1/models

echo "== 5. apt 패키지 =="
srcs=$( { grep -hsE '^[[:space:]]*deb[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d/*.list | awk '{for(k=2;k<=NF;k++) if($k ~ /^https?:/){print $k; break}}'; grep -hsE '^[[:space:]]*URIs:' /etc/apt/sources.list.d/*.sources | awk '{print $2}'; } | sed -E 's#^(https?://[^/]+).*#\1#' | awk 'seen[$0]++==0' | mask | paste -sd' ' -)
i "저장소: ${srcs:-없음}"
out=$(timeout 180 sudo -n apt-get update 2>&1); rc=$?
err=$(printf '%s\n' "$out" | grep -E '^(Err|W: Failed|E:)' | head -n 1 | mask | cut -c1-110)
if [ "$rc" = 0 ] && [ -z "$err" ]; then ok "apt-get update 성공"; else no "apt-get update 실패 - ${err:-종료코드 $rc}"; fi
i "postgresql 설치 가능 버전: $(apt-cache policy postgresql 2>/dev/null | awk '/Candidate:/{print $2}')"
i "pgvector 패키지: $(apt-cache search --names-only pgvector 2>/dev/null | awk '{print $1}' | paste -sd' ' -)"
i "build-essential(소스 빌드용): $(apt-cache policy build-essential 2>/dev/null | awk '/Candidate:/{print $2}')"

echo "== 6. 포트 =="
used=$(awk 'NR>1 && $4=="0A"{split($2,a,":"); print a[2]}' /proc/net/tcp /proc/net/tcp6 2>/dev/null | sort -u | while read -r h; do echo $((16#$h)); done | grep -xE '5432|8000|8001|8002|8080' | paste -sd' ' -)
i "Kong / DB 가 쓸 포트(5432 8000 8001 8002 8080) 중 사용 중: ${used:-없음}"
echo "== 끝 - 이 화면을 캡처해서 보내 주세요 =="
