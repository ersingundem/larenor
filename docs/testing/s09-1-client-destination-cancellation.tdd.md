# S09.1 Client backup-destination cancellation ownership

Date: 23 September 2026

The Android destination bridge already retired stale activity results and
deleted partial documents. The Dart destination owner still waited for the
original MethodChannel `open` reply after route or session cancellation,
however. A stalled SAF provider could therefore retain the screen export
Future for the five-minute picker deadline after its authority had expired.

## Three-job acceptance boundary

1. Each destination picker owns a local cancellation signal. Route/session
   teardown completes the retired `open` Future immediately while exact-session
   native cleanup continues under its existing bounded timeout.
2. A native success or failure arriving after local cancellation is observed
   but ignored. It cannot publish a handle, escape as an asynchronous platform
   error, block a replacement owner, or cancel that replacement operation.
3. `scoped()` preserves the injected operation-ID source together with the
   channel, platform and timeout policy. The screen-scoped owner therefore
   keeps the same production identity semantics and is exactly testable.

Only a bounded chunk and commit proof cross the channel after a successful
open. Provider URI, path, bundle bytes and passphrase remain outside Dart
destination state and no token enters a URL, log or export.

## RED to GREEN evidence

The focused RED run failed all three new regressions: two cancelled picker
Futures exceeded 100 ms while waiting for the native reply, and the scoped
owner replaced the captured operation ID with a random one. The GREEN run
passes all **9** destination-access tests:

```text
flutter test test/features/server/server_core_backup_file_access_test.dart
```

## Remaining S09.1 gates

This slice does not add encrypted upload or live restore execution. Android
emulator and real-provider SAF acceptance, independent review and exact-head
CI also remain open. S09.1 stays `pending`; the evidence-backed counters remain
**26/125** and **0/63**.
