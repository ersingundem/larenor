# F30 production read collector evidence

Date: 2026-09-30

This slice implements the four-source, read-only observation behind the F30
Core snapshot authority. It does not implement capacity collection or archive
actions.

## Destination and authorization boundary

The worker re-derives `MediaStackPlan` against the packaged catalog before any
request. It selects the health TCP host port for Jellyfin, Sonarr, Radarr, and
qBittorrent, then connects only to numeric `127.0.0.1`. Every request is `GET`;
there is no DNS resolution, proxy, redirect, retry, cookie jar, or caller URL.
The single IPC deadline and gate cover every connect/read.

Credentials come only from `PrivateMediaArchiveWorkerCollection`. Jellyfin
uses its provisioned API key, Sonarr and Radarr use `X-Api-Key`, and
qBittorrent uses the API key installed by the existing owned-config path.
This is native qBittorrent 5.2 functionality: the official API-key contract
starts at 5.2.0/WebAPI 2.14.1, requires a 32-character `qbt_` key, and sends it
as `Authorization: Bearer`. The pinned 5.2.3 source loads
`Preferences/WebUI/APIKey`, validates it, and compares the submitted Bearer key
before opening a non-cookie API session. Evidence sources:
[official API-key contract](https://github.com/qbittorrent/wiki/blob/master/API-Key-Authentication-%28%E2%89%A5v5.2.0%29.md),
[5.2.3 authentication source](https://github.com/qbittorrent/qBittorrent/blob/release-5.2.3/src/webui/webapplication.cpp), and
[5.2.3 preference source](https://github.com/qbittorrent/qBittorrent/blob/release-5.2.3/src/base/preferences.cpp).
Larenor's owned config writes that exact preference, its existing authenticated
readback requires the key echoed by `/api/v2/app/preferences`, and the pinned
LinuxServer 5.2.3 image has already passed amd64/arm64 native bootstrap,
restart, Bearer-authentication and readback evidence recorded in
`docs/qbittorrent-service-verification-implementation-2026-09-10.md`.

## Upstream read contracts

- Jellyfin is pinned to 10.11.11. The collector reads `/System/Info`,
  `/Library/VirtualFolders`, and a bounded `/Items` query. It verifies the
  persisted server ID, exact server version, managed `/media` libraries, item
  path, media source size/direct-play state, runtime, and the single video
  stream. Evidence source: [Jellyfin 10.11.11 OpenAPI](https://blr1.mirror.jellyfin.org/main/files/files/openapi/stable/jellyfin-openapi-10.11.11.json).
- Sonarr reads the documented V3 status, series, per-series episode with
  `includeEpisodeFile=true`, queue, and paged history resources. Its OpenAPI
  exposes the episode GET and `includeEpisodeFile` query and defines the
  `downloadFolderImported` history event used for torrent correlation.
  Evidence source: [Sonarr V3 OpenAPI](https://raw.githubusercontent.com/Sonarr/Sonarr/develop/src/Sonarr.Api.V3/openapi.json).
- Radarr reads the documented V3 status, movie, queue, and paged history
  resources. TMDB identity and movie-file path establish the canonical movie
  record; `downloadFolderImported` establishes import correlation.
  Evidence source: [Radarr V3 OpenAPI](https://raw.githubusercontent.com/Radarr/Radarr/develop/src/Radarr.Api.V3/openapi.json).
- qBittorrent reads application version/preferences/categories and
  `/api/v2/torrents/info`. The official 5.0 Web API defines `content_path` as
  absolute, `total_size` in bytes, `seeding_time` and `max_seeding_time` in
  seconds, and `ratio`/`max_ratio` as the current and stopping ratios.
  Evidence source: [qBittorrent WebUI API 5.0](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-5.0)).

## Projection and fail-closed rules

Jellyfin `/media/...` and Arr `/data/...` paths are reduced to the same
library-relative path. Sonarr supplies `episode:tvdb:<series>:<season>:<episode>`;
Radarr supplies `movie:tmdb:<movie>`. A Jellyfin item without exactly one Arr
path match rejects the whole read. Paths never enter the public observation.

An Arr `downloadFolderImported` history record maps its `downloadId` to the
corresponding media key. Only an exact qBittorrent hash match sets
`importedConfirmed`. Retention is satisfied only when that import proof exists,
the torrent is complete/stopped, and an explicit nonnegative effective ratio or
seeding-time limit has been reached. Unlimited or unknown limits remain false.

Every collection is all-or-nothing. The worker rejects identity/version/config
drift, duplicate JSON keys, more than 4096 records, incomplete paging, unknown
queue/torrent states, untrusted roots, ambiguous paths, duplicate mappings,
invalid sizes/runtime/codec, authentication failure, or an expired gate. Error
codes and reprs contain no credential, title, or path.

The authenticated Jellyfin path and media profile are sufficient input for the
next private source-resolver slice. That resolver must persist a sealed mapping
bound to installation revision, snapshot revision, Jellyfin service revision,
item ID, media key, approved library root ID, relative path, source bytes,
codec, bitrate, and duration. Host resolution must use the trusted root policy
and descriptor-relative/no-follow traversal; a caller path is never accepted.

## Focused verification

```text
server/.venv/bin/pytest -q \
  server/tests/test_media_archive_read_collector.py \
  server/tests/test_media_archive_ingestion.py
```

The focused suite covers exact four-service identity, fixed loopback ports,
path/media-key joins, Arr import-history to torrent-hash joins, seeding-policy
evaluation, public secret/path absence, incomplete result rejection, unknown
state rejection, identity drift, and deadline gate rejection. Live home-service
acceptance remains a separate read-only environment gate.
