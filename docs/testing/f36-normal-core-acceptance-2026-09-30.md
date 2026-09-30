# F36 fair chores normal Core acceptance

The production Flutter account API and controller now run through a normal
Uvicorn Core over loopback TCP for two Core lifetimes. The fixture owns only
synthetic household accounts and never contacts a household service.

The gate creates a recurring `Europe/Berlin` chore, defers it, completes it
after deliberately losing the HTTP result, and reconciles the durable receipt
without sending the command again. Core calculates the next occurrence from
its own clock across the daylight-saving boundary. Restart preserves the exact
task and event chain. After the assigned member is disabled through the real
admin API, the Client sees an inactive assignee, explicitly skips that turn,
and completes the recovered assignment.

Every command carries the exact current household-membership revision. Core
revalidates the account, session and member snapshot inside the same immediate
transaction before and after mutation. A stale revision fails before a write;
read responses are also postflight checked after the ledger read. The derived
membership digest is bounded to JavaScript's exact integer range, so the same
authority value survives Flutter Web JSON parsing without rounding. It is
compared for equality and never ordered: a newer membership digest may be
numerically smaller.

Completion atomically appends one private F54 event for the new assignee in the
same database transaction as the task and audit event. Its deterministic
task-revision idempotency key prevents duplicate completion notifications.
The normal gate reads each recipient's event through the authenticated F54 API,
checks private lock-screen redaction, exact event counts and encrypted storage,
and proves both task and notification persistence after restart.

Focused commands:

```text
server/.venv/bin/pytest -q \
  server/tests/test_f36_fair_chores.py \
  server/tests/test_f36_fair_chores_api.py \
  server/tests/test_f36_notifications_authority.py
server/.venv/bin/python server/tests/support/f36_flutter_acceptance.py
flutter test --no-pub test/features/fair_chores
flutter analyze --no-pub lib/features/fair_chores \
  test/features/fair_chores/fair_chore_normal_core_test.dart
```

Physical tablet notification timing and OEM background-process behavior remain
manual device evidence. This software gate proves the local Core/F54 handoff;
it does not claim external push delivery.

The recurring rotation supports at most 32 ready household members. A larger household receives the explicit bounded `fair_chore_members_limit_reached` (413) response before any chore mutation; it is not an internal server error or a truncated rotation.

Root integration validation: 10 focused Server tests passed, both normal Core/Client lifetimes passed, and the existing fair-chore Client suite and scoped analyze passed. Broad exact-HEAD CI remains pending.
