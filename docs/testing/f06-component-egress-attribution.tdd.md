# F06 component egress attribution TDD evidence

## Decision boundary

Android explanation plus Home Assistant, Keenetic and Proxmox histories do not
close F06. The feature acceptance requires a real rule identity in the same
user/rule/service/command/result trace. Larenor does not yet have a rule engine,
and the current Home Assistant attribution contract only accepts `core_api` or
`unknown`. This slice does not infer a rule from timestamps or nearby events,
and the F06 progress counters remain unchanged.

## Accepted slice

This slice covers the existing component egress policy and service verification
commands:

1. Policy replacement and probe events carry one correlation ID, actor, exact
   service revision, and closed source/reason/command/result values. A probe's
   authorization and completion share the same trace.
2. The encrypted journal moves from schema v1 to v2 atomically. Existing events
   with no recorded command/result/service revision become
   `unknown/unknown/unknown`; current bindings or adjacent timestamps are never
   used to invent attribution.
3. The dedicated history endpoint rechecks the current administrator and exact
   service in the same database transaction, returns only that service's last
   20 events without grants or pinned addresses, and rejects corrupted storage
   during live reads and restart.

## RED and GREEN evidence

| Stage | Command | Result |
| --- | --- | --- |
| RED `adb198f8` | `PYTHONPATH=server server/.venv/bin/python -m pytest -q server/tests/test_f06_component_egress_attribution.py` | 3/3 expected failures: missing v2 attribution fields, migration and history route. |
| GREEN `b6cf6e39` | Same focused command | 3/3 passed. |
| Egress regression | Component egress, Proxmox/Keenetic egress worker and service probe suites | 77/77 passed. |
| Startup regression | Admin migration, Core context and daemon startup suites | 55/55 passed. |
| Static checks | `compileall` for the changed package and test, plus `git diff --check` | Passed. |

All remote behavior uses synthetic local transports. No Home Assistant,
Proxmox, Keenetic or other LAN service was contacted. F06 still requires a real
rule-origin command path, combined exact-main review and CI before its queue
item can be completed. Queue and selected feature counters stay `15/125` and
`0/63`.
