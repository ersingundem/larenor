# F13 component egress lease lifecycle

This slice closes three independent replay paths in an already-authorized outbound probe lease:

1. A completed lease cannot emit another `dispatch_authorized` event or start another request.
2. A completed lease cannot append a second `probe_completed` outcome for the same correlation.
3. A failed lease cannot append repeated `probe_unconfirmed` outcomes, and success cannot later be rewritten as failure.

The lease now has a lock-protected `open -> dispatched -> completed|failed` lifecycle. Address and authority checks remain valid while open/dispatched; every terminal state rejects subsequent use with static `outbound_denied`. A phase changes only after its encrypted audit transaction commits, so a failed write remains safely retryable by the owning operation rather than recording an in-memory result that was never persisted.

## TDD evidence

- RED `c2ff6f17`: all three terminal replay contracts failed and appended duplicate audit events.
- GREEN `e72f46de`: all 3 focused lifecycle tests pass.
- ASSERTIONS `acf1e621`: terminal rejection evidence checks the stable API error and status precisely.

Independent review found that `complete` marked the lease terminal before the
outer service transaction committed. RED commit `28694364` proves a later
service write rollback made the unpersisted completion impossible to retry.
GREEN commit `0395cdfc` adds a commit/rollback completion callback: concurrent
reuse remains fenced while the transaction is open, commit makes the lease
terminal, and rollback restores its exact retryable phase. The expanded
component-egress batch passes **58/58** tests.

F13 remains pending at **26/125 (20.8%)** and selected-feature progress remains **0/63 (0.0%)**. Additional managed component transport coverage and exact-head CI remain open.
