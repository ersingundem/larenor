# F37 normal Core expense correction acceptance — 2026-09-30

A correction is an immutable new encrypted record linked by `replacesId` to
one existing expense. Currency and payer remain fixed; admin or the original
payer can explicitly correct title, total and participant split. The old
record and recorded payments remain in history. Balances use terminal expenses
plus every payment, without currency conversion or a bank/payment operation.
Current ledger CAS prevents branching or silently overwriting another change.

The normal gate uses production Flutter account/API/controller, a normal
Uvicorn Core and its actual private SQLite/AES-GCM ledger. It creates a 1001
minor-unit expense, corrects it to 2001, proves exact command replay, records
500 minor units of payment, exports linked history, then restarts both Core and
Client over the same data directory. A further correction to 3001 preserves
the original and payment and projects only the current split. Exactly three
records/events exist before restart and four after the second correction;
ciphertexts contain no plaintext bill title. Retired routes cannot read/write.

## Independent review repairs

- Every read, including a missing receipt, rechecks current session and the
  exact ready-member revision after capturing the ledger. Ledger reads use a
  consistent database snapshot. Writes check authority inside the immediate
  commit transaction.
- Each visible historical row carries server-computed `superseded` metadata.
  A member removed from the new split sees the old expense as corrected without
  receiving the hidden replacement. A new participant may see a replacement
  whose predecessor is filtered out. Admin graphs must be complete, acyclic,
  single-branch and consistent; malformed graphs are rejected.
- Departed split participants appear as explicit removable rows in the editor.
  A disabled immutable payer has a clear explanation and no unusable edit
  action. EN/TR 600/1200 layouts at 2x text scale preserve correction history.
- Current membership identity is equality-only and bounded to `2^53-1`, so
  Flutter Web does not round it. Real Chrome proves the maximum JSON
  roundtrip/equality/hash and rejects `2^53`.
- CSV carries `id`, `replaces_id` and `superseded`, quotes embedded content and
  neutralizes formula-like text. No opaque pending command is resent with a
  new identity; uncertain commands use the existing receipt reconciliation.

## Named evidence

```text
server/.venv/bin/pytest -q server/tests/test_f37_expense_corrections.py \
  server/tests/test_f37_shared_expenses.py server/tests/test_f37_shared_expenses_api.py
19 passed
flutter test --no-pub test/features/shared_expenses
15 passed; normal TCP test skipped without its isolated runner
server/.venv/bin/python server/tests/support/f37_flutter_acceptance.py
prepare 1 passed; fresh Core/Client restart 1 passed
flutter test --no-pub -d chrome test/features/shared_expenses/shared_expense_authority_web_test.dart
2 passed on real Chrome/web-javascript
flutter analyze --no-pub lib/features/shared_expenses test/features/shared_expenses
No issues found
```

The domain was checked against the official [Spliit project](https://github.com/spliit-app/spliit),
which documents expense editing/export and a product activity log. Larenor's
immutable linked ledger is its own implementation, not a claim to embed Spliit.
The read/write boundary was checked against [SQLite transaction semantics](https://www.sqlite.org/lang_transaction.html):
an explicit read transaction preserves one snapshot, while an immediate write
transaction serializes concurrent writers. Session/member postflight is still
necessary after a separate ledger read.

Broad exact HEAD CI remains open. Household financial records, physical device
usability and any external banking acceptance are not inferred from synthetic
software fixtures; banking/payment execution is outside this feature's scope.
