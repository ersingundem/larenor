# S09.1 native destination picker ownership TDD evidence

## Scope

This slice closes three Android destination lifecycle gaps without changing the
backup envelope, passphrase handling, export stream, or restore contract:

1. Cancelling an outstanding destination picker immediately releases the
   bridge for a new export session.
2. A late result from the cancelled picker is consumed and its partial URI is
   deleted without opening or completing the current session.
3. A result owned by a disposed bridge cannot be accepted by a replacement
   bridge or reach its output handle.

Each outstanding picker operation receives a process-unique request code.
Destination codes descend through `1..0x4c42`; source picker codes use the
disjoint ascending range beginning at `0x4c43`. Cancelled or disposed codes are
kept as process-scope tombstones until their Android result is consumed. The
follow-up [request-code reuse slice](s09-1-native-request-code-reuse.tdd.md)
recycles completed codes after bounded wrap while retained tombstones continue
to fail closed on true exhaustion.

## RED

Command:

```text
/Users/ersingundem/oikos/android/gradlew -p android \
  :app:testDebugUnitTest \
  --tests '*CoreBackupDestinationBridgeTest' --console=plain
```

The target compiled and ran 8 tests. Exactly the three new regressions failed:

- `cancelledPickerImmediatelyReleasesANewSessionWithANewRequestCode`
- `staleCancelledPickerResultCannotOpenOrCompleteTheCurrentSession`
- `disposedBridgeResultCannotBeConsumedByNewBridgePicker`

The fixed request code left cancellation pending, and a replacement bridge
could not distinguish an old Activity result from its current picker.

## GREEN

The same focused native command passed all 8 tests after the minimal bridge
change. Existing streaming, size-cap, digest, cancellation, gated-write, and
gated-open coverage remained green.

The client destination contract is also exercised with:

```text
flutter test test/features/server/server_core_backup_file_access_test.dart
```

## Progress boundary

S09.1 remains pending because its complete installation/update and backup
acceptance has not closed. Queue counters remain `26/125` implementation and
`0/63` validation.
