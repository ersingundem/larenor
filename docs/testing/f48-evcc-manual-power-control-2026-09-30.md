# F48 evcc manual power-budget control

This slice turns the existing F48 recommendation into an explicitly confirmed
manual evcc control. It does not add a scheduler or automatic shedding. The
normal Core runtime already supplies the same sealed `EvccCurrentControl` to the
resolved evcc power-budget provider, so no alternate device path or injected
test-only provider is needed.

## Safety and authority

- A loadpoint is treated as critical and read-only unless an administrator has
  explicitly enabled its existing revision-bound current-control authority.
  A missing policy never becomes `critical=false`.
- Every preview is bound to fresh meter, tariff, load-registry, grid-limit and
  loadpoint revisions. Only connected and currently charging loadpoints with
  exact upstream `minCurrent`, `maxCurrent`, `phasesActive`, and measured
  `chargeVoltages` are controllable. No nominal 230 V fallback is invented.
- Planning respects evcc's observed priority and never reduces a load below
  `minCurrent × phasesActive × measured voltage`. Critical or unauthorized
  loads are excluded even when that leaves the overage unresolved.
- Core writes an HMAC-protected `dispatch_reserved` event before the first
  upstream request. A timeout or unknown acknowledgement becomes `uncertain`;
  the same request key returns the durable receipt and does not send again.
- Each affected load receives a durable five-minute hold starting at dispatch.
  The hold survives restart and blocks immediate oscillating commands even when
  an acknowledgement was lost.

## Upstream exchange

Immediately before each write, the worker re-reads `/api/state`, verifies the
service binding, explicit loadpoint authority, unchanged target loadpoint
revision and real electrical bounds, and verifies any earlier effects in the
same multi-load command. It then sends the documented fixed route
`POST /api/loadpoints/{id}/maxcurrent/{current}`. A JSON 200 response is not the
receipt: causal readback requires a later `/api/state` to show both the exact
`maxCurrent` and `chargePower <= targetW` for every planned load.

The official evcc OpenAPI defines this endpoint and numeric response:
<https://github.com/evcc-io/evcc/blob/master/server/openapi.yaml>. The official
server registers the matching route and setter in
<https://github.com/evcc-io/evcc/blob/master/server/http.go>. evcc documents that
minimum charging power depends on current and phases, while its loadpoint
reference describes measured voltages and higher-number priority:
<https://docs.evcc.io/en/reference/configuration/loadpoints/>. Its load
management documentation also warns that the native feature is experimental
and that native circuit priority is not yet considered:
<https://docs.evcc.io/en/features/loadmanagement/>. Larenor therefore exposes
this bounded flow as manual confirmation and does not describe it as an evcc
automatic scheduler.

## TDD evidence

The initial RED run failed because `LoadState` had no minimum-power boundary:

```text
TypeError: LoadState.__init__() takes 8 positional arguments but 9 were given
```

After implementation, the focused server command was:

```text
server/.venv/bin/python -m pytest -q \
  server/tests/test_f48_home_power_budget.py \
  server/tests/test_f48_power_budget_http.py \
  server/tests/test_f48_evcc_power_control_loopback.py \
  server/tests/test_evcc_runtime_provider.py
```

Result: `23 passed`. The coverage includes minimum-current planning, critical
default behavior, explicit authority, revision and voltage failure closure,
durable unknown-ack non-replay, restart hold, exact idempotent receipt, normal
Core discovery, and a real numeric-loopback TCP exchange through the production
bounded HTTP transport with causal readback.

The broader related server selection
`test_evcc_*.py test_f46_*.py test_f47_*.py test_f48_*.py` passed `38/38`.
The existing power-budget and energy-priority Flutter controller, HTTP,
loopback, and screen selection passed `18/18`. This server environment does not
install the `pytest-cov` plugin, so the attempted `--cov` command was rejected
as an unknown pytest option; executable branch evidence remains in the focused
unit, Core integration, restart, and real-loopback tests above.
