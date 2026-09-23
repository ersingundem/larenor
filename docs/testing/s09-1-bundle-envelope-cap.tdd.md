# S09.1 encrypted bundle envelope ceiling

Date: 23 September 2026

The Server's 424 MiB limit is the final encrypted Core backup bundle limit.
The archive builder previously allowed a plaintext ZIP up to that full limit,
then added the fixed magic, salt, nonce, and AES-GCM authentication tag. A
boundary export could therefore exceed `MAX_BUNDLE_BYTES` and be rejected by
the same Server's open and restore paths.

## Acceptance boundary

1. The ZIP budget subtracts the exact 65-byte encrypted envelope from the
   final bundle ceiling before encryption.
2. One byte beyond that archive budget fails with the static
   `backup_too_large` error; an exact-bound export remains decryptable.
3. Digest, semantic payload, component, compatibility, restore, and Client
   transport behavior are unchanged. S09.1 stays pending and its counters stay
   at **25/125** and **0/63**.

## TDD evidence

The focused regression first failed because an export one byte above the final
synthetic cap completed successfully. After reserving the fixed envelope from
the archive budget, the new regression and the existing contract, component,
and empty-restore suites passed **33 tests**:

```text
uv run --project server pytest \
  server/tests/test_core_backup_bundle_limits.py \
  server/tests/test_core_backup_contract.py \
  server/tests/test_core_backup_components.py \
  server/tests/test_core_backup_empty_restore.py -q
```

## Remaining S09.1 gates

Production component-volume capture wiring, component restore and rollback,
full deployment configuration portability, interruption recovery across those
component effects, independent review, and exact-head CI remain open.
