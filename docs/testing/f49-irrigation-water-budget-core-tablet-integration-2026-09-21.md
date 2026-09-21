# F49 irrigation and water budget — Core and tablet integration

Status: **software recommendation path complete; live provider and physical valve acceptance pending**. Progress stays unchanged until those external gates close.

This integration depends on the provider-neutral F49 foundation in PR #293. The PR evolves that same branch after its exact-revision planner, bounded water budget and valve-effect safety contract; it does not duplicate the foundation.

## Three accepted criteria

1. **Authenticated, revision-bound recommendation read.** The admin-only Core endpoint binds the current account, session family, Core, home, policy, water budget, zone and soil-reading revisions. It returns a closed, secret-free schema containing verified area and plant labels, rain status, soil moisture and deterministic recommendations. Unknown capability, foreign authority, malformed labels or revision drift fails closed.
2. **Explicit no-command boundary.** The public response accepts only `read_only` or `manual_required` capability and reports `commandEndpointAvailable: false`; the HTTP router exposes GET only. Stale forecast, stale soil, leak, freeze, wind and exhausted-budget reasons remain visible per zone, and this slice never calls a valve or Home Assistant worker.
3. **Discoverable, lifecycle-safe tablet surface.** Energy exposes the EN/TR irrigation route. The 600/1280 logical-pixel surface is verified at 2x text with a 48 dp refresh action, TalkBack live status, keyboard-compatible controls and adaptive one/two-column cards. Account, Core, home, session, route, background or late-result changes clear retained data instead of presenting it as current.

## Automated evidence

- `uv run --project server --locked --no-sync python -m pytest -q server/tests/test_f49_irrigation_water_budget.py server/tests/test_f49_irrigation_http.py` — 8 passed.
- `flutter test test/features/irrigation_budget/irrigation_budget_http_test.dart test/features/irrigation_budget/irrigation_budget_client_test.dart` — 7 passed.
- Targeted Flutter analyze, Python compile, security policy, execution queue, progress, diff, merge-tree and redacted secret scan are required before publication.

## Remaining manual and provider gates

- Bind live Home Assistant soil sensors, weather/forecast sources, flow meters and named garden areas, then validate their units and retained timestamps.
- Add a supported valve capability adapter only behind a separate preview/confirm/readback journey; this integration intentionally provides no remote write route.
- Exercise Huawei tablet and Samsung DeX resizing, background/resume, keyboard and TalkBack behavior on physical devices.
