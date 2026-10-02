#!/usr/bin/env bash
# set-env.sh — 설정 값 하나를 바꾼다. 설정 파일이 어디 있든(저장소 .env · 유지 폴더 settings.env) 알아서 찾는다.
#   bash set-env.sh                    설정 파일 위치
#   bash set-env.sh <키> <값>          예) bash set-env.sh FEATURE_SEMANTIC_CACHE on
#   bash set-env.sh <키>               값을 묻는다 — 화면에 안 보임 (비밀번호·API 키)
#   bash set-env.sh --get <키>         값만 출력 (명령에 넣어 쓸 때:  KEY=$(bash set-env.sh --get DECK_CLIENT_KEY))
#   반영: Kong 설정 값은 bash apply-config.sh · 접속 주소·포트·LLM 주소는 bash stop.sh && bash start.sh
#         (빌드한 새 환경이 돌고 있으면 bash remote.sh apply · bash remote.sh restart)
source "$(dirname "$0")/lib.sh"
load_env --no-check

if [ $# -eq 0 ]; then note "설정 파일: $ENV_FILE"; exit 0; fi
if [ "$1" = --get ]; then
  [ $# -eq 2 ] || die "사용법: bash set-env.sh --get <키>"
  printf '%s\n' "$(env_get "$2" "$ENV_FILE")"; exit 0
fi
k=$1; shift
[[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "키 이름이 올바르지 않습니다: $k"
[ "$k" != DATA_DIR ] || die "유지 폴더 위치는 bash set-data-dir.sh 로 바꿉니다"
if [ $# -gt 0 ]; then v="$*"; else read -rsp "$k 값 (화면에 안 보임): " v; echo; fi
case "$v" in *$'\n'*) die "값에 줄바꿈을 넣을 수 없습니다" ;; esac
if [[ "$v" =~ [[:space:]]# ]]; then note "⚠ 값 안의 ' #' 뒤는 주석으로 읽혀 그 앞까지만 값이 됩니다"; fi

env_set "$k" "$v" "$ENV_FILE" || die "설정 파일에 쓰지 못했습니다: $ENV_FILE"
case "$k" in *PASSWORD*|*SECRET*|*KEY*|*AUTH*|*TOKEN*) shown="(${#v}자 — 화면에 안 보임)" ;; *) shown=$v ;; esac
note "$k = $shown  → $ENV_FILE"
note "반영: Kong 설정 값이면 bash apply-config.sh · 접속 주소·포트·LLM 주소면 bash stop.sh && bash start.sh"
note "      (빌드한 새 환경이 돌고 있으면 bash remote.sh apply · bash remote.sh restart)"
