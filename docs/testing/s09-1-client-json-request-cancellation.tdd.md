# S09.1 Client JSON request cancellation ownership

Date: 23 September 2026

The Core backup controller already discarded plan and restore-preflight
results after route, account or lifecycle retirement. The underlying JSON
HTTP request remained alive until the server replied or the 20-second timeout
expired, however. A retired screen could therefore retain transport work and
response resources even though it no longer accepted the result.

## Three-job acceptance boundary

1. Every backup-plan read owns a cancellation signal. `invalidate`, account
   authority loss and controller disposal now abort the exact in-flight
   `AbortableRequest` rather than only hiding its result.
2. Restore preflight uses the same bounded ownership contract. Lifecycle
   cancellation remains distinct from the request timeout and cannot publish
   compatibility or failure state after retirement.
3. Request cleanup is identity-bound. A delayed abort from an older generation
   cannot clear or cancel a newer plan request owned by the same controller.

The request remains pinned to the configured Server endpoint. Access tokens
stay in the Authorization header, never in the URL, logs or exported backup,
and the existing bounded JSON response parser remains unchanged.

## RED to GREEN evidence

The focused RED run failed all three new regressions because neither plan nor
preflight received a lifecycle abort signal; the delayed first request also
prevented the operation-isolation scenario from completing. The GREEN run
passes all **24** Core backup client tests:

```text
flutter test test/features/server/server_core_backups_test.dart
```

## Remaining S09.1 gates

This slice does not implement encrypted upload or live restore execution.
Android emulator and real-provider SAF acceptance, independent review and
exact-head CI also remain open. S09.1 stays `pending`; the evidence-backed
counters remain **26/125** and **0/63**.
