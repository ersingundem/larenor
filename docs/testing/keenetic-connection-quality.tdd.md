# Keenetic connection quality widget — TDD evidence

## User journey

A tablet dashboard editor can add one read-only Keenetic card that shows current internet reachability, the selected WAN interface address, measured receive/send rates labelled as download/upload only when fresh gateway evidence matches, and router uptime.

## RED

- `27539bf`: presentation, controller, picker and persistence contracts failed to compile because `KeeneticMetricKind.connectionQuality` did not exist.
- `9dfb11f`: the picker contract failed with `Expected: <3>, Actual: <2>`, proving the combined five-line card did not reserve enough dashboard height.

## GREEN

The implementation appends the persisted enum value, requires a current inventory-backed WAN selection, expands the visible card demand into the existing internet/traffic/resource reads, shares the existing foreground controller and keeps the transport read-only. Partial-source failures remain visible and the first counter sample remains unknown until a valid interval exists.

Validation on 2026-09-10:

- Focused presentation/controller/UI/persistence suite: 45 passed.
- Keenetic feature, persistence and Direct/Core boundary suite: 224 passed.
- Focused Flutter analyze: no issues.
- Android backup exclusions and CI trust policy: passed.
- Focused changed-production line coverage: 588/658, 89.4%.

## Remaining acceptance boundary

Tests use the existing deterministic Keenetic RCI fixtures. A physical tablet and the user's router still need read-only acceptance to confirm the selected WAN interface name and the router model's exact counter cadence; no live-router result is claimed here.
