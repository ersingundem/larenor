# F59 workshop intent retention evidence — 2026-10-01

## Defect and RED

`WorkshopService.confirm` rejected every new command after `workshop_intents` reached the production `MAX_INTENTS = 10_000` limit. Applied terminal results were retained forever, so ordinary confirmed pause/cancel use eventually made the workshop permanently return `workshop_limit_reached`, including after Core restart.

The focused normal-Core HTTP regression created one genuine confirmed provider effect through the production preview/confirm path, derived authenticated historical rows from that receipt inside one bounded SQLite transaction, restarted the normal Core application at the true 10,000-row limit, and attempted one new confirmation. Before the repair it returned HTTP 409 with `workshop_limit_reached`.

The seed does not claim 10,000 provider writes and never marks an unobserved effect applied. Every seeded row is derived from the genuine applied receipt, has a distinct intent/command identity and readback, and is sealed with the production intent/effect HMAC functions.

## Retention contract

Capacity recovery runs inside the existing confirmation transaction before any provider write. It validates every workshop printer, intent and effect envelope, every parent relation, effect chronology, and the causal fields of applied readback before deleting anything.

It may delete only an intent graph that is older than the inclusive 24-hour replay boundary and is either:

- a terminal `applied` effect with causal readback; or
- a legacy intent with no effect, which proves no provider dispatch was recorded.

It preserves the newest current intent for every printer, all receipts at exactly or inside the 24-hour replay window, and every `unknown` effect. The `unknown` state includes the durable pre-dispatch reservation and all uncertain/readback-mismatch outcomes, so those operations are never replayed to recover capacity. If protected records consume the limit, the request still fails with `workshop_limit_reached`.

Effects are deleted before intents for foreign-key safety. Any validation or SQLite failure rolls the whole transaction back. The configured caps and schemas are unchanged.

## Focused evidence

`server/tests/test_f59_workshop_retention.py` proves:

- true 10,000-row capacity recovery across normal Core restart;
- exactly one new provider dispatch after recovery and no dispatch for seeded history;
- current-intent and inclusive 24-hour replay retention;
- exact recent request replay without another provider call;
- indefinite unknown-effect quarantine at capacity;
- fail-closed intent/effect HMAC tamper handling with zero deletion;
- rejection of a correctly resealed but causally mismatched applied child readback; and
- transactional restoration of both parent and effect after an injected delete failure.

The existing Core and owned HTTP provider suites were rerun with the retention tests, confirming that real OctoPrint/Moonraker HTTP request behavior and provider write semantics remain unchanged.

## Result

Command:

`cd server && uv run pytest -q tests/test_f59_workshop_printer_core.py tests/test_f59_workshop_http_provider.py tests/test_f59_workshop_retention.py --tb=short`

Result: 28 passed, 0 failed, 0 skipped.

`uv run python -m py_compile larenor_server/workshop/service.py tests/test_f59_workshop_retention.py` and scoped `git diff --check` also passed.

Root independently verified the live working-tree source with `PYTHONPATH=server server/.venv/bin/python -m pytest server/tests/test_f59_workshop_printer_core.py server/tests/test_f59_workshop_http_provider.py server/tests/test_f59_workshop_retention.py --tb=no -q`: exit 0, 28 passing cases, no failure or skip marker. Private log: `/private/tmp/larenor-f59-retention-root.log`. This does not claim hosted CI or physical printer acceptance.
