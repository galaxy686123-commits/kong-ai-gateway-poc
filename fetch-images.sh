#!/usr/bin/env bash
# fetch-images.sh — GitHub Release 에 올려 둔 이미지 tar 를 images/ 로 내려받는다.
#   ./fetch-images.sh https://github.com/<계정>/<저장소>/releases/download/<태그>
#
# 파드에서 github.com 과 release-assets.githubusercontent.com 에 접속할 수 있어야 한다.
set -euo pipefail
cd "$(dirname "$0")"
base=${1:?"Release 주소를 지정하세요. 예: ./fetch-images.sh https://github.com/acct/repo/releases/download/v1"}
mkdir -p images
for f in kong-kong-gateway-3.15.tar pgvector-pgvector-pg16.tar kong-deck-v1.65.1.tar python-3.12-slim.tar; do
  [ -f "images/$f" ] && { echo "  있음 images/$f"; continue; }
  echo "▶ $f"
  curl -fL --retry 3 -o "images/$f.part" "$base/$f" && mv "images/$f.part" "images/$f"
done
echo "✔ 완료 — 이제 ./start.sh 가 images/ 의 tar 에서 이미지를 불러옵니다."
