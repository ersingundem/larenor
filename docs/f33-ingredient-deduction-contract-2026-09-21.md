# F33 ingredient deduction contract

This isolated contract does not read or mutate F32 pantry files. It defines the
boundary that a later Core pantry adapter must implement.

## Acceptance

1. A completed cooking step produces one canonical, bounded preview tied to the
   exact account, recipe session, recipe revision, step revision, and expected
   pantry revision. Duplicate stock items, invalid quantities, and more than
   100 deductions are rejected before any command exists.
2. Only explicit confirmation can call the gateway. The returned receipt must
   match the exact idempotency key, account, next pantry revision, and ordered
   applied deltas. A second confirmation returns the retained receipt without
   a second command.
3. Lost acknowledgement enters an uncertain state and cannot retry the stock
   command. Reconciliation is a separate read by idempotency key. Lifecycle or
   account authority loss discards late receipts and blocks further work.

## TDD evidence

- RED `26e96a98`: production contract and controller were absent.
- RED `bfe92b8a`: a retained receipt remained visible after account authority
  changed.
- GREEN `ac87856b` and `76637197`: the focused Flutter contract suite passes 5 tests and focused analysis
  reports zero findings.

F33 remains pending at 18/125 and 0/63. A real Core pantry adapter, grant and
audit receipt, Client-to-Core E2E, full CI, and F31/F32 integration remain open.
