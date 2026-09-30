# F46/F48 evcc provider contract

This slice pins its upstream interpretation to evcc commit
[`077c093e5fdc375a9f2b1bc360b4d7ba38eaae46`](https://github.com/evcc-io/evcc/tree/077c093e5fdc375a9f2b1bc360b4d7ba38eaae46).
The adapter is deliberately narrow because evcc documents `GET /api/state` as
its internal UI state with **no compatibility promise**; fields may change or
disappear between releases. See the official
[`/state` OpenAPI operation](https://github.com/evcc-io/evcc/blob/077c093e5fdc375a9f2b1bc360b4d7ba38eaae46/server/openapi.yaml#L1073-L1095)
and generated
[`State` schema](https://github.com/evcc-io/evcc/blob/077c093e5fdc375a9f2b1bc360b4d7ba38eaae46/server/openapi.state.yaml#L4-L15).

## Read contract

`EvccHttpReader` performs one bounded `GET /api/state` relative to the configured
evcc origin/base path. It uses `ServiceTransport`, whose
transport contract has no redirect, proxy, retry, cookie jar, or ambient
authentication behavior. A bearer header is sent only when a long-lived
`evcc_...` API key was explicitly supplied.

The projection requires all of these upstream facts:

- `grid.power`, using evcc's documented sign rule: positive is grid import and
  negative is feed-in. The adapter exposes `max(0, power)` as import, never a
  guessed load. The official sign convention is documented in
  [Meters](https://docs.evcc.io/en/reference/configuration/meters/#signs-and-directions).
- `tariffGrid` and `currency`; the price is converted from configured-currency
  units/kWh to integer micro-units/kWh.
- exactly one root entry in `circuits`, with a positive integer `maxPower` as
  the physical authority ceiling.
  The field is defined by the official
  [`Circuit` schema](https://github.com/evcc-io/evcc/blob/077c093e5fdc375a9f2b1bc360b4d7ba38eaae46/server/openapi.state.yaml#L484-L516).
  If HEMS reports `dimmed: true`, the lower positive
  `hems.status.maxConsumptionPower` is carried separately as the effective
  input limit. evcc documents that external
  limits cap the root circuit in
  [External Limit](https://docs.evcc.io/en/external-limit/).
- one to sixteen `loadpoints`, using only actual `chargePower`, `priority`,
  connection/charging state, current SoC, configured maximum current, active
  phases, title, and the connected vehicle's configured capacity. The official
  fields are defined by the
  [`Loadpoint` schema](https://github.com/evcc-io/evcc/blob/077c093e5fdc375a9f2b1bc360b4d7ba38eaae46/server/openapi.state.yaml#L746-L1100).

Missing limits, missing tariffs, duplicate JSON keys, non-finite numbers,
fractional values where the Larenor model requires integers, oversized bodies,
unexpected media types, or schema drift fail closed. Revisions are positive
content versions of the exact upstream fact subsets; they change only when the
corresponding observed facts change.

An observed import or EV load may already exceed the effective HEMS limit; that
overage remains a real F48 input instead of being relabeled as a protocol
failure. A load above the physical root ceiling still fails closed. Dynamic
prices are preserved as signed integer micro-units/kWh in both F46 and F48;
negative prices are never clamped or rewritten.

The normal Core composition resolves exactly one stored `evcc` service whose
encrypted record has passed the fixed read-only identity probe. Zero, multiple,
unverified, or malformed evcc records leave the feature unconfigured. The
selected service id/revision and the authenticated Larenor user's live account
and session-family revisions are checked on each projection. Core and home use
the authenticated immutable context schema revision. F48 is then installed as
the normal read-only power-budget provider without exposing the private URL or
API key in `repr`. Selection occurs at each request boundary, so a newly
verified service is available without a process restart. Each request uses a
new immutable binding; endpoint/revision drift and a second verified evcc
record both fail closed before another provider effect.

## Authentication and permissions

evcc defines cookie authentication and a bearer API key in its
[OpenAPI security schemes](https://github.com/evcc-io/evcc/blob/077c093e5fdc375a9f2b1bc360b4d7ba38eaae46/server/openapi.yaml#L2209-L2223).
The key is primarily the authenticated access mechanism for protected
configuration/database APIs. In the server source, `/api/state` and the
loadpoint routes are registered on the ordinary API router, while
`EnsureAuthHandler` is attached to the API-key and configuration route groups:
[route registration](https://github.com/evcc-io/evcc/blob/077c093e5fdc375a9f2b1bc360b4d7ba38eaae46/server/http.go#L148-L346).

Consequently, an evcc API key is not treated as proof that loadpoint control is
authorized. Larenor still binds every projection to its current actor/session,
core/home revisions, account revision resolver, private service id, and service
revision. The F48 provider advertises `read_only`; its loads are never marked
controllable, and its worker methods cannot dispatch.

## F46 plan boundary

evcc officially exposes:

- `GET /loadpoints/{id}/plan` for the current upstream plan;
- `POST /loadpoints/{id}/plan/energy/{energy}/{timestamp}` for one fixed energy
  target when a vehicle without SoC is connected;
- SoC plan operations and plan previews; and
- separate setpoint operations such as
  `POST /loadpoints/{id}/maxcurrent/{current}`.

These operations are defined in the official
[loadpoint OpenAPI paths](https://github.com/evcc-io/evcc/blob/077c093e5fdc375a9f2b1bc360b4d7ba38eaae46/server/openapi.yaml#L449-L650).
They do not accept Larenor F46's tuple of individually selected current slots,
and their GET response does not echo Larenor's plan hash. Treating a successful
POST or an unrelated evcc plan as that hash would create a false receipt.

An eventual control adapter has exact per-effect readback options, but it needs
a durable scheduler rather than the current immediate all-slots gateway:

- a current limit can be written with
  `POST /api/loadpoints/{id}/maxcurrent/{current}` and checked in a fresh
  `/api/state` at the same index through `maxCurrent`;
- a charge mode can be written with
  `POST /api/loadpoints/{id}/mode/{mode}` and checked through the fresh `mode`;
- a static energy or vehicle-SoC target can be checked with
  `GET /api/loadpoints/{id}/plan`, whose response contains evcc's `planId`,
  target time, duration, power, and rate windows.

None of those reads proves that every future Larenor current slot has executed.
A production write path must persist the accepted Larenor schedule, dispatch
only the slot current at execution time, bind it to the exact service revision
and loadpoint index, and record each fresh upstream setpoint readback. Until
that scheduler exists, Core supplies no charger gateway and never returns a
verified F46 command receipt.

The delivered F46 projection is planning-only and read-only. Charger facts come
from evcc. Future tariff, solar-surplus, and F48 home-budget facts enter normal
Core through the admin-only
`PUT /api/v1/ev-charging/{core}/{home}/providers/evcc/{service}/energy-windows`
acceptance route. The request binds the exact selected service revision, uses
CAS on `expectedAcceptedRevision`, carries signed tariff values and the three
source revisions, and is limited to 192 ordered slots and a 48-hour horizon.
Records are HMAC authenticated in private SQLite storage and checked during
startup reload. Source observations older than five minutes and expired records
are unavailable rather than silently refreshed.

The admin-only `GET` on the same route returns only the accepted revision, its
bound service revision, the current selected service revision, and one of
`missing`, `current`, `stale`, `expired`, or `service_revision_changed`. This
allows CAS replacement after service-revision drift without returning future
slot contents, prices, headroom, or credentials.

This explicit acceptance step is required because neither upstream offers a
generic future household-load or headroom contract. Home Assistant's official
`energy/solar_forecast` command returns solar production as `wh_hours`
([websocket handler](https://github.com/home-assistant/core/blob/ef2bc757e639324e3e106c125016a0542fd1d9a9/homeassistant/components/energy/websocket_api.py#L185-L235),
[type](https://github.com/home-assistant/core/blob/ef2bc757e639324e3e106c125016a0542fd1d9a9/homeassistant/components/energy/types.py#L9-L16)).
Energy preferences identify current power and price statistics
([energy data types](https://github.com/home-assistant/core/blob/ef2bc757e639324e3e106c125016a0542fd1d9a9/homeassistant/components/energy/data.py#L28-L179)),
while `recorder/statistics_during_period` returns recorded aggregate periods
([recorder command](https://github.com/home-assistant/core/blob/ef2bc757e639324e3e106c125016a0542fd1d9a9/homeassistant/components/recorder/websocket_api.py#L217-L311)).
Past consumption is not relabeled as future load, solar production is not
relabeled as surplus, and the current meter value is not repeated into future
slots. With a fresh accepted record, F46 advertises `canPlan: true` and
`canControl: false`; without one, it stays unavailable.
