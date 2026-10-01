# F27 offline downloads and local player — 2026-10-01

## Boundary

This slice exposes completed encrypted downloads through the token-free `ServerLocalMediaScope` projected by the account controller. The selector contains only Core, home, account and session-family identities. It cannot authorize a Core request, refresh credentials, select a provider or start a new download.

The screen does not reuse `CoreCatalogPlayerScreen`, its online capability gate or its Core API source. `ServerOfflineMediaController.local` accepts the exact selector captured when the route opens and offers three local-only operations: list completed manifests, open one exact completed manifest through the verified vault loopback, and purge that captured scope. Every async result is checked against the still-current selector before it is displayed or played.

## Product behavior

The Cupertino inventory has distinct loading, empty and integrity-error states. Each row is backed by a completed encrypted manifest and displays only its title and local encrypted byte count. Selecting a row opens a dedicated `media_kit` player route over the random process-local vault URL. Its play, pause and seek buttons call the actual player APIs; no watch-party, online-catalog, provider or download controls are shown.

Leaving the player, disposing the route, app backgrounding, a transient account mutation, logout or profile replacement closes the player and loopback lease. Transient working or pending state retains the encrypted records. A known terminal logout or stable scope replacement purges only the captured old scope. The vault still verifies expiry, AEAD, exact files, chunk sequence, whole-content SHA-256 and scope before binding playback.

Player open, play, pause, seek, stop and disposal share one bounded operation queue. Every queued effect rechecks the exact scope and screen generation before it starts. Timeout, native error, scope retirement and route disposal cancel the error/state subscriptions, fence late completion with stop, close the loopback lease, and dispose the player only after the bounded queue drains. Native error text is never displayed.

Completed-inventory reads and full encrypted playback verification also have a finite ten-minute local-I/O deadline. The larger deadline is intentional because opening a completed item verifies the complete encrypted content and SHA-256, up to the vault's 20 GiB quota. Each screen owns and cancels its deadline timer on replacement, account retirement, route disposal and playback retirement. Timeout invalidates the operation generation before a late result can bind UI or playback, retains the stored download, and presents a localized retry path; cancellation likewise rejects the late result without leaving a ten-minute timer alive.

## Evidence and limits

Focused widget coverage uses the production encrypted vault and a `media_kit` platform-player seam. It covers a delayed loading state, empty inventory, tampered-envelope error, real loopback bytes reaching `Player.open`, local-audio handoff, background closure and logout deletion of the exact directory and secure key. The account fixture serves only authentication/context/logout; inventory and playback issue no HTTP request.

Validated from the live source tree:

- `flutter test test/features/server/server_offline_downloads_screen_test.dart` — 13 passed. Negative cases cover inventory and lease I/O deadlines with rejected late results, disposal while each local I/O is pending with no retained deadline timer, a null lease, late lease after logout, player-open timeout and late completion, serialized controls, native error redaction, repeated account notifications, and `pause → stop → dispose` ordering.
- `flutter test test/features/server/server_offline_media_core_loopback_test.dart` — 2 passed, including completed-download recovery after controller restart with Core stopped.
- `flutter analyze lib/features/server/offline_media/data/server_offline_media_controller.dart lib/features/server/offline_media/presentation/server_offline_downloads_screen.dart test/features/server/server_offline_downloads_screen_test.dart` — no issues.

Root integration validation also ran the offline screen, account connection navigation, encrypted-vault loopback and Core loopback modules together with `flutter test --no-pub`: 46 passed (13 + 25 + 6 + 2). The normal connection route exposes the downloads entry even when initialization fails with Core offline and only the cached token-free local scope remains. Its route test verifies that entering downloads issues no further Core request or login/context request.

Physical decoder output, background audio policy and provider availability are not inferred from these software tests. The selector is decryption scope, not an authenticated Server session. Exact-HEAD final CI remains pending.
