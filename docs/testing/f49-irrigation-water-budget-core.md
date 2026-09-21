# F49 irrigation and water-budget Core foundation

This slice builds a local, deterministic planning contract and a separate valve
effect boundary. Forecast data is advisory: rain can defer a recommendation,
and an explicit unexpired administrator override can replace that recommendation.
Leak, freeze, wind and stale safety or soil signals are hard fail-safe blocks and
cannot be bypassed by an override.

## Acceptance criteria

1. **Exact inputs and bounded deterministic plan.** The policy binds up to 32
   zone, area, valve service and binding revisions. Every plan records exact soil
   sensor/reading, weather source/forecast, safety, budget and policy revisions.
   Input order cannot change the plan; zone order, duration, daily remaining
   water, price-derived cost and result counts are bounded. Core retains the
   exact generated plan as the authority used by the effect boundary.
2. **Safety before recommendation.** Unknown or stale soil/safety state, leak,
   freeze and excessive measured wind produce zero-water blocked items. A valid
   rain forecast only defers a recommendation. Manual overrides bind the exact
   administrator, policy and zone revision, cannot exceed the zone duration,
   last at most 24 hours, expire without effect and never bypass safety gates.
3. **Preview/confirm and verified effect.** A closed preview binds live account,
   policy, plan, valve and state revisions to a 60-second-or-shorter confirm
   window. The worker receives no credential through this contract. Success
   requires a newer exact closed-valve readback with verified flow inside the
   planned water tolerance. Missing acknowledgements remain `unknown` and the
   same request is never dispatched automatically again. A bounded HMAC-backed
   audit chain detects changed payloads, links and heads.

## Evidence and remaining gates

The focused pytest suite covers deterministic budget allocation, price math,
rain/override behavior, all hard safety gates, override expiry, stale scope,
preview/confirm, flow and lost-ACK readback, idempotency and audit tamper checks.
This foundation does not register HTTP routes, persist preview/receipt state
across restart, implement Home Assistant or valve-vendor workers, provide the
Android Client E2E, or prove a real valve/flow meter. Those F49 gates remain open,
so progress stays **18/125 (14.4%)** and selected-feature acceptance stays
**0/63 (0.0%)**.
