# S08.8 explicit legacy player mapping TDD evidence

This slice introduces a one-session confirmation contract for moving one
fresh Direct Music Assistant player choice to an explicit central Core
provider/receiver choice. It does not silently match names, copy Direct
identifiers into Core state, close S08.8, or change progress counters.

## Three accepted behaviors

1. **Fresh secret-free preview.** Preparation requires a current, complete
   Direct discovery with one exact loaded config entry and one available,
   enabled registry-backed player. Future, expired, partial, duplicated,
   malformed or unstable identities fail closed. The public preview exposes
   only the bounded player label and states that a Core choice is required.
2. **Explicit live Core choice.** Confirmation re-reads the exact Direct
   player, refreshes the selected Core manager under the active administrator
   session, and requires the exact provider revision plus receiver identity,
   kind, provider, queue and group membership. It then persists only the
   scoped central provider/receiver tuple. No Direct entity, config, registry,
   device or display field enters the persistent record or Core request.
3. **Single-owner lifecycle boundary.** A receipt admits one in-flight target
   and is consumed once. Concurrent or replayed confirmation fails. Authority
   is rechecked around each Direct read, Core refresh and cache operation. If
   route/account authority retires during persistence, only the exact mapping
   value written by that attempt is cleared; a replacement owner survives.

## RED

Commit `55300a84e873045328d3fdc64e44a3426c8f2415` added the focused preview,
confirmation, source-drift, concurrency, replay and delayed-persistence
journeys. The package failed to compile because the mapping contract did not
exist.

## GREEN

```text
flutter test test/features/server/legacy_music_player_mapping_test.dart
flutter analyze lib/features/server/music_manager/data/legacy_music_player_mapping.dart test/features/server/legacy_music_player_mapping_test.dart
python3 tool/execution_queue.py validate
git diff --check
```

The single focused package passes six tests. S08.8 remains pending: this
contract still needs an accessible route integration, remaining Direct media
surface replacement, integrated logout/same-URL Core-switch E2E, independent
review and exact-head CI. Progress stays 26/125 and 0/63.
