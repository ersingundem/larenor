# K12 watchdog and local usage foundation — 2026-09-21

K12 remains **pending** because `K03.remaining` has not yet supplied the final
renderer-death and reconnect callbacks. This slice closes three independent
software prerequisites without claiming Android force-stop recovery or a
physical 24-hour tablet result.

## Acceptance contract

1. **Bounded explicit recovery.** `KioskRecoveryGate` permits at most three
   user-requested recoveries in a rolling ten-minute window. The next attempt
   enters safe maintenance state. The gate owns no timer, reconnect callback or
   command replay path, and explicitly reports that no automatic recovery is
   pending.
2. **Content-free durable usage.** The local journal stores only a UTC day and
   five closed integer counters. It retains at most 30 days, rejects unknown or
   malformed fields, serializes concurrent updates, and exposes a fixed-schema
   CSV preview. URLs, page content, credentials, sensor values and raw platform
   errors have no field in the model.
3. **Accessible maintenance surface.** Display settings exposes a read-only
   kiosk recovery screen. EN/TR layouts pass at 600 and 1280 logical pixels
   with 2x text, the refresh action is at least 48 dp, corrupt storage hides
   stale counts, and the UI states the Android force-stop/OS termination limit.

## TDD evidence

- RED: `b29eda35` introduced the policy, persistence and tablet acceptance
  tests before production classes existed.
- GREEN: focused Flutter tests cover policy, restart persistence, retention,
  strict parsing, CSV output, four EN/TR tablet viewports and the existing
  Display pane accessibility/lifecycle suite.

## Remaining K12 gates

- Wire the gate to the final `K03.remaining` renderer-death and reconnect
  receipts after that contract lands; source identity must remain bounded and
  must not enter the journal.
- Run physical Huawei/DeX process-death and long-idle checks. Android
  force-stop and OS relaunch remain unsupported claims.
