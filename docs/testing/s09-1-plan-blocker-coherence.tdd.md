# S09.1 backup plan blocker coherence

Date: 23 September 2026

The Core backup plan response names every in-flight operation that prevents a
consistent cut. The response models previously accepted blocker lists that the
capture service can never produce. A duplicated, reordered or mixed
quiescence response could therefore be displayed as a valid blocked plan and
hide a Server contract regression.

## Three-job acceptance boundary

1. Active operation blocker codes are unique. Repeating one code is rejected
   by the Server response model and the Client parser.
2. Active blocker codes follow the capture service's fixed inspection order.
   A Server test binds the response-model order directly to `_ACTIVE`, and the
   Client rejects reordered input.
3. Component quiescence timeout/unavailable is an exclusive terminal blocker.
   It cannot be combined with an active operation or the other quiescence
   result.

This slice changes no backup data, secret, URL, log or export destination. It
only rejects impossible response states before they cross the Server or Client
contract boundary.

## RED to GREEN evidence

The RED Server run failed all four noncanonical cases. With generated Flutter
sources present, the Client RED run failed its duplicate, order and exclusive
quiescence tests. The GREEN focused batch passes the new contract tests plus
the existing Server and Client Core backup contract suites:

```text
uv run pytest \
  tests/test_core_backup_plan_blocker_contract.py \
  tests/test_core_backup_contract.py

flutter test \
  test/features/server/server_core_backup_plan_contract_test.dart \
  test/features/server/server_core_backups_test.dart
```

## Remaining S09.1 gates

Production component-volume restore, full deployment configuration
portability, Client import UX, independent review and exact-head CI remain
open. S09.1 stays `pending`; evidence-backed counters remain **26/125** and
**0/63**.
