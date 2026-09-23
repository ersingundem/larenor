# S08.8 Movie Night persistence TDD evidence

This slice moves the Direct Home Movie Night preset from an unscoped raw
preference into a bounded typed record. It does not centralize Home Assistant
actions, close S08.8, or change progress counters.

## Three accepted behaviors

1. **Exact source scope.** New saves bind the canonical Home Assistant server
   URL to a `movie_night_preset` resource revision. A different server sees no
   preset and cannot clear the current owner's record. Existing strict legacy
   records remain readable only when their own canonical server URL matches.
2. **Schema, TTL and quota.** The record has exact schema/scope/resource/time
   fields, a 30-day TTL and an 8 KiB UTF-8 cap. Unknown schema, expired,
   malformed and oversized records fail closed and best-effort cleanup only
   removes the exact value read. Presets with and without a finishing scene
   round-trip; no credential or token is stored.
3. **Lifecycle ownership.** Reads now accept the same current-generation guard
   as writes and recheck it before preference acquisition, after reload, before
   decode/cleanup and before publication. The launcher supplies its exact
   route/account/playback guard and canonical active connection URL. Existing
   Direct source retirement and uncertain-write behavior remains intact.

## RED

Commit `7840c805e6a7e4dcf93c7c931c5d3f4d0e374de1` added exact scope/envelope,
schema/TTL/quota and queued-read retirement tests. They failed because the
store exposed only the raw v1 preset and had no clock, bounds or read guard.

## GREEN

```text
flutter gen-l10n
dart run build_runner build
flutter test test/features/media/movie_night/movie_night_persistence_test.dart test/features/media/movie_night/movie_night_runner_test.dart test/features/media/movie_night/movie_night_launcher_test.dart test/core/direct_home_routines_test.dart
flutter analyze lib/features/media/movie_night/data/movie_night_store.dart lib/features/media/movie_night/presentation/movie_night_launcher.dart test/features/media/movie_night/movie_night_persistence_test.dart test/features/media/movie_night/movie_night_runner_test.dart test/features/media/movie_night/movie_night_launcher_test.dart test/core/direct_home_routines_test.dart
python3 tool/execution_queue.py validate
git diff --check
```

S08.8 remains pending. Central catalog detail/playback dispatch, remaining
direct Jellyfin surfaces, explicit legacy player mapping, integrated
same-URL replacement/logout E2E, independent review and exact-head CI remain
open. Progress stays 26/125 and 0/63.
