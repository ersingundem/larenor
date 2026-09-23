# S08.8 legacy Jellyfin track-preference preview TDD evidence

This slice recovers one real pre-Core settings record as a read-only,
sanitized preview. It does not silently import or delete the record and does
not claim the full S08.8 migration.

## Accepted behavior in this slice

- The reader uses the exact historical endpoint-and-user hash key, while the
  access token and device id never affect the lookup.
- Only schema-v1 audio/subtitle language choices are returned. They are
  normalized with the player contract and carry no URL, user id, device id,
  token, or raw record in fields or diagnostics.
- Unknown fields, incompatible schema, malformed JSON, invalid languages,
  empty choices, values over 128 UTF-8 bytes, and unbounded source identities
  fail closed.
- Direct-home and caller authority are checked around every asynchronous
  storage boundary. Preview is read-only; user confirmation and the later
  exact Core write remain mandatory.

## RED

The preceding `test(s08.8): specify legacy track preference preview` commit
added the focused legacy-record, scope, corruption, non-mutation,
secret-redaction, and authority-race tests before the reader existed. The test
failed to compile because the preview contract was absent.

## GREEN

Run from the branch head:

```text
flutter test test/features/media/jellyfin/legacy_jellyfin_track_preferences_preview_test.dart
flutter analyze lib/features/media/jellyfin/data/legacy_jellyfin_track_preferences_preview.dart test/features/media/jellyfin/legacy_jellyfin_track_preferences_preview_test.dart
python3 tool/execution_queue.py validate
```

S08.8 remains pending. A user-facing confirmation flow must bind this preview
to the exact current Core authority, re-read the unchanged source, write the
central preference revision, and retire the legacy record without uncertain
replay. Wider catalog/search/provider/player/queue adoption and remaining
typed-cache/E2E evidence also remain open. Progress stays 26/125 and 0/63.
