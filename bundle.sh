#!/usr/bin/env bash
# bundle.sh — (인터넷 되는 PC 에서) 파드에 들여갈 이미지를 준비한다.
#   파드에서 Docker Hub 에 접속할 수 없을 때 필요하다. (./check-env.sh 로 확인)
#
#   ./bundle.sh                         이미지 tar 4개를 images/ 에 저장 + 반입용 번들 생성
#   ./bundle.sh --push ghcr.io/<계정>    이미지를 GHCR 에 올림 (먼저 docker login ghcr.io)
#
# .env · secrets/ 는 어디에도 넣지 않는다.
set -euo pipefail
cd "$(dirname "$0")"
IMAGES=(
  "${KONG_IMAGE:-kong/kong-gateway:3.15}"
  "${PG_IMAGE:-pgvector/pgvector:pg16}"
  "${DECK_IMAGE:-kong/deck:v1.65.1}"
  "${PY_IMAGE:-python:3.12-slim}"
)

if [ "${1:-}" = "--push" ]; then
  dest=${2:?"GHCR 주소를 지정하세요. 예: ./bundle.sh --push ghcr.io/myaccount"}
  echo "▶ GHCR 에 올리기 → $dest"
  for img in "${IMAGES[@]}"; do
    name=${img##*/}                                  # kong-gateway:3.15
    docker pull -q --platform linux/amd64 "$img" >/dev/null
    docker tag "$img" "$dest/$name"
    docker push -q "$dest/$name" >/dev/null
    echo "  ✔ $dest/$name"
  done
  cat <<MSG

파드의 .env 에 아래를 넣으세요:
  KONG_IMAGE=$dest/${IMAGES[0]##*/}
  PG_IMAGE=$dest/${IMAGES[1]##*/}
  DECK_IMAGE=$dest/${IMAGES[2]##*/}
  PY_IMAGE=$dest/${IMAGES[3]##*/}
비공개 패키지라면 파드에서 먼저:  echo <토큰> | docker login ghcr.io -u <계정> --password-stdin
MSG
  exit 0
fi

mkdir -p images
for img in "${IMAGES[@]}"; do
  tar="images/$(echo "$img" | tr '/:' '--').tar"
  echo "▶ $img"
  docker pull -q --platform linux/amd64 "$img" >/dev/null
  docker save -o "$tar" "$img"
  echo "  → $tar ($(du -h "$tar" | cut -f1))"
done

out="kong-poc-bundle-$(date +%Y%m%d).tar.gz"
tar --exclude=.git --exclude=.env --exclude='secrets/*' --exclude=data \
    --exclude='kong-poc-bundle-*.tar.gz' \
    -czf "$out" -C .. "$(basename "$PWD")"
echo
echo "✔ $out ($(du -h "$out" | cut -f1))"
echo "  images/*.tar 4개는 GitHub Release 에 올려도 됩니다 (./fetch-images.sh 로 받음)."
