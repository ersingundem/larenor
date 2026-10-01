# F21/F24/F25/F27 Core-bound local player evidence — 2026-10-01

## Scope

This slice makes a verified Core catalog item reachable by the device-local
`media_kit` player without constructing a direct-home Jellyfin client or
moving a provider URL/key into Flutter. The catalog entry now has a separate
local-player action; its existing media-flow route is unchanged.

Two sources remain distinct:

- `coreLease` first captures the current Android display, decoder, network and
  bounded product-policy facts. Core asks Jellyfin to evaluate that exact
  client-reported profile and returns an opaque, short-lived observation ID.
  Only Core's `direct_play_supported` result can be consumed once to create the
  120-second playback lease. The adapter carries the exact installation,
  snapshot, service, item, profile and session authority, and owns renewal,
  retirement and generic `lease_unavailable` handling. Remux, transcode,
  unavailable and contract-unknown outcomes remain unavailable. No provider
  URL or key crosses into Flutter, and a missing lease never falls back to
  direct-home access.
- `offlineVault` downloads through the existing bounded F27 chunk contract,
  requires the returned completed manifest to match the exact catalog
  authority and content hash, and exposes only the encrypted vault loopback
  URI. A completed manifest can be restored after controller recreation; an
  incomplete or corrupt vault is rejected. It is labelled as a download rather
  than streaming.

The screen exposes accessible play/pause and ten-second seek controls for the
owned `Player`. It applies current Core audio/subtitle preferences to tracks
actually reported by that player, reads F25 segments using the original
catalog authority, and seeks only while the exact segment remains active. Its
F21 watch-party loop reports the actual player position/playing state with
measured round-trip time. Leader gestures publish a command for the exact
current lease and room snapshot. Segment skip uses the same leader-owned,
success-gated seek path; a follower sees the skip control disabled. Follower
directives seek to the commanded position before play or pause and call the
player directly, so they cannot echo another leader command.

Account generation, session family/context, route visibility, application
lifecycle and native capability drift retire the source, player, segments,
subscriptions and watch-party controller. Source replacement clears old
position/duration/playing state. Delayed source completions, directives and
invalidation callbacks carry exact generation, lease and room-snapshot guards;
they cannot reopen, control or close a successor.

## Focused evidence

- `server_core_catalog_player_test.dart` covers the exact online lease
  request/bearer ownership, capability observation and pre-open revalidation,
  logout during a pending source, Core preference application to an actual
  `Player`, exact-catalog segment skip, visible transport controls, source-state
  reset, successor isolation, leader command publication, and follower
  directive seek/pause without command echo.
- `server_media_catalog_screen_test.dart` first failed because no local-player
  action was reachable from the verified Core catalog. The named browse test
  now requires that action beside the existing media-flow action.
- `jellyfin_core_track_preferences_test.dart` uses the config-free current-Core
  methods. The legacy direct-player signatures remain wrappers and no direct
  Jellyfin configuration is sent on the Core preference wire.

## Honest open boundaries

- The F26 profile is explicitly client-reported. Decoder MIME presence is not
  a profile/level, hardware-acceleration, HDR, receiver or physical-performance
  guarantee. The provider observation authorizes original-byte Direct Play for
  the exact profile; it does not turn the online `source_bound` bytes into a
  whole-file integrity claim. The complete vault path remains the SHA-256
  verified path.
- Online leases are intentionally process-memory-only and return
  `lease_unavailable` after loss or process restart. Reopening requires a fresh
  observation; token/session rotation invalidates the current player rather
  than changing request headers beneath an open `Media` source.
- Offline restore is limited to a completed, exact-scope encrypted vault
  manifest. Incomplete-download resume remains separate, and no provider token
  is persisted by this slice.
- Physical playback, display performance and provider playback-progress
  reporting are not inferred from a successful player open.

## Validation

- `flutter test --no-pub test/features/server/server_core_catalog_player_source_test.dart test/features/server/server_core_catalog_player_test.dart test/features/server/server_media_catalog_screen_test.dart`: 33 passed (source 9, player screen 8, catalog 16), zero failures or skips. The screen cases include failed native pause/seek and segment skip producing zero leader commands, successful leader skip publishing its exact position, follower skip producing zero native input and zero command, a finite old seek draining before successor open, and a hung native mutation retiring the player instance before any successor can open.
- `dart analyze lib/features/server/local_media_player/presentation/core_catalog_player_screen.dart test/features/server/server_core_catalog_player_test.dart`: no issues.
- `dart format` reported both owned Dart files already formatted.

These software gates prove the normal verified-Core entry, observation-gated
source open and actual owned-player control lifecycle. They do not replace
changed-source hosted CI or the physical playback boundary above.

Root independently ran source, player, catalog and Core track-preference
tests together: **38 passed**, zero failures/skips, with the full scoped
local-player/catalog/store/test analysis clean. The private combined log is
`/private/tmp/larenor-core-player-integration-root-20261001.log`.
