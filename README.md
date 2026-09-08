# Media Server

Dockerized media stack managed under the PARA system (`~/Areas/Media`). Modular
Compose setup: one file per service in `services/`, included by the root
`compose.yaml`.

## Layout

```
~/Areas/Media/
├── .env                  # shared vars: PUID/PGID/TZ/paths/DNS
├── compose.yaml          # root — includes services/*.yml + defines network
├── compose.gpu.yml       # optional GPU override (device paths, render group)
├── media.sh              # docker compose wrapper (auto-adds GPU override)
├── services/             # one modular compose fragment per service
├── config/               # persistent app state (jellyfin, plex, *arr, qbt)
└── data/                 # single bind mount → /data inside containers
    ├── torrents/
    │   ├── incomplete/
    │   └── complete/{movies,tv,music}/   # category targets for *arr import
    ├── movies/           # Radarr library (hardlinked imports)
    ├── tv/              # Sonarr library
    └── music/           # Lidarr library
```

All containers share one bridge network `media` and address each other by name
(`http://qbittorrent:8080`, `http://flaresolverr:8191`, ...).

## Fresh clone setup

`config/`, `data/`, and `.env` are git-ignored (they hold runtime state and
credentials), so a fresh clone starts without them. Docker will auto-create the
bind-mount directories on first `up`, but as **root** — which breaks the apps
running as `PUID`/`PGID` (default 1000). Create and own the dirs yourself first:

```bash
cp .env.example .env              # then edit values if needed
mkdir -p config data
sudo chown -R <PUID>:<PGID> config data   # e.g. 1000:1000
```

Once `.env` exists and the dirs are owned correctly, the stack is fully
reproducible from a clone.

## Usage

`media.sh` wraps `docker compose`. It automatically adds the GPU override
(`compose.gpu.yml`) when the render device from `.env` exists — so the same
command works on GPU and GPU-less hosts:

```bash
cd ~/Areas/Media
./media.sh up -d              # everything
./media.sh up -d qbittorrent  # just one service
./media.sh ps                 # status
./media.sh logs -f <service>  # logs
./media.sh down               # stop (state persists in config/ and data/)
```

Without a GPU, Plex starts in software-transcode mode; set `NO_GPU=1` to force
that even when a render device exists. The underlying command is
`docker compose -f compose.yaml [-f compose.gpu.yml] <args>`, so you can also
run `docker compose` directly on either host type.

## Ports

| Service      | URL                        | Port  |
|--------------|----------------------------|-------|
| Jellyfin     | http://localhost:8096      | 8096  |
| Plex         | http://localhost:32400/web | 32400 |
| Prowlarr     | http://localhost:9696      | 9696  |
| Sonarr       | http://localhost:8989      | 8989  |
| Radarr       | http://localhost:7878      | 7878  |
| qBittorrent  | http://localhost:8080      | 8080 (+6881 tcp/udp peers) |
| FlareSolverr | internal only              | reachable at `http://flaresolverr:8191` from other containers |
| Stremio      | http://localhost:11470     | 11470 (+12470 HTTPS) |
| Lidarr       | http://localhost:8686      | 8686  |

## First-run wiring checklist

1. **qBittorrent** (:8080) — temp password from `docker logs qbittorrent`.
   Save paths are preconfigured: in-progress → `/data/torrents/incomplete`,
   finished → `/data/torrents/complete` (*arr categories land in `complete/{movies,tv,music}`).
2. **Prowlarr** (:9696) — add indexers; set FlareSolverr proxy tag where needed.
   Settings → Apps: add Sonarr/Radarr/Lidarr (use API keys from their
   Settings → General pages). Indexers sync to all automatically.
3. **Radarr** (:7878) — Root folder `/data/movies`; add qBT client
   (`http://qbittorrent:8080`, category `movies`, save path `/data/torrents/complete/movies`).
4. **Sonarr** (:8989) — same as Radarr with `/data/tv`, category `tv`,
   `/data/torrents/complete/tv`. Enable "Use hardlinks instead of copy" (default).
5. **Lidarr** (:8686) — Root folder `/data/music`; add qBT client
   (`http://qbittorrent:8080`, category `music`, save path `/data/torrents/complete/music`).
   Uses MusicBrainz for metadata.
6. **Jellyfin** (:8096) — libraries: `/data/movies`, `/data/tv`, `/data/music`.
   Dashboard → Playback: enable Intel QuickSync (HD 630 is passed through).
7. **Plex** (:32400/web) — sign in with Plex account once, then claim server;
   libraries on `/data`; enable hardware transcoding (requires Plex Pass).

## Notes

- **Hardlinks**: qBT and the *arr apps share the same `/data` mount, so completed
  downloads import instantly without copying.
- **DNS**: indexer/torrent containers use Cloudflare (1.1.1.1) + Quad9 (9.9.9.9)
  directly to sidestep ISP-level blocks; see `dns:` in service files.
- **Transcoding**: GPU device paths live in `compose.gpu.yml` (not the base
  services), relative to this host (`renderD128` = Intel HD 630 QuickSync,
  `renderD129` = AMD Radeon Pro). `media.sh` includes it only when the device
  from `.env` exists; edit `.env` per host (e.g. NVIDIA uses `/dev/nvidia*`).
- **Archiving**: when content is "done", move it out of `data/` yourself — the
  media servers never see anything outside this Area.
- **Backups**: `config/` holds all app state; `data/` holds media. Back up
  `config/` + `.env` and the stack is reproducible.