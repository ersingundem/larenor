# F13 component egress lease lifecycle

This slice closes three independent replay paths in an already-authorized outbound probe lease:

1. A completed lease cannot emit another `dispatch_authorized` event or start another request.
2. A completed lease cannot append a second `probe_completed` outcome for the same correlation.
3. A failed lease cannot append repeated `probe_unconfirmed` outcomes, and success cannot later be rewritten as failure.

The lease now has a lock-protected `open -> dispatched -> completed|failed` lifecycle. Address and authority checks remain valid while open/dispatched; every terminal state rejects subsequent use with static `outbound_denied`. A phase changes only after its encrypted audit transaction commits, so a failed write remains safely retryable by the owning operation rather than recording an in-memory result that was never persisted.

## TDD evidence

- RED `5b4d73666face6288d259bd538ded5298834f910`: all three terminal replay contracts failed and appended duplicate audit events.
- GREEN `80f003168276ce171d820568660f8e6e5a8b7ce9`: all 3 focused lifecycle tests pass.

F13 remains pending at **26/125 (20.8%)** and selected-feature progress remains **0/63 (0.0%)**. Additional managed component transport coverage and exact-head CI remain open.
