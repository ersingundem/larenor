# F39 normal Core acceptance — 2026-09-30

F39 uses Core's encrypted family-board reducer; it has no household or external
provider write. The normal-path acceptance runs the production Flutter account,
authority gateway, strict board models, durable secure-cache contract and
controller against a normal `create_app` Core over Uvicorn TCP.

The runner replaces the first two successful HTTP command responses with a
bounded `request_timeout` response **after Core has committed the command**. The
Client sends the same immutable request id and body once more, retains that
command after the second uncertain response, and blocks further mutation. A
fresh Flutter process and a fresh Core process then recover the same stored
session and pending command. The command is replayed only as an idempotent
receipt lookup before the board is writable again; SQLite contains one event.

The second lifetime also proves two independent authenticated sessions can
merge stale, disjoint appends, while a stale edit of the same card receives a
revision conflict and is not retried. It deletes the private card, verifies the
Client cache no longer contains its text, rejects a retired route and signed-out
account, and finishes with exactly five encrypted audit events.

Run:

```sh
server/.venv/bin/python server/tests/support/f39_flutter_acceptance.py
```

Focused contracts:

```sh
flutter test --no-pub \
  test/features/family_board/family_board_controller_test.dart \
  test/features/family_board/family_board_cache_test.dart
server/.venv/bin/pytest -q \
  server/tests/test_f39_family_board_core.py \
  server/tests/test_f39_family_board_api.py
```

This is software acceptance with synthetic accounts and loopback TCP. It does
not claim a household-device or manual-provider gate because F39 has no such
provider.

Root integration: 11 focused Server tests, 26 Flutter tests (one runner-only test skipped outside its explicit fixture), both normal-Core lifetimes, and scoped analyze passed. Broad exact-HEAD CI remains pending.
