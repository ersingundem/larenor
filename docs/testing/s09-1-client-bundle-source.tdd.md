# S09.1 Client encrypted-bundle source boundary

Date: 23 September 2026

The Android Client could export a Core backup to an OS-owned destination but
had no production read boundary for a user-selected encrypted bundle. A future
restore screen would otherwise have to receive an unbounded `byte[]`, a source
URI, or a provider path through Dart before it could reject a malformed file.

## Acceptance boundary

This narrow slice completes three concrete source-boundary tasks:

1. Android opens only an `ACTION_OPEN_DOCUMENT`, openable, exact
   `application/vnd.larenor.core-backup` source and reads it through a
   read-only `ContentResolver` descriptor on a serial I/O executor.
2. Native code scans at most 424 MiB with one 64 KiB buffer, requires the exact
   `LARENOR-CORE-BACKUP\0\1` prefix and 65-byte minimum encrypted envelope,
   and returns only exact byte length plus lowercase SHA-256. URI, display
   name, provider path, and bundle bytes never cross the MethodChannel.
3. Every picker request has a 128-bit operation ID, and every bridge instance
   receives a process-unique Android request code that is never reused.
   Exact-session cancel, Flutter-engine disposal, and stale activity results
   retire the operation, close an opened descriptor once, and cannot publish a
   late proof into a new owner.

This port only validates the opaque encrypted source. It does not collect a
passphrase, upload or decrypt a bundle, call restore, or mutate Core/component
state.

## RED to GREEN evidence

The Flutter RED test first failed because
`ServerCoreBackupSourceAccess` did not exist. The native RED test likewise
referenced the missing `CoreBackupSourceBridge`. The GREEN focused runs pass
**5 Flutter tests** and **6 Robolectric tests**:

```text
flutter test \
  test/features/server/server_core_backup_source_access_test.dart

/Users/ersingundem/oikos/android/gradlew \
  -p android :app:testDebugUnitTest \
  --tests '*CoreBackupSourceBridgeTest'
```

The regressions cover exact channel arguments, secret-free response shape,
malformed native proof, unsupported platform and picker cancel, teardown
timeout suppression, OS picker intent, off-main reads, wrong magic, overflow,
gated-read cancellation, concurrent single close, stale picker-result
rejection, serialization before a new picker session, and an engine recreation
race where picker A returns after disposed bridge A has been replaced by
bridge B.

## Remaining S09.1 gates

The restore/import screen, encrypted upload transport, passphrase handoff,
Server restore application, rollback/interruption recovery, Android emulator
and real-provider SAF acceptance, independent review, and exact-head CI remain
open. S09.1 remains `pending`; evidence-backed counters stay at **26/125** and
**0/63**.
