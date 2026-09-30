# F49 Home Assistant irrigation source — 2026-09-30

## Delivered contract

The normal Core now creates an authenticated Home Assistant irrigation source
provider. An administrator can bind exactly one encrypted Home Assistant
service revision and configure one weather entity, one moisture leak entity,
one daily water utility meter, and up to 32 valve/soil-moisture zone pairs.
Each zone is bound to an exact encrypted Home Resource room ID and room
revision. The policy uses that real room reference as its area identity and
reads the room label from the registry; the source cannot supply an unrelated
display area. The authenticated `home_resource_state.revision` is the
authority's home revision.
The source settings use compare-and-swap revision updates and an HMAC envelope
bound to the Core and home IDs. Credentials stay in the existing encrypted
service store and never enter this table or an HTTP response.

Each snapshot reads only fixed packaged routes:

- `GET /api/states/<configured-entity-id>` for weather, leak, daily water,
  soil moisture, and valve observations;
- `POST /api/services/weather/get_forecasts?return_response` with an exact
  configured weather entity and `type=hourly` for forecast response data.

The transport has a five-second request deadline, a 64 KiB response limit,
no redirect, cookie, proxy, or retry behavior. JSON rejects duplicate keys,
non-finite numbers, unexpected content types, and oversized structures.
Current actor, session family, account revision, source CAS revision, and
encrypted service revision are revalidated after upstream I/O. The global
home-resource revision and every referenced room revision are also checked
before and after I/O, so room deletion, replacement, or rename discards the
late observation.

The projection accepts only documented Home Assistant units and classes:
moisture `%`, weather `°C` / `m/s` / `mm`, a moisture binary sensor, and a
daily water meter in liters with a current reset window no longer than 24
hours. Missing, stale, malformed, over-budget, or changed observations fail
closed. Provider snapshot hashes form bounded content revisions; they are not
synthetic upstream counters.

## OpenSprinkler verified control

Home Assistant's generic valve contract exposes explicit
`valve.open_valve` and `valve.close_valve` actions and observable valve states,
but it does not promise a bounded run duration, delivered-flow evidence, or a
causal command receipt. The Home Assistant source therefore remains read-only.

An administrator can separately bind one OpenSprinkler 2.2.1 controller and an
exact, unique station index for every current irrigation-zone revision. The
controller URL and lowercase MD5 password digest are encrypted with an
AEAD domain key and never returned by the metadata endpoint. Updating the
binding requires the current source revision, every current zone revision, and
the controller metadata revision when replacing an existing binding. The
client deliberately leaves endpoint, password, station, entity, room, flow,
and duration inputs blank for a new binding; it never displays an existing
endpoint or digest and does not invent configuration values.

`verified_control` is exposed only after live fixed-endpoint reads prove the
expected firmware build and controller shape, an enabled controller, no active
or queued overlapping station, no configured master station, a standard and
enabled target station, and a positive configured liters-per-flow-pulse value.
The executor uses only:

- `GET /jo`, `/jn`, `/jc`, and `/js` for options, station attributes,
  controller status/flow counters, and exact station state;
- `GET /cm` with an explicit station, `en=1`, bounded `t`, and `qo=1` for one
  timed manual run; or `en=0` and `ssta=0` for an explicit stop.

Before the only mutating request, the command and its pre-read boot time,
device time, last-run tuple, flow counter, pulse conversion, binding revision,
and station are durably moved to `dispatching`. A lost acknowledgement or
process restart performs readback reconciliation only and never resends the
mutation. An applied receipt requires the same boot, an isolated manual
program-99 run for the exact station and duration, a changed exact last-run
tuple, a closed/idle final state, and a positive flow-pulse delta. Delivered
milliliters are calculated from that actual counter delta; the configured
zone flow remains a separate estimate and is used only for plan bounds.
Because OpenSprinkler exposes one combined flow sensor, any concurrent or
queued station makes attribution unsupported and fails closed.

The full account/session/home authority and controller/source binding are
revalidated before and after device I/O. A late authority change discards the
applied readback as unknown. The timed firmware command is still retained in
the durable command journal, so it cannot be replayed after that loss of
authority.

## Official sources

- [Home Assistant REST API](https://developers.home-assistant.io/docs/api/rest/)
  documents authenticated entity-state reads, action calls, response data via
  `return_response`, and the `weather.get_forecasts` REST example.
- [Home Assistant Valve](https://www.home-assistant.io/integrations/valve/)
  documents valve states and the explicit open/close actions.
- [Home Assistant Weather](https://www.home-assistant.io/integrations/weather/)
  documents weather units and the `weather.get_forecasts` response fields.
- [Home Assistant Sensor entity](https://developers.home-assistant.io/docs/core/entity/sensor/)
  documents moisture `%`, water/volume totals, `total` /
  `total_increasing`, and reset semantics.
- [Home Assistant Utility Meter](https://www.home-assistant.io/integrations/utility_meter/)
  documents daily reset cycles for water-source sensors.
- [OpenSprinkler firmware 2.2.1 API](https://opensprinkler.github.io/OpenSprinkler-Firmware/2.2.1/221_5_api/)
  documents the password-digest query contract, `/jo`, `/jn`, `/jc`, `/js`,
  `/cm`, manual program ID 99, timers, last-run data, and flow counters.
- [OpenSprinkler firmware 2.2.1 manual](https://opensprinkler.github.io/OpenSprinkler-Firmware/2.2.1/221_6_manual/)
  documents the flow-pulse conversion and that one sensor measures combined
  controller flow, which is why overlapping station runs are rejected.

## Focused evidence

No real home or device write was performed. The fixture exercises the normal
HTTP routes through Core, encrypted source/controller storage, exact Home
Assistant and OpenSprinkler request paths, source/controller CAS conflicts,
service and room revision drift, durable process-loss/lost-ack recovery,
single dispatch, actual measured-flow receipts, strict Flutter parsing, and
late account-revision rejection.

```text
cd server
.venv/bin/python -m pytest -q \
  tests/test_f49_irrigation_water_budget.py \
  tests/test_f49_irrigation_http.py \
  tests/test_f49_home_assistant_provider.py \
  tests/test_f49_opensprinkler_executor.py

21 passed

cd ..
flutter test test/features/irrigation_budget
flutter analyze lib/features/irrigation_budget test/features/irrigation_budget
```

## Socket-send authority review

The normal provider supplies a full account/session/source/policy guard to both
run and stop. Every controller request invokes it before transport construction,
in the transport's `before_send`, and after response receipt, and re-reads the
exact sealed controller/station binding. Loss of authority after the final
pre-read cannot send `/cm`. The durable `dispatching` intent is retained and
subsequent reads reconcile without resending. A dedicated regression revokes
authority at socket send and proves both zero mutation and zero replay.

The fully unmodified Flutter Client→normal Core→TCP HA/OpenSprinkler acceptance
runner and exact-head CI remain open. Adapter transport fixtures prove the
software command contract and do not establish physical installation acceptance.
