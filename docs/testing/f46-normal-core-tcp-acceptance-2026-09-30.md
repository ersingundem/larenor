# F46 actual EV Client/Core/evcc acceptance

The named gate is `server/tests/support/f46_flutter_acceptance.py`. It starts
the ordinary `create_app` Core behind Uvicorn TCP and an owned synthetic evcc
TCP service. It configures the normal service and explicit admin current-control
authority, with a bounded accepted tariff/power window. Those accepted inputs
are fixture setup; this gate does not claim a live utility tariff feed.

The production Flutter account and `AccountEvChargingGateway` then:

1. authenticate, discover the actual evcc charger, and parse its negative tariff;
2. preview the 16→8 A adjustment and confirm it through normal Core;
3. receive an uncertain receipt after the owned upstream applies the command
   but loses its HTTP ACK;
4. repeat the same command identity without a second upstream POST, then obtain
   verified target/observed 8 A through the normal readback endpoint;
5. restart Core from the same database/vault and start a fresh Flutter process,
   revalidate the retained synthetic session family through production account
   initialization, and read/replay the durable verified receipt;
6. reject a new command locally after route authority retires.

The Python runner independently checks exactly one upstream POST, an immediate
fresh `/api/state` GET before dispatch, and the actual retained upstream 8 A
setpoint. Only the owned listener port changes after restart; no Core API or
provider runtime is replaced by a fake response server.

Root evidence on 2026-09-30:

```text
PYTHONPATH=server server/.venv/bin/python server/tests/support/f46_flutter_acceptance.py
confirm phase: 1 passed
restart phase: 1 passed

PYTHONPATH=server server/.venv/bin/python -m pytest -q \
  server/tests/test_f46_ev_charge_planner.py \
  server/tests/test_f46_ev_charge_http.py \
  server/tests/test_evcc_runtime_provider.py \
  server/tests/test_f46_evcc_production_loopback.py --tb=short
26 passed

flutter test --no-pub test/features/ev_charging/ev_charging_core_loopback_test.dart \
  test/features/ev_charging/ev_charging_route_test.dart \
  test/features/ev_charging/ev_charging_screen_test.dart
11 passed

flutter analyze test/features/ev_charging/ev_charging_normal_core_test.dart
No issues found
```

The provider endpoint contract was checked against the [pinned official evcc
HTTP source](https://github.com/evcc-io/evcc/blob/077c093e5fdc375a9f2b1bc360b4d7ba38eaae46/server/http.go).
The previous [production recovery gate](f46-evcc-production-recovery-2026-09-30.md)
still covers pre-dispatch drift and no-write rejection.

This is focused software evidence. Broad exact-commit CI, physical EV charger
acceptance, actual tariff-provider quality, and target hardware remain separate
gates. The queue moves to `awaiting_ci`; accepted completion counters do not rise.
