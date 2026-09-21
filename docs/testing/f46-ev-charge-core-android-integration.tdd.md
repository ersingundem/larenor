# F46 EV charge Core and Android integration

Status: **software integration ready; physical provider acceptance remains manual**

## Three acceptance criteria

1. **Exact authenticated authority.** Core derives tariff, power-budget,
   charger and schedule facts from a trusted provider boundary. Preview and
   confirm bind the current Core, home, account, session family, charger and
   source revisions. A foreign scope, account change, stale revision, late
   callback or changed route/lifecycle fails closed.
2. **Validated goal with single-effect control.** Departure and target state of
   charge are bounded while current charge, battery capacity and current limits
   come from the revision-bound provider snapshot before a deterministic plan is
   persisted. Confirm reserves one command
   before provider dispatch; replay returns the receipt and lost acknowledgement
   is uncertain until exact charger readback rather than automatically replayed.
3. **Truthful tablet operation.** The Android Settings route exposes verified
   capability, current and target battery, departure choice, plan energy and
   unverified receipt state in English and Turkish at 600/1280 widths with 2x
   text, 48dp actions, keyboard focus and TalkBack semantics. An absent or
   unreachable OCPP/vehicle provider disables planning and control explicitly.

## Automated evidence

- Server foundation and authenticated HTTP/provider suites cover planning,
  stale revisions, capability gating, replay, restart, tamper and provider
  failure.
- Flutter screen and route suites cover 600/1280 at 2x, EN/TR, authenticated
  Core calls, keyboard actions and stale account callback retirement.
- Command-history and Core-context rollback suites run because the new schema
  uses only `connection.execute` inside the existing startup transaction.

## Manual boundary

No real OCPP charger, vehicle account, tariff feed or physical tablet was used.
Provider compatibility, network-loss behavior at the charger and electrical
safety acceptance remain MANUAL. Queue and selected-feature counters do not
advance from **22/125** and **0/63** until those gates and exact CI complete.
