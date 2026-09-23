# S09.1 native backup picker request-code reuse

Date: 23 September 2026

Android backup source and destination pickers previously consumed one activity
request code for every operation for the entire process lifetime. Even a
successful or user-cancelled picker result never released its code. A
long-running managed tablet would therefore reach the finite 16-bit range and
permanently lose backup source/destination selection until process restart.

## Three-job acceptance boundary

1. A synchronized process-scope pool wraps within each existing disjoint
   range. Codes are reusable only after the matching Activity result completes;
   ascending source and descending destination allocation remain separated.
2. Source and destination bridges release a completed or failed-launch code on
   every terminal picker path. A one-code regression proves both bridges can
   launch again without restarting the process.
3. Cancellation and Flutter-engine disposal retire rather than release a code.
   The code remains unavailable through wrap/exhaustion until its exact stale
   Activity result is consumed; unknown completion cannot release another
   owner.

The pool carries only integer request codes. Bundle URI, bytes, digest,
passphrase, destination handle and session identifier do not enter the pool,
logs or exported state. Existing source/destination ranges stay disjoint.

## RED to GREEN evidence

After local generated-source setup, RED failed Kotlin test compilation because
the bounded reusable pool and bridge injection points did not exist. GREEN
passes **22 Robolectric tests**: 3 pool, 9 source and 10 destination cases.

```text
/Users/ersingundem/oikos/android/gradlew -p android \
  :app:testDebugUnitTest \
  --tests '*CoreBackupRequestCodePoolTest' \
  --tests '*CoreBackupSourceBridgeTest' \
  --tests '*CoreBackupDestinationBridgeTest' \
  --console=plain
```

## Remaining S09.1 gates

Production component snapshot/restore authority, component rollback and
interruption recovery, Android emulator/real-provider SAF acceptance,
independent review and exact-head CI remain open. S09.1 stays `pending`; the
evidence-backed counters remain **26/125** and **0/63**.
