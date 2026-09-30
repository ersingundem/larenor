# F47 solar and home-battery priorities acceptance

This package connects the fail-closed Core planning boundary to an authenticated
HTTP contract, a live evcc home-battery source, and a route-owned Android tablet
surface. The generic evcc battery-mode API cannot honestly satisfy an
exact-watt command and readback contract. A separately accepted Home Assistant
Fronius binding implements only the narrower control the official integration
actually offers: an exact minimum-reserve percentage.

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
value was applied would be false. Charge and discharge plan slots therefore
remain advisory and cannot be previewed through the Fronius adapter.

## Verified Fronius reserve control

The reserve binding accepts exactly one enabled `number` entity whose Home
Assistant entity-registry platform is `fronius`, whose unique ID ends in
`-modbus-battery_minimum_reserve`, and whose config entry and device agree with
one device-registry record identifying a Fronius model. The live state must
report an integer 0–100 percent number with min 0, max 100 and step 1. A Home
Assistant service revision, evcc battery-provider revision, registry identity,
sealed record or current reserve-policy change closes the write path.

Explicit confirmation records a sealed dispatch intent before the one allowed
`number.set_value` request. A successful receipt requires a fresh state whose
percentage is exact and whose `last_updated` is later than the pre-write state.
If the HTTP acknowledgement is lost, Core marks the intent uncertain. On a
later read or after restart it may reconcile a causally newer exact state, but
it never repeats the POST. A target that was already current is recorded as a
verified no-op without a service call.

The administrator surface lists only Core service records whose kind is Home
Assistant and whose latest verification state is authenticated. It reads the
current sealed binding revision, then submits that exact service revision,
battery provider revision and a syntactically bounded `number.*` entity to the
fixed binding endpoint. The Client never receives the Home Assistant token or
sends a registry command. A failed or acknowledgement-unknown binding write is
not retried; the surface requires a fresh Core read before another submission.

The published capability is `reserve_percent`: `canSetReserve=true`, while
`canCharge=false` and `canDischarge=false`. The adapter does not convert watts
from an operator envelope because Home Assistant does not expose the battery's
hardware maximum rate as a verified source. It does not claim that setting a
charge/discharge ceiling forces the physical direction or wattage.

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
- [Home Assistant Fronius documentation](https://www.home-assistant.io/integrations/fronius/#controlling-the-inverter-over-modbus)
  defines local Modbus reserve and power-limit entities, their percentage
  units, enable switches and the absence of absolute-watt settings.
- [Home Assistant Fronius number source](https://github.com/home-assistant/core/blob/dev/homeassistant/components/fronius/number.py)
  defines the exact `battery_minimum_reserve` entity key, 0–100 bounds, step 1,
  percent unit and device-read state after writes.

Exactly three user acceptance criteria are in scope:

1. The authenticated Core endpoint returns production, consumption, tariff,
   battery and backup-reserve-percent inputs only when their exact Core, home,
   resource, provider and revision bindings are current. The deterministic plan
   is advisory and can never authorize an automatic inverter write.
2. A writable administrator may preview and explicitly confirm the exact bound
   backup reserve. The Client reports success only after a separate exact
   receipt readback; stale account, session-family, route, lifecycle, battery,
   service or inverter authority fails closed. Charge/discharge power controls
   remain unavailable because neither evcc nor the supported Fronius path can
   apply and prove the requested absolute watt value.
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
reserve and forecast separation, stable snapshots inside the 60-second command
window, freshness renewal, battery-catalog drift, fixed Fronius registry
provenance, service-revision retirement, causal reserve readback, numeric
loopback HTTP and restart recovery without a second mutation.

## Final-function review follow-up — 2026-09-30

The Core adapter now re-reads actual Fronius entity/device registry provenance
when advertising control and immediately before the socket sends the mutation.
It also revalidates current authority around no-op and readback results. A new
regression changes the registered device identity between reservation and send:
the operation becomes unavailable/uncertain and no POST reaches the provider.
The five Fronius tests passed; the Flutter feature set passed 16 tests and
focused analyze. The broader F47/F48/evcc check found one active F46 normal
confirm failure; that separate source/charger repair is in progress.

These tests include adapter seams for evcc transport and Home Assistant registry.
They do not establish a fully unmodified Client→normal Core→TCP evcc/HA gate.
That combined acceptance and exact-head CI remain required before `done`.
