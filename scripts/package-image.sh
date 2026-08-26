#!/usr/bin/env bash
# Build nemohermes:local and pack it for offline transfer.
#
# Usage (from repo root):
#   ./scripts/package-image.sh
#
# Output:
#   release/nemohermes-local.tar
#   release/docker-compose.yml   (already present; image-only, no build)
#   release/.env.example         (copied from the repo root)
#
# On the other machine:
#   docker load -i nemohermes-local.tar
#   cp .env.example .env && edit it
#   docker compose up -d
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/release"
TAR="${OUT}/nemohermes-local.tar"

mkdir -p "$OUT"
cd "$ROOT"

echo "[package] building nemohermes:local ..."
docker compose -f docker-compose.yml build

echo "[package] saving ${TAR} ..."
docker save -o "$TAR" nemohermes:local

# The target configures the image through .env, so ship the template with it.
cp "${ROOT}/.env.example" "${OUT}/.env.example"

ls -lh "$TAR"
echo
echo "[package] done. Send this folder:"
echo "  ${OUT}/"
echo "    nemohermes-local.tar"
echo "    docker-compose.yml"
echo "    .env.example"
echo
echo "Target machine:"
echo "  docker load -i nemohermes-local.tar"
echo "  cp .env.example .env    # set INFERENCE_API_KEY"
echo "  docker compose up -d"
echo
echo "Note: the image holds no secrets; the key lives in .env on the target."
echo "Note: sandbox images are pulled by the inner dockerd on first up; they are"
echo "      not in this tar and need not be pre-loaded on the host."
