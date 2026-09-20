# S08.10 event, command result, and bounded transfer acceptance

This slice reuses the existing signed event and command history and adds the
smallest missing Core transport capability. It does not close S08.10: Android
resume/cancel UX, physical SAF/LAN evidence, and exact-main CI remain open, so
progress stays at **17/125 (13.6%)** and feature completion at **0/63 (0.0%)**.

## Acceptance criteria

1. **Ordered, replay-protected events.** Transfer and command histories retain
   their HMAC chain, monotonic cursor, checkpoint signature, bounded page size,
   and fail-closed replay/gap behavior. Resume and cancel produce the existing
   accepted/result event sequence rather than a parallel event store.
2. **Idempotent attributed command results.** The established command ledger
   remains the authority for request identity, actor attribution, terminal
   result replay, and readback. This slice does not duplicate or weaken that
   contract; its regression set runs alongside transfer tests.
3. **Bounded resume, cancel, and cleanup.** A continuation requires a new
   request ID plus an exact interrupted receipt belonging to the actor and the
   same Core/home/resource/content digest/type/length/provider revision. Core
   reserves only remaining bytes, retains the 256 KiB and MIME gates, exposes
   the resume offset, and rejects HTTP Range. Explicit cancel is idempotent and
   all terminal paths retire active leases without exposing content or secrets.

## Focused evidence

- Server: bounded-transfer unit, HTTP contract, upload/media policy, ordered
  event/checkpoint, and command history suites.
- Client: existing bounded-transfer contract/checkpoint tests plus focused
  static analysis; Client resume UI remains an explicit open gate.
- Security: repository security policy, secret scan, diff whitespace check,
  queue validation, progress trailer validation, and merge-tree simulation.
