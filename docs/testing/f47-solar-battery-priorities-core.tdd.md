# F47 solar and home-battery priorities Core acceptance

This package establishes the fail-closed Core domain boundary for advisory
solar and battery planning. Queue progress remains at 18/125 and selected
feature progress remains at 0/63: persistent Core storage, an authenticated API,
a production inverter worker, physical readback, and the Android tablet surface
remain explicit gates before F47 can be counted as complete.

Exactly three user acceptance criteria are in scope:

1. A user receives the same bounded advisory plan for the same exact home,
   meter, forecast, tariff, battery, reserve, and provider revisions. Forecasts
   never authorize automatic execution, and any revision drift fails closed.
2. Charge and discharge slots respect battery SoC, backup reserve, and power
   limits. A manual charge, discharge, or hold override wins only before its
   exact expiry and still cannot bypass those safety limits.
3. An admin must preview and explicitly confirm an inverter command. The worker
   result is successful only after exact revision-bound readback; a lost ACK is
   retained as uncertain and never replayed in-process, while a broken HMAC
   audit chain blocks later effects.

## TDD evidence

The RED commit `91187368` failed collection because the
`larenor_server.energy_priorities` package did not exist. The GREEN matrix has
three focused tests covering deterministic planning and every input revision,
safety and override expiry boundaries, and preview-confirm-readback behavior,
including exact plan drift, lost ACK idempotency, exception redaction, and audit
tamper rejection.
