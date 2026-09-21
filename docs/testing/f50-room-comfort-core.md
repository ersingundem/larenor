# F50 room comfort and ventilation Core foundation

This slice builds a local deterministic recommendation and a separate effect
boundary. Occupancy is advisory metadata only; it cannot authorize a plan or a
device command. Every evaluation and confirmation independently requires a live
administrator authority and the exact retained Core plan.

## Acceptance criteria

1. **Exact bounded comfort plan.** A versioned policy binds up to 32 rooms and
   their area, HVAC, window, service and binding revisions. Plans bind separate
   temperature, humidity, CO2, VOC, smoke, outdoor-weather and occupancy source,
   sensor and reading revisions. Sorting, thresholds, desired device states and
   occupied/unoccupied/stale advisory labels are deterministic and bounded.
2. **Safety before preference.** Stale indoor or outdoor sensors, smoke, outdoor
   freeze, rain when a window refresh is needed and unsafe outdoor air quality
   close the window and block ordinary comfort actions. A bounded 24-hour manual
   override binds the exact administrator, policy and room revision, expires
   without effect and cannot bypass a safety block. Occupancy never disables an
   air-quality response and never becomes an access decision.
3. **Verified HVAC/window effect.** A short-lived preview is bound to the trusted
   plan and exact current device readbacks. Confirm produces separate closed HVAC
   or window worker commands. Success requires a newer readback for the exact
   room, device, service, binding and desired state. Missing acknowledgements
   remain `unknown`; repeated confirmation returns the receipt without replay.
   A bounded HMAC-authenticated audit chain detects event, link and head changes.

## Evidence and remaining gates

The focused pytest suite covers source revisions, occupancy advisory behavior,
all hard safety paths, override expiry, stale account/room facts, trusted plan
resolution, preview/confirm readback, lost-ACK idempotency and audit tampering.
This foundation does not register HTTP routes, persist plan/preview/receipt state
across restart, implement Home Assistant or vendor workers, provide Android
Client-to-Core E2E, or prove physical HVAC/window behavior. F50 remains open, so
progress stays **20/125 (16.0%)** and selected-feature acceptance stays
**0/63 (0.0%)**.
