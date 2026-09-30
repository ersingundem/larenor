# F30 private duplicate and retention cleanup executor

This slice implements only explicitly previewed and confirmed cleanup commands.
Automatic cleanup remains disabled. Credentials never enter the action command,
sealed cleanup catalogue, journal, receipt, or public observation. A successful
authenticated four-source collection leases the exact revision-bound credentials
and fixed loopback ports in worker memory for 60 seconds. Restart or authority
change requires a fresh collection.

qBittorrent authentication is its native 5.2 API-key mechanism, not an
invented gateway contract: the worker sends the pinned 32-character `qbt_`
credential in `Authorization: Bearer`. The upstream feature begins with
qBittorrent 5.2.0 and WebAPI 2.14.1; this deployment pins qBittorrent 5.2.3.

## Authority and provenance

The private collector joins every Jellyfin item path to one exact Sonarr
`episodeFile.id` or Radarr `movieFile.id`, translates the Jellyfin path through
the admin-provisioned mount catalogue, and seals only mount-relative provenance
with the exact four-source authority. It also seals qBittorrent hash,
`content_path`, size, imported media key, state, and retention result. Host and
service paths never enter the public health observation.

Duplicate resolution requires the exact keep/delete item roles from the Core
command, distinct Arr file IDs, distinct approved paths, coherent byte totals,
an existing keep file, and no downloading, seeding, or paused imported torrent
for a delete media key. Every approved host lookup walks from a verified mount
file descriptor with `O_NOFOLLOW`; fresh commands always reject missing delete
files. The sealed catalogue can reconstruct the plan for diagnostics after an
intent, but the engine does not infer success from later absence.

Retention resolution requires the exact torrent hash, imported media key,
complete state, confirmed Arr import, satisfied retention policy, candidate byte
count, and at least one currently mapped Jellyfin/Arr library item. It never
deletes a caller-provided path.

## Mutation and recovery

Duplicate cleanup uses two ordered effects per delete item:

1. read the exact Arr file ID and path, durably record its effect intent, call
   the exact file DELETE endpoint, then require a 404 readback;
2. read the exact Jellyfin item ID/path/size, durably record its effect intent,
   call item DELETE, then require a 404 readback.

Immediately before each destructive request, the executor authenticates to the
affected service, verifies its pinned product/version and collected server
identity where the API exposes one, re-reads the keep/import set, and re-reads
the exact target. A changed or absent target blocks the request. Arr runs first;
Jellyfin's library manager removes the database item even when the underlying
file was already removed, so the second step reconciles the library without
relying on a second filesystem deletion.

Retention cleanup reads the exact qBittorrent hash/path/size/complete state,
durably records its effect intent, posts `deleteFiles=true`, then requires the
exact hash to disappear from `/torrents/info`. qBittorrent documents 200 for all
delete scenarios, so the response status is never treated as proof.

Every effect ID is opaque and HMAC-independent of credentials and paths. A
successful upstream response plus exact absence is recorded completed in the
same run. If the worker stops after durable intent but before that completion
record, neither later presence nor absence proves that this worker submitted the
delete: recovery remains `effect_unknown`, requires operator review, and never
repeats or claims the request. Success requires every effect's verified and
durably recorded absence, a still-current Core authority, the same sealed plan,
and a live in-memory credential lease.

## Upstream contracts

- qBittorrent WebUI API 5.0 documents `POST /api/v2/torrents/delete`, exact
  `hashes`, and `deleteFiles=true`, and states that delete returns 200 for all
  scenarios: <https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-5.0%29>
- qBittorrent's official API-key documentation defines the `qbt_` key format
  and `Authorization: Bearer` header for qBittorrent 5.2.0+:
  <https://github.com/qbittorrent/wiki/blob/master/API-Key-Authentication-%28%E2%89%A5v5.2.0%29.md>
- Sonarr's official controller exposes exact-ID `DELETE /api/v3/episodefile/{id}`,
  returns not-found for an unknown file, and calls `DeleteEpisodeFile`:
  <https://github.com/Sonarr/Sonarr/blob/develop/src/Sonarr.Api.V3/EpisodeFiles/EpisodeFileController.cs>
- Radarr's official controller exposes exact-ID `DELETE /api/v3/moviefile/{id}`
  and calls `DeleteMovieFile`:
  <https://github.com/Radarr/Radarr/blob/develop/src/Radarr.Api.V3/MovieFiles/MovieFileController.cs>
- Jellyfin's official controller exposes `DELETE /Items/{itemId}` and calls the
  library manager with `DeleteFileLocation=true`; its library manager catches an
  already-missing file and still removes the item from persistence and cache:
  <https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/LibraryController.cs>
  and
  <https://github.com/jellyfin/jellyfin/blob/master/Emby.Server.Implementations/Library/LibraryManager.cs>

## Focused evidence

`test_media_archive_cleanup_catalog.py` covers sealed reopen, HMAC tamper,
descriptor-relative path proof, recovery after an intended file disappears, and
active imported-torrent protection. `test_media_archive_cleanup_executor.py`
runs the real numeric-loopback HTTP transport; its qBittorrent fixture removes
an actual temporary file, blocks mutation when the keep/import set disappears,
checks the pinned qBittorrent identity, and requires subsequent exact-hash
absence. Engine, journal, and collector tests cover per-effect durable intents,
lost-completion restart behavior, terminal proof, private provenance
publication, and secret/path exclusion.
