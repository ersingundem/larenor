# S08.8 legacy Jellyfin provider preview TDD evidence

This slice exposes one real old provider record as a closed, secret-free
transition prompt. It does not copy credentials, create a Core mapping, or
claim the full S08.8 migration.

## Accepted behavior in this slice

- The existing `DirectCredentialRecord` reads the complete historical
  Jellyfin URL/user/token tuple and rejects pending or uncertain mutations.
- The public preview contains only the closed provider kind and the fact that
  credential re-entry is required. URL, user id, access token, device id, raw
  fields, and fingerprints are never returned or included in diagnostics.
- Missing, empty, control-character, unbounded, unsupported-scheme,
  credential-bearing, query/fragment, or otherwise invalid source values do
  not produce a preview.
- Direct-home ownership and caller authority are rechecked around the secure
  storage read. This read is side-effect free and does not create the legacy
  Jellyfin device id.

## RED

The preceding `test(s08.8): specify legacy Jellyfin provider preview` commit
added provider redaction, malformed/incomplete tuple, pending-mutation, and
authority-race tests before the preview contract existed. The focused test
failed to compile because the reader and preview model were absent.

## GREEN

Run from the branch head:

```text
flutter test test/features/media/jellyfin/legacy_jellyfin_provider_preview_test.dart test/core/direct_credential_record_test.dart
flutter analyze lib/features/media/jellyfin/data/legacy_jellyfin_provider_preview.dart test/features/media/jellyfin/legacy_jellyfin_provider_preview_test.dart
python3 tool/execution_queue.py validate
```

S08.8 remains pending. The follow-up migration contract now requires a fresh,
unchanged preview and newly authenticated Core service before retiring direct
state; see `s08-8-legacy-jellyfin-provider-migration.tdd.md`. Its accessible
user confirmation surface, active media/provider integration, other direct
provider migrations, wider catalog/search/player/queue adoption, E2E, review,
and CI evidence remain open. Progress stays 26/125 and 0/63.
