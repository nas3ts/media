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
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"
# Homepage runs as PUID but needs the docker socket's GID for container status.
DOCKER_GID="${DOCKER_GID:-$(stat -c %g "$DOCKER_SOCK" 2>/dev/null || echo 0)}"
export DOCKER_GID

# ---- Compose arguments (shared by the config generator and the final exec) ----
args=(-f "$BASE")

if [[ -z "${NO_GPU:-}" ]] && [[ -f .env ]] && grep -q '^RENDER_DRI_PRIMARY=' .env; then
  device="$(grep '^RENDER_DRI_PRIMARY=' .env | tail -1 | cut -d= -f2-)"
  if [[ -n "$device" ]] && [[ -e "$device" ]]; then
    args+=(-f "$GPU")
  fi
fi

# ---- Ensure directories exist with correct ownership ----
# Docker auto-creates bind-mount directories as root on first `up`, which breaks
# the apps running as PUID/PGID (default 1000:1000). Create and chown them here
# so qBittorrent (and the other services) can write to their bind mounts.
mkdir -p "$CONFIG_DIR" \
         "$CONFIG_DIR/homepage" \
         "$DATA_DIR" \
         "$DATA_DIR/downloads" \
         "$DATA_DIR/downloads/incomplete" \
         "$DATA_DIR/downloads/movies" \
         "$DATA_DIR/downloads/tv"

# ---- Homepage configuration ----
# docker.yaml and services.custom.yaml are seeded once from tracked templates.
# services.yaml is regenerated on every run from the active Compose services.
HOMEPAGE_TEMPLATE_DIR="$SCRIPT_DIR/config.example/homepage"
for name in docker.yaml services.custom.yaml; do
  template="$HOMEPAGE_TEMPLATE_DIR/$name"
  [[ -f "$template" ]] || continue
  target="$CONFIG_DIR/homepage/$name"
  [[ -e "$target" ]] || cp "$template" "$target"
done

# Metadata for known services: name, group, icon, link, description, widget
# type, widget URL, and the .env key that feeds the widget secret.
homepage_register() {
  local svc="$1" name="$2" group="$3" icon="$4" href="$5" desc="$6" \
        widget="$7" widget_url="$8" widget_key="$9"
  HP_NAME[$svc]="$name"
  HP_GROUP[$svc]="$group"
  HP_ICON[$svc]="$icon"
  HP_HREF[$svc]="$href"
  HP_DESC[$svc]="$desc"
  HP_WIDGET[$svc]="$widget"
  HP_WURL[$svc]="$widget_url"
  HP_WKEY[$svc]="$widget_key"
  HP_GROUPS[$group]=1
}

homepage_emit_service() {
  local svc="$1"
  local name="${HP_NAME[$svc]:-$svc}"
  printf '    - %s:\n' "$name"
  printf '        icon: %s\n' "${HP_ICON[$svc]:-$svc.png}"
  [[ -z "${HP_HREF[$svc]:-}" ]] || printf '        href: %s\n' "${HP_HREF[$svc]}"
  printf '        description: %s\n' "${HP_DESC[$svc]:-$svc}"
  printf '        server: local\n'
  printf '        container: %s\n' "$svc"

  local type="${HP_WIDGET[$svc]:-}"
  [[ -n "$type" ]] || return 0

  local key_name="${HP_WKEY[$svc]:-}"
  if [[ "$type" == qbittorrent && -z "${QBITTORRENT_APIKEY:-}" ]]; then
    printf '        # Set QBITTORRENT_APIKEY in .env to enable this widget. An empty\n'
    printf '        # key causes failed logins and qBittorrent bans Homepage\x27s IP.\n'
    return 0
  fi

  printf '        widget:\n'
  printf '          type: %s\n' "$type"
  printf '          url: %s\n' "${HP_WURL[$svc]:-}"
  if [[ -n "$key_name" ]]; then
    printf '          key: "{{HOMEPAGE_VAR_%s}}"\n' "$key_name"
  fi
}

generate_homepage_services() {
  local output="$CONFIG_DIR/homepage/services.yaml"
  local custom="$CONFIG_DIR/homepage/services.custom.yaml"
  local services tmp group svc first

  if ! services="$(docker compose "${args[@]}" config --services 2>/dev/null)"; then
    echo "warning: could not read active services from Compose; keeping existing $output" >&2
    return 0
  fi

  declare -A HP_NAME HP_GROUP HP_ICON HP_HREF HP_DESC HP_WIDGET HP_WURL HP_WKEY
  declare -A HP_GROUPS HP_GROUP_SERVICES HP_SKIP
  local -a HP_GROUP_ORDER=(Media Downloads Automation System Other)

  # Intentionally not shown on the dashboard yet.
  HP_SKIP=([flaresolverr]=1 [jellyfin]=1)

  homepage_register plex        Plex        Media      plex.png         'http://localhost:32400/web' 'Media server'       plex        'http://host.docker.internal:32400' PLEX_TOKEN
  homepage_register qbittorrent qBittorrent Downloads qbittorrent.png  'http://localhost:8080'     'Torrent client'     qbittorrent 'http://qbittorrent:8080'          QBITTORRENT_APIKEY
  homepage_register sonarr      Sonarr      Automation sonarr.png      'http://localhost:8989'     'TV series management' sonarr      'http://sonarr:8989'                SONARR_APIKEY
  homepage_register radarr      Radarr      Automation radarr.png      'http://localhost:7878'     'Movie management'   radarr      'http://radarr:7878'                RADARR_APIKEY
  homepage_register prowlarr    Prowlarr    Automation prowlarr.png    'http://localhost:9696'     'Indexer management' prowlarr    'http://prowlarr:9696'              PROWLARR_APIKEY
  homepage_register homepage    Homepage    System     homepage.png    'http://localhost:3005'     'Dashboard'          ''          ''                                  ''

  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    [[ -z "${HP_SKIP[$svc]:-}" ]] || continue
    group="${HP_GROUP[$svc]:-Other}"
    HP_GROUP_SERVICES[$group]+="${svc}"$'\n'
  done <<< "$services"

  tmp="$(mktemp "${output}.XXXXXX")"
  {
    printf '%s\n' '---' \
      '# Generated by media.sh from the active Compose services.' \
      '# Do not edit directly; add manual entries to services.custom.yaml.' \
      ''
    for group in "${HP_GROUP_ORDER[@]}"; do
      first=1
      while IFS= read -r svc; do
        [[ -n "$svc" ]] || continue
        if [[ "$first" -eq 1 ]]; then
          printf -- '- %s:\n' "$group"
          first=0
        fi
        homepage_emit_service "$svc"
      done <<< "${HP_GROUP_SERVICES[$group]-}"
      [[ "$first" -eq 1 ]] || printf '\n'
    done
    if [[ -f "$custom" ]]; then
      printf '%s\n' '# Manual entries from services.custom.yaml:' ''
      sed -e '/^---[[:space:]]*$/d' -e '/^\.\.\.[[:space:]]*$/d' "$custom"
    fi
  } > "$tmp"
  mv -f "$tmp" "$output"
}

generate_homepage_services

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

exec docker compose "${args[@]}" "$@"
