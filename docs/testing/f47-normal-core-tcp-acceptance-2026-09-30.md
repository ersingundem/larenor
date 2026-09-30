# F47 normal Client/Core/provider acceptance — 2026-09-30

## Production defect closed

The normal Core can hold both an `evcc` service and an authenticated Home
Assistant service for F47. The Flutter service wire model omitted the `evcc`
kind, so listing those real services rejected the entire response as
`invalid_response`. The energy-priority controller consequently showed no
Fronius setup candidates even though both providers were correctly configured.

`ServerServiceKind.evcc` now decodes the Core wire kind and admits only the
same API-key credential form that Core supports. No provider token or endpoint
is logged or returned by the acceptance runner.

## Actual boundary

`server/tests/support/f47_flutter_acceptance.py` starts:

- an owned HTTP evcc provider exposing the authenticated fixed `GET /api/state`;
- an owned authenticated Home Assistant HTTP/WebSocket provider exposing only
  the fixed entity/device registry reads, the exact Fronius reserve number
  state, and `number.set_value`;
- the production `create_app` Core over a real Uvicorn TCP listener; and
- the production Flutter `ServerAccountController`, `CoreEnergyPriorityApi`,
  and `EnergyPriorityController`.

The first Core/Client lifetime discovers the real Home Assistant service,
persists the registry-verified Fronius source, reloads the evcc battery plan,
and confirms one 40% reserve mutation with causal state readback. A fresh Core
and Flutter process then reads the durable binding and plan. It creates a real
Home Resource revision change after preview; confirmation of the stale preview
fails before provider I/O. The runner requires exactly one Home Assistant POST
across both lifetimes.

The fixture follows evcc's documented `/api/state` and `evcc_`-prefixed bearer
key contract: <https://docs.evcc.io/integrations/rest-api/>. Home Assistant's
REST API defines bearer-authenticated state reads and service calls:
<https://developers.home-assistant.io/docs/api/rest/>. The fixture does not
stand in for a physical inverter, battery, forecast source, or household
network.

## Focused evidence

```text
server/.venv/bin/python server/tests/support/f47_flutter_acceptance.py
  two Flutter phases passed; exactly one owned HA mutation

server/.venv/bin/python -m pytest -q \
  server/tests/test_f47_energy_priorities_api.py \
  server/tests/test_f47_evcc_battery_binding.py \
  server/tests/test_f47_fronius_reserve_control.py \
  server/tests/test_f47_solar_battery_priorities.py
  14 passed

flutter test --no-pub \
  test/features/server/server_services_test.dart \
  test/features/energy_priorities/energy_priority_core_loopback_test.dart \
  test/features/energy_priorities/energy_priority_controller_test.dart
  14 passed
```

Root independently repeated the actual two-lifetime runner, 14 Server tests,
and 14 Flutter tests. All passed without skipped acceptance phases.
Targeted analysis and `git diff --check` are clean. Exact-head broad CI and a
real inverter/battery/forecast acceptance remain open. No physical device was
read or mutated by this gate.
