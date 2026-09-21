# S07.3 Larenor Core music tablet client acceptance

This client slice consumes the single Larenor Core music manager contract. It
does not ask for a Music Assistant address or token and does not create a
second connection authority. Its Core API and unified-package dependencies are
accepted in `docs/s07-2-s07-3-software-closure-2026-09-21.md`; real provider
accounts and physical HomePod/AirPlay/Cast receiver acceptance remain separate
manual gates.

## Three acceptance criteria

| Criterion | Implemented boundary | Automated evidence |
| --- | --- | --- |
| One manager screen | Music Center opens one tablet surface for Spotify, Apple Music and YouTube Music catalog search, queue state, and enabled HomePod, AirPlay or Cast receiver selection. The saved Larenor Core account is the only credential source. | Strict manager/catalog models reject extra or secret-bearing fields; request tests bind installation, Core, manager and provider revisions and assert that no token or password enters a public body. |
| Verified controls | Play, pause, seek, queue add, queue replace and queue clear capture the current receiver identity, capability, queue and revision. A successful receipt is followed by a fresh manager read; missing or mismatched effect readback clears verification and is never retried. Saved setup, reachable service and verified receiver result remain visibly separate. | Parameterized controller tests cover all six operations and the second read. Negative readback, retained route callback and lifecycle tests fail closed. |
| Tablet and accessibility | The EN/TR surface supports 600 and 1200 px tablet/DeX widths at 200% text. Actions use 48 dp targets, visible selection, non-color status text, TalkBack headings/live regions and Enter/search IME activation. Account, route, TickerMode and app-lifecycle changes invalidate pending authority. | Widget tests cover the full EN/TR width matrix, hit targets, semantics, keyboard catalog selection, queue mutation and background expiry. Existing Music Center tablet tests cover its new route entry without regressing direct Home Assistant playback. |

## Manual boundary

The tests use a local synthetic Core account and manager responses. They do not
claim real Spotify, Apple Music or YouTube Music playback, HomePod/AirPlay/Cast
discovery, network pairing, synchronized groups, Huawei MatePad, DeX, physical
keyboard or TalkBack device acceptance. Those gates remain explicit manual
acceptance and do not block the declared S07.3 software scope.

## Core contract cross-check

The rebased client was checked against `codex/s073-music-core-api` at
`3b3bca6e`. Paths and strict envelopes match the Core manager, refresh,
catalog-search and command routes. Requests carry the exact installation,
Core, manager/player, provider setup, provider instance, target and queue
authority fields. The catalog request names all seven Core media types,
including `radio`; response items must return the selected provider instance.
Command success still requires the matching receipt revision and a subsequent
manager readback with the expected receiver or queue effect.
