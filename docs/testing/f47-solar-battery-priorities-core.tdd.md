# F47 solar and home-battery priorities acceptance

This package connects the fail-closed Core planning boundary to an authenticated
HTTP contract, a live evcc home-battery source, and a route-owned Android tablet
surface. Physical inverter mutation remains a separate gate: evcc's generic
battery-mode API cannot honestly satisfy the existing exact-watt command and
readback contract.

## Production source boundary

The normal Core composition now reads the official evcc `/api/state` battery
object. Capacity, SoC, power, per-device names and `controllable` flags come
from that fresh response. They are never supplied by the forecast payload.
An administrator must separately accept a sealed binding containing the exact
service revision, observed battery-catalog revision, backup reserve percentage,
and bounded charge/discharge limits. A service or battery-catalog change closes
the provider until a new binding is accepted.

The existing accepted energy-window record gained optional solar energy, home
load energy, and export tariff values. F46 remains compatible with old window
records, while F47 requires all three values and uniform contiguous 5–60 minute
slots. Missing or stale windows, missing battery data, incomplete electrical
facts, storage tampering, or revision drift return provider unavailable.

The live capability reports whether every bound evcc battery device advertises
external control, but remains `writable=false`. The official API describes
`POST /batterymode/{batteryMode}` as a mode applied to all controllable
batteries which resets after 60 seconds and must be refreshed. It has no target
power parameter. Treating that endpoint as proof that an exact requested watt
value was applied would be false. A supported inverter-specific adapter with a
durable intent and causal power readback is still required for mutation.

Primary-source evidence:

- [evcc OpenAPI state schema](https://github.com/evcc-io/evcc/blob/master/server/openapi.state.yaml)
  defines aggregate and per-device battery capacity, SoC, power and
  `controllable`, and states that `/api/state` has no compatibility promise.
- [evcc OpenAPI operations](https://github.com/evcc-io/evcc/blob/master/server/openapi.yaml)
  defines external battery mode and its 60-second reset, as well as long-lived
  bearer API-key authentication.
- [evcc battery interfaces](https://github.com/evcc-io/evcc/blob/master/api/api.go)
  distinguish battery SoC/capacity, controller support, SoC limit support and
  power-limit support. The latter two are not exposed by the state schema.
- [evcc site implementation](https://github.com/evcc-io/evcc/blob/master/core/site.go)
  shows that `prioritySoc` changes solar-allocation priority. It is not silently
  reinterpreted as Larenor's backup reserve.

Exactly three user acceptance criteria are in scope:

1. The authenticated Core endpoint returns production, consumption, tariff,
   battery and backup-reserve-percent inputs only when their exact Core, home,
   resource, provider and revision bindings are current. The deterministic plan
   is advisory and can never authorize an automatic inverter write.
2. A writable administrator must preview and explicitly confirm a bounded
   charge or discharge command. The Client reports success only after a separate
   exact receipt readback; stale account, session-family, route, lifecycle,
   input or inverter authority fails closed. The normal evcc source is
   read-only because its generic mode endpoint cannot apply an exact power.
3. The EN/TR tablet surface exposes the same plan and authority state at 600 and
   1280 logical pixels with 2x text, 48dp actions, TalkBack live status and
   Enter/Space keyboard activation. Backgrounding, route retirement or account
   change retires pending confirmation and drops late callbacks.

## TDD evidence

The original RED commit `91187368` failed collection because the Core package
did not exist. The integration RED commit `ef2f6251` required authenticated HTTP
and Android Client contracts. The live-source RED on 2026-09-30 failed
collection because `larenor_server.evcc.battery` did not exist. The resulting
normal-Core acceptance covers sealed binding creation, fresh battery facts,
reserve and forecast separation, read-only capability, stable snapshots inside
the 60-second command window, freshness renewal, and battery-catalog drift.
