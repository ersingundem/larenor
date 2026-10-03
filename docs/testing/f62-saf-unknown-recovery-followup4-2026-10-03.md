# F62 SAF unknown recovery follow-up 4 — 2026-10-03

This private integration follow-up keeps the public SAF 5 and owned-session 6
wire unchanged. It corrects the production disposal boundary:
`RdpNativeBridge.retire()` first reports `transportRetiring(session)` and
closes the transport, then `dispose()` closes the SAF coordinator. The
coordinator now retains that exact session until an owned daemon performs
`closeAndAwaitNativeDrain`. Main-thread disposal returns promptly.

The single process reservation is released only when the exact native drain and
the mirror manager's provider/executor quiescence both complete inside one
monotonic bound. Timeout, exception, a pending native callback, active provider
work, or a result arriving after the bound leaves the reservation held until
process death. A late success never upgrades that outcome. Manager shutdown
always interrupts and joins both owned executors within the remaining bound;
duplicate callback plus throw ends the native callback lease exactly once.

A durable `COMPLETE` record remains cleanup debt. Neither
`requirePrepareAllowed` nor `create` permits replacement until exact
private-mirror cleanup has durably written `DISCARDED`. Cold `COMPLETE` and
`DISCARD_INTENT` recovery remains local deletion only: it performs no provider
create/write, transport replay, or hidden successor admission.

Focused JVM validation ran:

```
:app:testDebugUnitTest
  --tests com.ersingundem.larenor.rdp.RdpSafTransferCoordinatorRecoveryTest
  --tests com.ersingundem.larenor.rdp.RdpSafMirrorManagerTest
  --tests com.ersingundem.larenor.rdp.RdpSafTransferJournalTest
  -x :app:compileFlutterBuildDebug
```

The three classes contain 28 tests, with 0 failures, 0 errors, and 0 skips. New
regressions cover the exact production retire/close/coordinator-close order,
prompt main-thread return, pending and late native drain reservation behavior,
executor shutdown after callback timeout, callback-then-throw single
completion, and `COMPLETE` rejection until durable `DISCARDED`. The private
log is `evidence/focused.log`, SHA-256
`37efe4296c77f686337eb761a4af1dafea024d803a0e38f247615f01b9b6bf17`.

This is local JVM lifecycle evidence. It does not claim Android provider
acceptance, a real FreeRDP transfer, Gateway acceptance, CI success, or feature
acceptance.
