# S08.8 Core media client closure evidence

Status: software acceptance complete at exact source `ff55f5141ad3f686e73511465ff057f14b18495a`. Independent P1/P2 review and current-head CI passed. Physical receiver journeys remain under `MANUAL.MEDIA`.

## Journeys

1. A verified-Core or unresolved home opens only the Core catalog and account-row surface. Direct Jellyfin and Music Assistant providers cannot be constructed from that branch. Explicit Direct homes retain their existing local media experience.
2. A signed-in tablet browses the Core catalog and reads both recently-added and resume rows across a controller/process restart. Logout retires every published result, and a same-URL replacement Core cannot receive the previous Core's cached scope.
3. Static architecture coverage keeps the dashboard tile, Media Hub, search/detail hierarchy, casting hierarchy, retained target resolver, settings entries and music route behind their existing Core/direct authority selectors.

## RED and GREEN

| Stage | Commit | Command | Result | Guarantee |
| --- | --- | --- | --- | --- |
| RED | `354c083e` | `python3 -m unittest tool.tests.s08_8_core_media_architecture_test` | Expected failure: the verified-Core Media Hub entry imported `jellyfinClientProvider`. | The missing source boundary was reproduced before the selector split. |
| GREEN | `991ce2ca` | `python3 -m unittest tool.tests.s08_8_core_media_architecture_test` and `flutter test test/features/media/hub/media_hub_screen_test.dart` | 2 architecture tests and 17 widget tests passed. | The Core selector is provider-free, `home == null` is fail-closed, and only exact Direct authority publishes the direct subtree. |
| E2E | `6ca4fc00` | `flutter test test/features/server/server_media_cache_loopback_test.dart` | 2 real-loopback journeys passed. | Browse, recent and resume cross real Core HTTP; restart revalidates rows, logout retires values, same-URL Core replacement misses the old scope, and no direct service path is read. |
| Search RED | `4e086011` | `python3 -m unittest tool.tests.s08_8_core_media_architecture_test` | Expected failure: `search_route_bypasses_media_authority_selector`. | The production global-search action could still open the Direct provider search under Core authority. |
| Search GREEN | `4212b11d` | Architecture test plus local-search and Media Hub widget tests | 2 architecture and 26 widget tests passed. | The production search action enters `/media`, where the same fail-closed Core/direct selector chooses the catalog surface. |
| Import RED | `9fdfca18` | `python3 -m unittest tool.tests.s08_8_core_media_architecture_test` | Expected failure: a relative Jellyfin provider import was not detected. | A symbol-marker-only guard could be bypassed with the repository's normal relative-import style. |
| Import GREEN | `0ad5a555` | `python3 -m unittest tool.tests.s08_8_core_media_architecture_test` | 3/3 passed. | Core-only files resolve every relative and package import and reject the legacy Jellyfin, Music Assistant, Arr, Seerr, casting, playback and Direct hub trees. |

The restart distinction is explicit: catalog browse may finish from its verified cache, while account rows always perform a fresh target-bound read and therefore end with `origin=live` when that read succeeds.

## Grouped verification

- `python3 -m unittest tool.tests.s08_8_core_media_architecture_test`: 3/3 passed.
- Core Media Hub, accessibility, cache, rows API/controller, rows screen and global-search Flutter batch: 81/81 passed.
- Navigation, dashboard, Core rows tile and settings tablet regression batch: 54/54 passed.
- Targeted `dart analyze`: no issues; targeted `dart format --output=none --set-exit-if-changed`: no changes.
- Security policy, queue validation, progress gate and `git diff --check`: passed.

## Persistence and privacy bounds

The journey reuses the shipped catalog and account-row caches. Their scope remains the exact Core/home/account tuple and installation/binding resource revisions; the test records only Core API paths. It asserts that neither a Jellyfin path nor a Music Assistant path is contacted. The fixture password is absent from request bodies used by media operations.

## Acceptance boundary

Independent diff review found no remaining P1/P2 blocker after the search and resolved-import fixes. On exact source `ff55f5141ad3f686e73511465ff057f14b18495a`, Android Build run `35950583150` passed static analysis, four Flutter shards, four Server shards, both aggregate gates, the API 35 emulator journey and debug APK; Security run `35950582810` passed dependency, platform and secret policy. The same source passed the local 3/3 architecture, 81/81 primary and 54/54 surface-regression proof. This completes the S08.8 software acceptance. Physical HomePod, Cast and Apple TV results remain under `MANUAL.MEDIA` and are not part of this software acceptance.
