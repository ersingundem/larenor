# F51 real floor-plan Client/Core/HA acceptance — 30 September 2026

The named runner starts normal `create_app` over loopback Uvicorn TCP and an
owned HTTP Home Assistant fixture. The production Flutter account client logs
in and uses `FloorPlanAccountGateway`; no fake Core response server or injected
floor-plan gateway is used. The fixture is explicitly isolated from household
devices and accepts only the fixed synthetic switch state/service routes.

The first Client phase loads real registry room/resource candidates, saves
bounded floor/room/device geometry, vector walls and rotation with the actual
four-revision CAS contract, and repeats the exact request idempotently. It
reads the live switch projection through the normal HA binding, sends one
authorized action, and repeats that request without a second upstream POST.
The runner independently verifies exactly one provider mutation and its new
state. Renaming the resource invalidates the old editor revision; the Client
reloads the real catalog and repairs the target revision before saving again.
Retiring the route blocks subsequent editor reads.

The first Core is stopped and closed. A new normal Core is constructed from
the same private data directory and key, a second real Client process logs in,
and the saved layout revision, target revision, rotation and vector wall are
read again. No in-memory gateway result carries across that restart.

Executed gate:

```text
server/.venv/bin/python server/tests/support/f51_flutter_acceptance.py
2 separate Flutter Client phases passed; exactly 1 owned HA mutation

server/.venv/bin/python -m pytest -q \
  server/tests/test_f51_floor_plan_core.py \
  server/tests/test_f51_floor_plan_editor.py \
  server/tests/test_f51_floor_plan_http.py
9 passed

flutter test --no-pub \
  test/features/floor_plan/floor_plan_client_test.dart \
  test/features/floor_plan/floor_plan_core_loopback_test.dart \
  test/features/floor_plan/floor_plan_editor_test.dart
13 passed
```

The related tests cover malformed bounds, role/scope rejection, stale or
missing projections, editor conflicts, uncertain actions, retired routes and
the accessible inline/list alternative. Physical measurements, tablet touch
quality, real household HA and broad exact-HEAD CI remain separate gates.
This result supplements F51's `awaiting_ci` record and does not increase the
accepted queue or selected-feature counters.
