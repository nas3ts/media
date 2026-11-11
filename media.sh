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

# ---- Load environment ----
if [[ -f .env ]]; then
  set -a
  . .env
  set +a
fi

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
CONFIG_DIR="${CONFIG_DIR:-./config}"
DATA_DIR="${DATA_DIR:-./data}"

# ---- Ensure directories exist with correct ownership ----
# Docker auto-creates bind-mount directories as root on first `up`, which breaks
# the apps running as PUID/PGID (default 1000:1000). Create and chown them here
# so qBittorrent (and the other services) can write to their bind mounts.
mkdir -p "$CONFIG_DIR" \
         "$DATA_DIR" \
         "$DATA_DIR/downloads" \
         "$DATA_DIR/downloads/incomplete" \
         "$DATA_DIR/downloads/movies" \
         "$DATA_DIR/downloads/tv"

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R "${PUID}:${PGID}" "$CONFIG_DIR" "$DATA_DIR"
elif command -v sudo >/dev/null 2>&1; then
  sudo chown -R "${PUID}:${PGID}" "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null || {
    echo "warning: could not chown $CONFIG_DIR $DATA_DIR to ${PUID}:${PGID}" >&2
    echo "         fix ownership manually or re-run with sudo" >&2
  }
else
  chown -R "${PUID}:${PGID}" "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null || {
    echo "warning: could not chown $CONFIG_DIR $DATA_DIR to ${PUID}:${PGID}" >&2
  }
fi

args=(-f "$BASE")

if [[ -z "${NO_GPU:-}" ]] && [[ -f .env ]] && grep -q '^RENDER_DRI_PRIMARY=' .env; then
  device="$(grep '^RENDER_DRI_PRIMARY=' .env | tail -1 | cut -d= -f2-)"
  if [[ -n "$device" ]] && [[ -e "$device" ]]; then
    args+=(-f "$GPU")
  fi
fi

exec docker compose "${args[@]}" "$@"
