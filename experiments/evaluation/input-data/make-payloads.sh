#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-storage/files}"
mkdir -p "$OUT_DIR"

PHRASE="Artifact for middleware evaluation"
# Default sizes in MB (override with: SIZES="10 60 100")
SIZES=(${SIZES:-1 2 4 6 8 10 20 40 60 100 200 300 400 500})

for s in "${SIZES[@]}"; do
  # newline-free repetition (tight bytes):
  yes "$PHRASE" | tr -d '\n' | head -c $((s * 1024 * 1024)) > "${OUT_DIR}/${s}MB.txt"
  echo "wrote ${OUT_DIR}/${s}MB.txt"
done
