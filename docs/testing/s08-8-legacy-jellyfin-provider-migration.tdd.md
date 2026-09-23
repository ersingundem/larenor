# S08.8 legacy Jellyfin provider migration TDD evidence

This slice binds one exact device-local Jellyfin provider tuple to an explicit,
freshly authenticated Core service before retiring the local record. It does
not copy a legacy credential to Core and does not claim full S08.8 closure.

## Accepted behavior in this slice

- Preparation captures the exact validated local URL/user/token tuple only in
  private process memory and records the current Core Jellyfin service
  revisions. The public receipt exposes no tuple field, hash, URL, user id,
  token, account id, or Core service id.
- Confirmation first re-reads and compares the complete source tuple. A source
  change fails before another Core request. The target must then appear in a
  fresh authenticated Core list as either a new Jellyfin service or a higher
  revision with a new verification result. The Client never sends the legacy
  credential or a Core mutation during this flow.
- The local tuple is cleared only after that proof. A partially completed clear
  remains marked uncertain; an explicit retry with the same receipt rechecks
  the exact proven Core id/revision using GET, skips the now-partial source
  tuple, and safely retries retirement. Account, route, and direct-home
  authority are checked through the destructive boundary.
- One receipt has a single in-flight owner and selected Core target. A
  concurrent confirmation cannot select another target, start another Core
  read, clear the tuple, or consume the receipt. Every await and each storage
  effect rechecks the same receipt/target pairing; only an uncertain clear
  releases that pairing for an explicit retry of the already proven target.

## RED

Commit `bd392b4be35d0f30bcd311bb6a33dd4525fd9127` added the exact-source,
post-preview Core revision, secret-wire, and uncertain-retirement replay tests
before `LegacyJellyfinProviderMigration` existed. The focused test failed to
compile because the receipt and migration contract were absent.

Follow-up RED commit `a16244f5` delayed target A's live Core read and showed
target B could concurrently consume the same receipt and complete a second
clear. The in-flight ownership and exact selected-target checks close that
race while preserving same-target uncertain-clear retry.

## GREEN

Run from the branch head:

```text
flutter gen-l10n
flutter test test/features/media/jellyfin/legacy_jellyfin_provider_migration_test.dart test/features/media/jellyfin/legacy_jellyfin_provider_preview_test.dart test/core/direct_credential_record_test.dart test/features/server/server_services_test.dart
flutter analyze lib/features/media/jellyfin/data/legacy_jellyfin_provider_preview.dart test/features/media/jellyfin/legacy_jellyfin_provider_migration_test.dart test/features/media/jellyfin/legacy_jellyfin_provider_preview_test.dart
python3 tool/execution_queue.py validate
```

The focused and shared regression run passes 124 tests. The scoped analyze and
queue validation are clean.

S08.8 remains pending. An accessible user confirmation surface, integration
with the active media/provider flow, other direct provider migrations, wider
catalog/search/player/queue adoption, E2E, review, and CI evidence remain open.
Progress stays 26/125 and 0/63.
