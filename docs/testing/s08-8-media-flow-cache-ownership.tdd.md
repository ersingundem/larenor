# S08.8 media-flow cache ownership TDD evidence

This slice hardens the existing bounded Core media-flow cache against local
read/write races. It does not publish the cache to playback, close S08.8, or
change progress counters.

## Three accepted behaviors

1. **Exact cleanup ownership.** Malformed, expired and oversized records are
   removed only when the exact raw value read is still current. A replacement
   written while validation is in progress remains intact.
2. **Conditional writes.** Every cache write captures the current raw value and
   uses compare-and-write inside the serialized SharedPreferences mutation. A
   stale writer reports `false` and cannot overwrite a newer Core flow record.
3. **Exact schema type.** The cache accepts schema version `1` only as an
   integer. JSON `1.0` fails closed and is conditionally cleaned without
   weakening the existing tuple, resource, authority, TTL or quota checks.

## RED

Commit `8f067aae1334125daa15bf2270cb715d19d9abb6` added deterministic
replacement-owner cleanup, stale-writer and numeric schema regressions. All
three failed against unconditional clear/write and loose numeric equality.

## GREEN

```text
flutter test test/features/server/server_media_flow_cache_test.dart
flutter analyze lib/features/server/media_flow/data/server_media_flow_cache.dart test/features/server/server_media_flow_cache_test.dart
python3 tool/execution_queue.py validate
git diff --check
```

The single focused package passes 6 tests. S08.8 remains pending: cache
publication, central playback and queue dispatch, remaining Direct Jellyfin
surfaces, explicit legacy player mapping, integrated logout/Core-switch E2E,
independent review and exact-head CI remain open. Progress stays 26/125 and
0/63.
