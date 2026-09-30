# F33 cooking assistant normal-Core acceptance — 30 September 2026

## Production path

`server/tests/support/f33_flutter_acceptance.py` starts the ordinary packaged
`create_app` composition behind a real loopback Uvicorn TCP listener. The
production Flutter account, pantry, cooking-session and ingredient-deduction
APIs then perform the following sequence:

1. log in as the synthetic administrator through HTTP;
2. receive a real pantry lot, create a cooking session and advance its exact
   recipe/session revision;
3. derive the Client idempotency key, atomically deduct the ingredient through
   normal Core and prove a duplicate request does not consume twice;
4. write an oven timer with `SharedPreferencesCookingTimerStore`, retire the
   first controller and restore the exact deadline with a new controller;
5. stop Core, rebuild normal Core from the same database and vault, log in with
   a new Client instance, and read the retained session, pantry quantity and
   deduction receipt;
6. replay the exact deduction after restart and prove the pantry revision and
   quantity remain unchanged.

The fixture owns only synthetic local Core state. It does not claim appliance
control, recipe correctness, physical ingredient measurement or food-safety
validation.

## Defects reproduced and repaired

The first real TCP run exposed three production blockers that seam tests did not
exercise:

- `PantryStockService._mutate` held `BEGIN IMMEDIATE` and then opened a second
  write transaction for rate limiting. Every pantry mutation waited for the
  15-second busy timeout and returned HTTP 503. Rate-limit reservation now
  finishes before the pantry transaction, while session authority is still
  checked inside the mutation transaction.
- authenticated pantry JSON stored receipt `allocations` as an array, but the
  strict restore model accepted only a tuple. The first later read failed with
  HTTP 503. Restore now converts only that exact bounded JSON array before
  strict receipt validation.
- Flutter placed ingredient rows directly in the idempotency hash's outer
  array, while Core hashes the documented nested item array. Every real
  deduction returned `idempotency_conflict`. The Client now emits the same
  canonical structure as Core, with a fixed digest regression vector.

## Focused evidence

```text
PYTHONPATH=server server/.venv/bin/python -m pytest -q \
  server/tests/test_f33_cooking_normal_core.py \
  server/tests/test_pantry_stock_contract.py \
  server/tests/test_f33_cooking_session.py --tb=short
7 passed

flutter test \
  test/features/cooking_assistant/ingredient_deduction_controller_test.dart
5 passed

PYTHONPATH=server server/.venv/bin/python \
  server/tests/support/f33_flutter_acceptance.py
prepare phase: 1 passed
restart phase: 1 passed
```

The named runner is the combined Client→normal Core gate. The broader focused
Flutter directory remains a separate UI/controller regression gate; hosted CI
and manual large-screen/timer-notification checks remain delivery evidence,
not prerequisites for the software path proved here.
