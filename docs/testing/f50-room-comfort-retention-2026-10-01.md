# F50 room-comfort retention evidence — 2026-10-01

## Scope

This slice closes the persistent-capacity failure in the production room-comfort
service. Every refresh creates a new, time-bound plan identity. The previous
implementation retained plans, previews, and dispatches forever, so an ordinary
installation eventually returned `comfort_limit_reached` permanently.

No Home Assistant device or household service was contacted by these tests.
The normal-Core HTTP fixture uses only synthetic room inputs and local SQLite.

## RED

Before the production change, this command executed the normal Core HTTP path:

```text
server/.venv/bin/python -m pytest -q server/tests/test_f50_room_comfort_retention.py -x
```

`test_normal_core_restart_recovers_after_more_than_maximum_plan_refreshes`
published 64 distinct plans, advanced the trusted test clock, restarted
`create_app(settings)`, and attempted the 65th publish. The expected `200` was
an actual `429 Too Many Requests`. This was the intended capacity defect, not a
fixture or authentication failure.

## Retention contract

Compaction runs inside the same `BEGIN IMMEDIATE` transaction that reserves new
capacity. Before any deletion it validates every bounded plan, preview, receipt,
and dispatch envelope and their parent relationships.

The service preserves:

- the current plan;
- every preview through its exact expiry boundary;
- every dispatching effect;
- every completed `unknown` effect;
- every effect whose receipt was not durably finalized;
- every plan and preview required by those effects; and
- terminal receipts for 24 hours from `completedAtMs`, inclusive at the cutoff.

It may remove expired unconfirmed previews, terminal histories older than that
replay window, their dispatch rows, and non-current plans no longer referenced
by a retained preview. Child rows are deleted before parents. If retained rows
still consume the limit, the operation returns `429` and the transaction rolls
back every tentative deletion.

The singleton current-plan pointer has no independent schema tag, so the service
derives currentness from an authenticated ordering invariant: a different new
plan must have a strictly later `created_at`, and the pointer must identify the
single newest HMAC-valid plan. Exact current-plan replay remains valid. Clock
regression, a different plan in the same millisecond, pointer rollback, a NULL
pointer with history, or ambiguous legacy timestamps fail closed rather than
selecting an unauthenticated row.

## GREEN

```text
server/.venv/bin/python -m pytest -q \
  server/tests/test_f50_room_comfort.py \
  server/tests/test_f50_room_comfort_http.py \
  server/tests/test_f50_home_assistant_executor.py \
  server/tests/test_f50_room_comfort_retention.py
```

Result: 32 passed, zero failures or skips.

```text
server/.venv/bin/python -m pytest -q \
  server/tests/test_f50_home_assistant_normal_core.py
```

Result: 1 passed, zero failures or skips.

The 16 focused retention tests prove normal-Core restart recovery beyond
`MAX_PLANS`, preview expiry recovery, exact expiry and receipt-cutoff boundaries,
recent replay, old receipt eviction without redispatch, current/unknown/
dispatching parent preservation, indispensable-capacity failure, transactional
rollback, plan/preview/dispatch tamper failure, strict timestamp ordering, and
startup rejection of forged or ambiguous current-plan pointers.

`python -m py_compile` for the changed Python files and `git diff --check` for
this three-file slice also completed without errors.

## Deliberate limits

The 24-hour receipt replay window is a bounded software retention guarantee.
`dispatching`, `unknown`, and not-yet-finalized effects are not aged out by this
window. If protected records alone fill a configured cap, the service stays
fail-closed until the evidence is resolved; it does not increase caps or discard
uncertain effect history.

Root independently repeated all five named files in one invocation: **33 passed,
zero failures or skips**. Broad final-HEAD CI is still required.
