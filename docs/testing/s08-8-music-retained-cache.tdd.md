# S08.8 retained music cache TDD evidence

Date: 23 September 2026

## Scope

This slice adds three bounded Client behaviors for the retained Music
Assistant inventory returned by Larenor Core:

1. The parsed inventory has an exact, secret-free wire representation rather
   than retaining provider payload maps.
2. A persisted snapshot is bound to the exact Core, home and account tuple,
   uses a five-minute TTL and 64 KiB quota, and is never returned after route or
   account ownership retires.
3. The controller may show that stored snapshot while the Core request is in
   flight, but reports stored, reachable and verified states separately. Only a
   current live response becomes verified and may replace the cache.

Each write has a random record identity. Compare-and-clear therefore retracts
only the retired owner's exact write and cannot erase an equivalent snapshot
published by a newer owner. SharedPreferences mutations remain serialized by
`ConfigurationWrites` and recheck ownership around load, reload and persist.

## RED and GREEN evidence

RED commit `140451ba` defined the missing serialization, tuple/TTL/quota,
retirement and stored-before-network contracts.

GREEN commit `ca95960f` passes the focused batch:

```text
flutter test test/features/server/server_music_retained_status_test.dart \
  test/features/server/server_music_retained_cache_test.dart \
  test/features/server/server_music_retained_controller_test.dart \
  test/features/server/server_music_retained_screen_test.dart
19 tests passed.

flutter analyze lib/features/server/music_retained \
  test/features/server/server_music_retained_status_test.dart \
  test/features/server/server_music_retained_cache_test.dart \
  test/features/server/server_music_retained_controller_test.dart \
  test/features/server/server_music_retained_screen_test.dart
No issues found.
```

S08.8 stays pending until all catalog, search, provider, player and queue paths
use the central Larenor API and the legacy migration and authority-loss E2E
gates pass. This slice does not advance the acceptance counters by itself.
