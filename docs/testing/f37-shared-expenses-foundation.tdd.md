# F37 shared expenses Core foundation

Status: the foundation is mounted behind authenticated Core routes and the
current account resolver; F37 remains `pending` for the remaining acceptance
work recorded in the Client document.

Larenor stores household expense amounts as integer minor units. This package
contains no bank connection, payment initiation, card data, or credential field.
The household-account snapshot is expected to come from a current server-side
resolver; display names or time proximity never grant authority.

## Three accepted criteria

1. Supported ISO currency codes have an explicit scale and reject floats.
   Deterministic account ordering distributes indivisible remainder units while
   preserving the exact total for every split.
2. Create is bound to exact Core/home, active household membership, payer
   authority, ledger revision, and command id. A byte-identical retry returns
   its prior receipt; changed payload, stale revision, foreign member, or
   cross-home access fails closed without another event.
3. Expense payloads are AES-GCM encrypted at rest. Scope state and append-only
   events are HMAC anchored so actor, order, request, record, or terminal-state
   tampering fails after restart. Bounded export is admin-wide or participant
   filtered and contains no command id, bank, payment, token, or secret field.

## TDD evidence and remaining work

- RED `2891675e`: the three isolated SQLite acceptance scenarios failed because
  `larenor_server.shared_expenses` did not exist.
- GREEN `83bd6c6c`: deterministic splitting, exact authority/idempotency,
  encryption, filtered export, restart, and tamper checks pass.

The HTTP contract and household-account resolver are now integrated. The edit
and reversal journal, CSV artifact delivery, and real Client-to-isolated-Core
device acceptance remain open. No F37 acceptance or progress counter is claimed
by this integration package.
