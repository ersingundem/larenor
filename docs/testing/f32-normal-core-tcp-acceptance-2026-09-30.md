# F32 pantry stock real Client/Core acceptance

`server/tests/support/f32_flutter_acceptance.py` starts normal Core behind
Uvicorn TCP and uses the production Flutter account, pantry API and controller.
It receives two flour lots, consumes from the earliest expiry first, reconciles
the exact consume request, undoes the movement, and reads a previous receive
receipt after newer stock mutations. A separate Core and Client restart then
reads the retained two lots and replays the undo without double restoration.
The gate also rejects stale mutations and requests after route retirement.

The real path exposed a Client defect: Core correctly returned an old
idempotency receipt with its current stock snapshot, but `PantryMutation`
required equal revisions and rejected every such response. The parser now
allows a receipt revision no newer than the snapshot while binding its exact
request ID and operation kind. The Client keeps the latest balance and never
rolls back to an earlier snapshot. Focused regressions reject future, unrelated
request and wrong-operation receipts.

Root evidence:

```text
PYTHONPATH=server server/.venv/bin/python server/tests/support/f32_flutter_acceptance.py
mutate phase: 1 passed
restart phase: 1 passed

flutter test --no-pub test/features/pantry_stock/pantry_stock_receipt_contract_test.dart
4 passed

PYTHONPATH=server server/.venv/bin/python -m pytest -q \
  server/tests/test_pantry_stock_contract.py \
  server/tests/test_f33_cooking_normal_core.py \
  server/tests/test_f33_cooking_session.py --tb=short
7 passed

flutter analyze lib/features/pantry_stock test/features/pantry_stock
No issues found
```

The earlier F33 real-Core gate repaired pantry transaction and persisted JSON
receipt restore defects shared with F32; this gate exercises the pantry's own
Client/controller operations. The pure Server gate retains normalization,
bounded malformed inputs, FEFO, concurrent stale-CAS single winner and exact
undo/idempotency checks.

This evidence uses synthetic owned stock and Core only. Physical ingredient
quantities, barcode scanner hardware and tablet accessibility remain separate
manual evidence. Broad exact-commit CI is still required; completion counters
remain unchanged while F32 is `awaiting_ci`.
