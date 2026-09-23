# S09.1 vault-key consistency boundary

Date: 23 September 2026

This narrow Server slice closes one independent gap in the S09.1 backup
contract. The separate 256-bit vault key is now captured while the Core
SQLite write reservation is held and is accepted only when it matches the
`key_check` stored in that exact database cut. It does not change the Client
export/destination implementation or introduce restore and host-volume writes.

## Acceptance boundary

1. A replaced, malformed, missing, or non-private key file cannot produce a
   ready manifest or encrypted export. The API returns only the static
   `server_unavailable` response and does not expose a path or key material.
2. The key bytes used in `vault-key` are read and validated before the bounded
   component quiescence/capture completes, while the Core database write
   reservation is still active. The resulting database and key therefore
   cannot be an internally mismatched restore pair.
3. Existing encrypted-envelope, component consistency, empty-target restore,
   Core identity, and storage-permission contracts remain unchanged.

## TDD evidence

The RED command was:

```text
cd server
PYTHONPATH=. /Users/ersingundem/oikos/server/.venv/bin/python -m pytest \
  tests/test_core_backup_contract.py -q
```

It produced **1 failed, 9 passed**: both plan and export returned `200` after
replacing the separate vault key with a different private 32-byte value. The
GREEN rerun produced **10 passed**.

The broader backup/key regression command covered
`test_core_backup_contract.py`, `test_core_backup_components.py`,
`test_core_backup_empty_restore.py`, `test_core_context.py`, and
`test_storage.py`: **79 passed** with only the two existing upstream
Starlette/httpx deprecation warnings. Focused Ruff and `git diff --check` pass.

## Remaining S09.1 gates

S09.1 remains pending. A reviewed privileged component snapshot adapter,
large-volume/native acceptance, component restore/rollback, interruption
recovery, Client restore UX, independent review, and exact-head CI remain
separate gates. This slice does not change `docs/execution-queue.json`, the
queue status, or selected-feature counters.
