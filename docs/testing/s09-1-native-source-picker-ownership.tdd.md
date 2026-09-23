# S09.1 native backup-source picker ownership

Date: 23 September 2026

The Android encrypted-bundle source originally allocated one request code per
bridge. Cancelling a document picker kept its `Pending` record until Android
returned that exact activity result. If the provider or system dropped the
result, every later source selection on the same Flutter engine failed as
`busy`. Reusing the bridge request code was necessary to avoid binding a stale
result to a new session, so the old implementation could not safely release
the owner early.

## Three-job acceptance boundary

1. Every picker operation receives a process-unique request code from the
   existing bounded source-only range. A cancelled operation releases the
   active slot immediately, allowing a new scoped session to launch with a
   different request code.
2. Cancelling while the picker is outstanding records the old code in a
   process-scope tombstone. Its eventual Activity result is consumed without
   opening a URI, scanning bytes, replying again or completing the current
   session.
3. Flutter-engine disposal records the same tombstone. A replacement bridge
   consumes the disposed bridge's stale result while its own picker remains
   pending and authoritative.

The original delivery never reused codes during the process lifetime. The
follow-up [request-code reuse slice](s09-1-native-request-code-reuse.tdd.md)
now recycles only completed codes after bounded wrap. Retired codes remain
reserved until their exact stale result is consumed. Cancellation after a
picker result has already started the serial scan does not add an unreachable
tombstone; it closes the current descriptor through the existing cleanup
executor.

## RED to GREEN evidence

The focused RED run executed seven Robolectric tests and failed only the three
new ownership regressions: the next picker remained busy, the stale code was
indistinguishable from the current picker, and a replacement bridge did not
consume the disposed bridge result. The GREEN run passes all **7** tests:

```text
/Users/ersingundem/oikos/android/gradlew \
  -p android :app:testDebugUnitTest \
  --tests '*CoreBackupSourceBridgeTest'
```

## Remaining S09.1 gates

This slice does not add encrypted upload, passphrase handoff, component-volume
publication or live restore. Android emulator/real-provider SAF acceptance,
independent review and exact-head CI remain open. S09.1 stays `pending`; the
evidence-backed counters remain **26/125** and **0/63**.
