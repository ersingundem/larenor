# S08.8 confirmed legacy track-preference migration TDD evidence

This slice turns the existing read-only legacy Jellyfin preference preview into
an explicit confirmation contract. It migrates only normalized audio/subtitle
choices; direct Jellyfin identity and credentials remain device-local.

## Accepted behavior in this slice

1. `prepare` binds a one-session confirmation receipt to the exact legacy key
   and raw record. The receipt exposes only normalized choices, and a changed
   source is rejected before any Core request.
2. `confirm` re-reads the current Core record inside the live account/session,
   merges only the legacy fields that exist, preserves a newer same-account
   sibling field, and uses the current optimistic revision. URL, user, device,
   token, raw legacy JSON, and source fingerprint never enter the request or
   diagnostics.
3. The exact legacy record is removed only after the validated Core result.
   Authority is rechecked around every storage/network boundary. If the Core
   PUT may have committed before authority loss, retry first reads Core and
   skips an already-applied PUT before retiring the unchanged source.

## RED

Commit `af18d8e5` added the three focused migration regressions before the
coordinator existed. After normal generated-source setup, the test failed to
compile at each missing `LegacyJellyfinTrackPreferencesMigration` reference.

## GREEN

Run from the branch head:

```text
flutter test test/features/media/jellyfin/legacy_jellyfin_track_preferences_migration_test.dart test/features/media/jellyfin/legacy_jellyfin_track_preferences_preview_test.dart test/features/media/jellyfin/jellyfin_core_track_preferences_test.dart
flutter analyze lib/features/media/jellyfin/data/jellyfin_track_preferences_store.dart lib/features/media/jellyfin/data/legacy_jellyfin_track_preferences_preview.dart test/features/media/jellyfin/legacy_jellyfin_track_preferences_migration_test.dart test/features/media/jellyfin/legacy_jellyfin_track_preferences_preview_test.dart test/features/media/jellyfin/jellyfin_core_track_preferences_test.dart
python3 tool/execution_queue.py validate
```

S08.8 remains pending. The tablet still needs to wire this contract to an
accessible confirmation surface, and the wider provider/player/queue
migration plus authorization-loss E2E evidence remain open. Progress stays
26/125 and 0/63.
