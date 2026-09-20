# F32 pantry stock reducer foundation

This first independent F32 slice is intentionally limited to a pure Core
contract. It does not register an API, database migration, Client route, or
claim full F32 closure. Progress remains **17/125** and **0/63**; F31 and all
currently open pull request files remain untouched.

Exactly three acceptance criteria are delivered:

1. Stock amounts use bounded integers and normalize `g`, `kg`, `ml`, `l`, and
   piece quantities without floating-point drift. Lot IDs, ingredient keys and
   ISO expiry dates reject ambiguous or malformed input.
2. Consumption uses one locked optimistic revision and allocates the earliest
   expiry lot first. Two concurrent callers with the same revision produce one
   committed receipt and one `revision_conflict`; insufficient stock changes
   nothing.
3. Receive, consume and undo requests are exact-idempotent. A byte-equivalent
   replay returns its original receipt, request reuse with changed intent fails,
   and one movement can be restored at most once without double credit.

## TDD evidence

RED failed during collection because `larenor_server.pantry_stock` did not
exist. GREEN covers normalization and malformed dates, deterministic lot
allocation, a real two-thread stale revision race, exact replay conflict, and
bounded one-time undo. Persistence, encrypted journal/tamper recovery, person
ACL, versioned HTTP, Client to isolated Core E2E and tablet UI remain explicit
next slices.
