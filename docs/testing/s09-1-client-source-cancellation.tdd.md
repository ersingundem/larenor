# S09.1 Client backup-source cancellation ownership

Date: 23 September 2026

The Android backup-source bridge already bounded an opaque encrypted bundle
and closed its descriptor on lifecycle cancellation. The Dart owner still
waited for the original MethodChannel `inspect` reply, however. A stalled
provider or bridge could therefore keep a retired route Future alive for the
five-minute inspection deadline, and a late native failure could escape after
a new owner had started.

## Three-job acceptance boundary

1. Every source inspection now owns a local cancellation signal. Route/session
   teardown completes the retired inspection immediately while exact-session
   native cleanup continues under its existing bounded timeout.
2. A native success or failure arriving after local cancellation is ignored.
   It cannot publish a proof, surface an asynchronous platform error, or
   cancel the next scoped owner.
3. `scoped()` preserves the injected operation-ID source as well as the
   channel, platform and timeout policy. Tests can therefore prove the exact
   128-bit operation captured by cancellation without replacing production
   ownership semantics.

The channel still returns only byte length and lowercase SHA-256. URI, provider
path, display name, bundle bytes and passphrase do not enter Dart state.

## RED to GREEN evidence

The focused RED run had three failures: a locally cancelled inspection timed
out after 100 ms, a late `PlatformException` escaped, and a scoped owner used a
new random ID instead of the captured factory. The GREEN run passes all **8**
source-access tests:

```text
flutter test \
  test/features/server/server_core_backup_source_access_test.dart
```

The existing native source suite remains the paired boundary for off-main
bounded reads, exact-session cleanup, request-code isolation and stale Android
activity results.

## Remaining S09.1 gates

This slice does not add encrypted upload, passphrase handoff, component-volume
publication or a live restore. Android emulator/real-provider SAF acceptance,
independent review and exact-head CI also remain open. S09.1 stays `pending`;
the evidence-backed counters remain **26/125** and **0/63**.
