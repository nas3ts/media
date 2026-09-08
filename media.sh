#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BASE="compose.yaml"
GPU="compose.gpu.yml"

if [[ ! -f "$BASE" ]]; then
  echo "error: $BASE not found" >&2
  exit 1
fi

args=(-f "$BASE")

if [[ -z "${NO_GPU:-}" ]] && [[ -f .env ]] && grep -q '^RENDER_DRI_PRIMARY=' .env; then
  device="$(grep '^RENDER_DRI_PRIMARY=' .env | tail -1 | cut -d= -f2-)"
  if [[ -n "$device" ]] && [[ -e "$device" ]]; then
    args+=(-f "$GPU")
  fi
fi

exec docker compose "${args[@]}" "$@"