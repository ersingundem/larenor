# S08.8 music-manager cache ownership TDD evidence

This slice hardens the persisted central music-manager snapshot against local
ownership and lifecycle races. It does not close S08.8 or change progress
counters.

## Three accepted behaviors

1. **Exact cleanup ownership.** Malformed, expired and oversized snapshots are
   removed only when the exact raw value read remains current. A replacement
   written during validation is preserved.
2. **Conditional writer ownership.** Cache writes capture the prior raw value
   and compare-and-write inside the serialized preference mutation. A stale
   writer cannot overwrite a newer manager revision. Schema version `1.0`
   and floating-point installation/Core/manager revisions fail closed; only
   exact integers are accepted.
3. **Lifecycle authority.** The controller passes its exact account/operation
   guard into cache writes. The cache checks it before and after every awaited
   acquisition, and the SharedPreferences executor checks it after reload and
   immediately before mutation. It also rechecks authority after `setString`;
   if authority retired during that await, it reloads storage and removes only
   its exact stale value. A concurrent replacement remains untouched.

## RED

Commit `11fe1cc6edc4de0b52a60185e6f647ca6b19bad0` added deterministic
replacement cleanup, stale-writer, numeric schema and delayed lifecycle
regressions. All four failed against unconditional write/clear and loose
numeric equality. Commit `2b1cba81824e23236af813fc8c045e71bfa36d9e`
expanded the numeric matrix to the resource installation, Core and manager
revisions; floating-point values were accepted before the parser fix. Commit
`6d59715340d4b2129724c261bde48d50fb6fb2c5` added the post-`setString`
retirement and replacement-owner regressions; both returned success before the
post-write authority check.

## GREEN

```text
flutter test test/features/server/server_music_manager_cache_test.dart
flutter analyze lib/features/server/music_manager/data/server_music_manager_cache.dart lib/features/server/music_manager/data/server_music_manager_controller.dart test/features/server/server_music_manager_cache_test.dart
python3 tool/execution_queue.py validate
git diff --check
```

The single focused package passes 11 tests. S08.8 remains pending: central
catalog detail/playback and queue dispatch, remaining Direct Jellyfin surfaces,
explicit legacy player mapping, integrated logout/Core-switch E2E,
independent review and exact-head CI remain open. Progress stays 26/125 and
0/63.
