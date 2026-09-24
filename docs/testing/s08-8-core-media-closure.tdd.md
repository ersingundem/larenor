# S08.8 Core media client closure evidence

Status: software acceptance candidate; independent review and exact-head CI remain required before the queue item can be accepted.

## Journeys

1. A verified-Core or unresolved home opens only the Core catalog and account-row surface. Direct Jellyfin and Music Assistant providers cannot be constructed from that branch. Explicit Direct homes retain their existing local media experience.
2. A signed-in tablet browses the Core catalog and reads both recently-added and resume rows across a controller/process restart. Logout retires every published result, and a same-URL replacement Core cannot receive the previous Core's cached scope.
3. Static architecture coverage keeps the dashboard tile, Media Hub, search/detail hierarchy, casting hierarchy, retained target resolver, settings entries and music route behind their existing Core/direct authority selectors.

## RED and GREEN

| Stage | Commit | Command | Result | Guarantee |
| --- | --- | --- | --- | --- |
| RED | `153e90144e664f1536d001b5158e721e7ade0654` | `python3 -m unittest tool.tests.s08_8_core_media_architecture_test` | Expected failure: the verified-Core Media Hub entry imported `jellyfinClientProvider`. | The missing source boundary was reproduced before the selector split. |
| GREEN | `6a9a35072c20ce8f6477ebe848b68c2013a979ff` | `python3 -m unittest tool.tests.s08_8_core_media_architecture_test` and `flutter test test/features/media/hub/media_hub_screen_test.dart` | 2 architecture tests and 17 widget tests passed. | The Core selector is provider-free, `home == null` is fail-closed, and only exact Direct authority publishes the direct subtree. |
| E2E | `70e47d94` | `flutter test test/features/server/server_media_cache_loopback_test.dart` | 2 real-loopback journeys passed. | Browse, recent and resume cross real Core HTTP; restart revalidates rows, logout retires values, same-URL Core replacement misses the old scope, and no direct service path is read. |

The restart distinction is explicit: catalog browse may finish from its verified cache, while account rows always perform a fresh target-bound read and therefore end with `origin=live` when that read succeeds.

## Grouped verification

- `python3 -m unittest tool.tests.s08_8_core_media_architecture_test`: 2/2 passed.
- Core Media Hub, accessibility, cache, rows API/controller and rows screen Flutter batch: 72/72 passed.
- Navigation, dashboard, Core rows tile and settings tablet regression batch: 54/54 passed.
- Targeted `dart analyze`: no issues; targeted `dart format --output=none --set-exit-if-changed`: no changes.
- Security policy, queue validation, four-commit progress gate and `git diff --check`: passed.

## Persistence and privacy bounds

The journey reuses the shipped catalog and account-row caches. Their scope remains the exact Core/home/account tuple and installation/binding resource revisions; the test records only Core API paths. It asserts that neither a Jellyfin path nor a Music Assistant path is contacted. The fixture password is absent from request bodies used by media operations.

## Remaining gate

This branch does not increment `26/125` or `0/63`. S08.8 still requires independent P1/P2 review and current exact-head CI, including the Flutter shards and API 35 emulator journey, before its `test + review + ci` queue requirement can be marked complete. Physical HomePod, Cast and Apple TV results remain under `MANUAL.MEDIA` and are not part of this software acceptance.
