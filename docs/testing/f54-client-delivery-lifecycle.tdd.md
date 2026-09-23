# F54 Client delivery lifecycle hardening

This independent Client slice hardens three lifecycle boundaries without
changing the Server inbox contract or the Android notification bridge. F54
remains pending, so queue progress stays **26/125** and selected-feature
progress stays **0/63**.

## Three acceptance jobs

1. **Throwing authority callbacks fail closed.** A route/activity callback
   that throws is treated as inactive before the controller starts network
   polling or Android display work. Secure-store authority callbacks are
   normalized to `cancelled` before the first storage read rather than leaking
   an arbitrary callback exception.
2. **Awaited lifecycle work cannot survive authority drift.** Real loopback
   Core polling and acknowledgement readback are retired when the home changes;
   neither late result is published locally. If authority changes while a
   subscription record is being written, the serialized configuration write
   restores the exact previous value before returning `cancelled`.
3. **One receipt produces one display effect.** A repeated event ID/sequence
   with the same envelope does not trigger a second platform reconciliation.
   The controller retains the prior receipt envelope across a full refresh and
   rejects changed content for the same identity as `invalid_response`, so an
   altered replay cannot reach the in-app inbox or Android display. The native
   bridge's existing sequence watermark remains the final display dedupe.

## RED to GREEN evidence

The RED runs produced four intended failures: a throwing runtime authority
escaped as `StateError` and enabled the runtime, a throwing store callback was
not normalized to `cancelled`, authority drift left a newly written secure
record behind, and a changed envelope for the same receipt was accepted. The
home-drift loopback test already passed, confirming the existing generation and
interaction-epoch guards; the secure-write rollback is the nearest real
persistence gap closed in this slice.

```text
flutter test \
  test/features/local_notifications/local_notification_store_test.dart \
  test/features/local_notifications/local_notification_core_e2e_test.dart
```

The focused GREEN run passes **14/14**. After rebasing onto the exact live
`main`, the complete local-notification Flutter suite passes **31/31** and
targeted analysis reports no issues. Security, execution-queue,
progress-trailer and diff checks remain mandatory before the PR is opened.

The independent exact-head audit also exercised the store's CAS authority
identity. RED `8f59ec6c` proved that a `before` record from another
Core/home/actor could authorize a write when its lease tuple happened to
match. GREEN `47f92914` includes the context and actor in the exact comparison;
the complete local-notification suite now passes **32/32**, with targeted
analysis, security policy and execution-queue validation clean.

No access token, refresh token, notification body or secure-store value is
logged or exported. The temporary synthetic loopback credentials remain test
fixtures only. Background/OEM/Huawei and physical-device acceptance gates are
still open.
