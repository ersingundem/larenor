# F36 fair chore Core foundation

Status: software foundation only; F36 stays `pending`.

This slice owns no Android route, notification delivery, Home Assistant write,
or household-membership resolver. Those integrations remain separate acceptance
work. The Core contract accepts only a server-resolved, revisioned member
snapshot and never infers membership from display names or event timing.

## Three accepted criteria

1. A scoped recurring chore keeps an exact member-snapshot revision, rotates to
   the next currently eligible person, skips departed members, and derives the
   next due wall time from the real completion in the configured IANA timezone.
   The exact task revision survives a Core restart.
2. Create is admin-only; read, defer, and completion remain bound to the exact
   Core/home and current member authority. Foreign members, stale task or
   household revisions, and cross-home identifiers fail closed without a write.
3. Completion commands are idempotent, a command cannot be replayed as another
   action, and the bounded append-only history is HMAC chained. Restarted reads
   reject modified actor, receipt, revision, ordering, or current task state.

## TDD and verification

- RED: `2bf253a8` defined restart/rotation, authority/departure, idempotency, and
  tamper cases before `larenor_server.fair_chores` existed.
- RED hardening: `498614ca` reproduced same-home disclosure and cross-action
  idempotency-key reuse before the authority fix.
- GREEN: `server/tests/test_f36_fair_chores.py` passes all three scenarios using
  isolated SQLite files and no production account, host, or secret.

Remaining F36 work includes the authenticated HTTP contract, the real current
household-membership resolver, Client tablet surfaces, F54 notification outbox
delivery/duplicate acknowledgement, and real Client-to-isolated-Core E2E. No
queue counter changes until those dependencies and complete CI evidence exist.
