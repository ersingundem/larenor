# F27 Core player lease ownership evidence — 2026-10-01

## Scope

The verified-Core catalog may show online playback, but opening it requires a
current native playback profile and a server-held F26 observation. The source
passes only that observation ID to Core. It never receives a Jellyfin URL,
provider session, API key, or source ID. The returned media URL is a short Core
lease URL with the exact captured Core bearer and `source_bound` byte integrity.

`source_bound` means Core bound the bytes to the selected provider item and
authority. It does not claim that the original media bytes were independently
content-hash verified, transcoded, or physically accepted by a device.

## Ownership and cancellation

- Online open requires a non-null `CoreCatalogPlaybackAuthorization`; offline
  vault open requires it to be null.
- The source revalidates the native profile immediately before and after the
  one-use lease POST. An expired observation, changed account/session family,
  changed native profile, stale caller generation, or stale response returns no
  playable source.
- Overlapping opens allocate their generation before awaiting. A late Core
  create response is retired best effort and cannot replace or cancel the newer
  lease.
- Create requires the returned lease ID to equal the exact request ID at
  revision 1. Renewal requires the same lease ID and exactly the next revision.
  A malformed ID, revision, or authority response triggers cleanup only for the
  expected owned lease; an ID supplied by the malformed response is never
  retired or opened.
- Renewal uses a fresh native profile capture and compares its full digest with
  the profile that authorized the lease. It does not reuse the consumed F26
  observation's 30-second TTL as continuing playback evidence.
- Account logout, account generation change, or access-token/session-object
  rotation invalidates the exact active lease. The media bearer is never
  rewritten to the replacement token; the user must reopen.
- Renewal and expiry timers belong to one exact lease owner. Closing a stale
  lease cannot cancel its successor's timers. A lease whose expiry is already
  reached is retired and never returned to the player.
- Core restart, lease expiry, or an otherwise missing lease is surfaced as
  source unavailable. The client cannot distinguish those causes from a 404 and
  does not silently fall back to direct-local provider access.
- Offline open first asks the current authenticated account scope for an exact
  completed encrypted-vault record. A verified record opens locally without a
  Core request. Only an absent record with no controller failure may begin a
  download; missing-key, chunk, manifest, or digest failure is terminal and is
  never overwritten by a redownload.

## Focused proof

`test/features/server/server_core_catalog_player_source_test.dart` covers:

- verified-Core route reachability with fail-closed observation admission;
- null-observation rejection and exact `playbackObservationId` transport;
- already-expired create rejection and exact retirement;
- two overlapping creates where the late response is retired without closing
  its successor;
- account token/session rotation invalidation with zero renew request;
- native profile drift before renewal with zero renew request;
- wrong create ID/revision, wrong renew ID/revision, and wrong renew authority,
  with cleanup bound to the exact expected owned ID and CAS revision;
- encrypted-vault restore with zero Core requests, followed by a corrupted
  chunk case that returns no lease and performs no redownload.

The focused Flutter command is:

```text
flutter test --no-pub test/features/server/server_core_catalog_player_source_test.dart
```

This evidence uses an owned bounded HTTP fixture and a native-capability port
fixture. It does not establish physical codec playback, Jellyfin throughput,
device thermal behavior, or provider availability; those remain runtime/manual
acceptance boundaries.
