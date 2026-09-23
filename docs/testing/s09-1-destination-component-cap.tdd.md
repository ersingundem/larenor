# S09.1 Android destination component-bundle cap

Date: 23 September 2026

The Client HTTP export transport already accepts the Server contract's 424 MiB
encrypted bundle ceiling. The Dart destination proof guard and Android native
sink still retained the earlier 168 MiB ceiling. A valid component-bearing
export could therefore stream completely and then lose its OS-owned document
at the destination boundary.

## Acceptance boundary

This slice completes three concrete tasks without changing the open Client
resource-model PR or Server restore code:

1. The Dart destination commit guard derives its ceiling from
   `LarenorServerApi.maxCoreBackupBytes`, accepts the exact 424 MiB proof, and
   rejects one byte above it before invoking the platform commit.
2. The Android destination bridge enforces the same production 424 MiB ceiling
   for cumulative 64 KiB appends and final length proof. Tests use a small
   injected limit to exercise exact-bound commit without allocating a large
   bundle.
3. Both streamed overflow and declared-length overflow fail as
   `invalid_request`, close the descriptor, delete the partial URI exactly
   once, never fsync/finish, and never publish a destination URI.

MIME, filename, content URI ownership, digest equality, chunk size, serial I/O,
session identity, cancellation, and disposal behavior remain unchanged.

## RED to GREEN evidence

The Dart RED test failed because `ServerCoreBackupFileAccess.maxBytes` did not
exist and exact 424 MiB commit was rejected by the 168 MiB literal. Native RED
tests failed because the bridge had no bounded test injection; after the cap
was wired, the streamed-overflow RED checkpoint also showed the generic
`unavailable` classification instead of the static `invalid_request` result.

GREEN focused coverage passes **7 Flutter tests** and **6 Robolectric tests**:

```text
flutter test \
  test/features/server/server_core_backup_file_access_test.dart

/Users/ersingundem/oikos/android/gradlew -p android \
  :app:testDebugUnitTest \
  --tests '*CoreBackupDestinationBridgeTest'
```

## Remaining S09.1 gates

Privileged component capture, component restore and rollback, interruption
recovery, full restore/import UX, real-provider SAF acceptance, independent
review, and exact-head CI remain open. S09.1 remains `pending`; counters stay
at **26/125** and **0/63**.
