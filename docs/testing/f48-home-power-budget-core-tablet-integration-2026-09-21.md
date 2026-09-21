# F48 home power budget — Core and tablet integration

Status: **software recommendation path complete; live provider and physical switching acceptance pending**. Progress remains **22/125 selected features** and **0/63 expansion features** until the external gates below close.

## Three accepted criteria

1. **Exact, authenticated Core projection.** The admin-only endpoint binds account, Core, home, session, meter, tariff, load registry, grid limit, override and plan revisions. Meter and tariff observations must be current and verified. Startup validates the HMAC audit chain inside the outer database transaction; the migration uses only `connection.execute` and does not commit independently.
2. **Deterministic, bounded recommendations with no hidden write.** Grid overage becomes a stable priority-ordered list of noncritical, controllable loads and exact load revisions. Critical loads, hold windows, active manual overrides, stale measurements and safety-limit violations fail closed. The public route exposes only `read_only` or `manual_required`, explicitly reports that no command endpoint exists, and never invokes the relay/Home Assistant worker. Lost-ACK/no-replay command semantics remain in the foundation for a later verified capability adapter.
3. **Tablet and lifecycle integrity.** The Energy screen exposes the EN/TR power-budget route. Its 600/1280 logical-pixel surface is verified at 2x text with 48 dp controls, TalkBack live status and keyboard-compatible actions. The controller binds the exact signed-in session and route generation; account, Core, home, navigation, background or late-result changes clear the snapshot rather than presenting retained data as current.

## Automated evidence

- `uv run --project server --locked python -m pytest -q server/tests/test_f48_home_power_budget.py server/tests/test_f48_power_budget_http.py` — 5 passed.
- `flutter test test/features/power_budget/power_budget_client_test.dart test/features/power_budget/power_budget_http_test.dart` — 6 passed.
- Targeted Flutter analyze, Python compile, security policy, execution queue, progress, diff and redacted secret scan are required before the PR head is published.

## Remaining manual and provider gates

- Calibrate a real main meter and tariff adapter against retained readings.
- Verify a supported Home Assistant or relay capability, then add a separate preview/confirm/readback endpoint and explicit user confirmation. This PR deliberately provides no remote write path.
- Exercise Huawei tablet and Samsung DeX resize, background, keyboard and TalkBack behavior on physical devices.
