# F06 Proxmox power attribution TDD evidence

## Accepted guarantees

This slice closes three independent attribution guarantees for real Proxmox
power commands:

1. Preview, cancel, accepted, executing and final journal events carry the
   original request trace, actor, exact service revision, closed command/result
   fields, and a closed source/reason pair. No reason is inferred from nearby
   events.
2. An interrupted command recovered after restart is labelled
   `core_recovery/interrupted_after_restart` only when the service identity was
   recorded. Pre-attribution journal rows migrate as `unknown/unknown` with no
   invented service identity.
3. The attributed journal rechecks the exact current admin, Core, home and
   resource authority before and after reading. It returns only the selected
   resource, exposes no global event count, and rejects attribution deletion or
   modification through its HMAC-bound journal verification.

## RED and GREEN evidence

| Stage | Command | Result |
| --- | --- | --- |
| RED | `PYTHONPATH=server server/.venv/bin/python -m pytest -q server/tests/test_f06_proxmox_attribution.py` | 3 expected failures: the attributed endpoint and persistence contract did not exist. |
| GREEN | Same focused command | 3/3 passed, including restart migration and live/restart tamper rejection. |
| Proxmox regression | `PYTHONPATH=server server/.venv/bin/python -m pytest -q server/tests/test_proxmox_power_commands.py server/tests/test_proxmox_power_worker_ipc.py server/tests/test_proxmox_power_worker_runtime.py server/tests/test_proxmox_power_e2e.py server/tests/test_proxmox_target_discovery.py server/tests/test_f06_proxmox_attribution.py` | 88/88 passed. |
| Startup regression | `PYTHONPATH=server server/.venv/bin/python -m pytest -q server/tests/test_admin_migration.py server/tests/test_core_context.py server/tests/test_daemon_startup.py` | 55/55 passed. |
| Compile and diff | `python3 -m compileall -q server/larenor_server/proxmox_commands server/tests/test_f06_proxmox_attribution.py` and `git diff --check` | Passed. |

The RED specification is commit `44bd873b`; the production implementation is
commit `90c8d99a`. Tests use local SQLite databases and deterministic fake
providers/executors. They do not contact a Proxmox host.

## Progress boundary

This is one server-side part of F06. Android consumption, exact-main CI and the
remaining command sources are separate acceptance work. Queue and selected
feature counters remain `15/125` and `0/63` until the full F06 acceptance item
is complete.
