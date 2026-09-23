# S09.1 offline restore passphrase contract

Date: 23 September 2026

The export API accepts backup passphrases containing 16 through 128 characters
and at most 512 UTF-8 bytes, without control characters. The offline restore
CLI previously read at most 129 bytes and did not apply the same semantic
validation. A valid 128-character, 512-byte passphrase could create a bundle
that the supported restore path could not reopen.

## Acceptance boundary

1. Export and offline restore share one passphrase validator: 16..128
   characters, at most 512 UTF-8 bytes, and no C0 or DEL controls.
2. The CLI accepts the exact 512-byte boundary plus one terminal line feed in
   the private passphrase file.
3. Invalid decoded values fail before Scrypt/decrypt or restore mutation with
   the static `restore_passphrase_invalid` code; the supplied value is never
   printed.
4. This slice changes no Client export transport, bundle-size calculation, or
   recovery publication code. S09.1 remains pending; counters stay at the
   current main values, **26/125** and **0/63**.

## TDD evidence

The focused RED run failed all four cases: the valid maximum-size UTF-8 value
returned `invalid_storage_file`, short/control values reached decryption, and
the 129-character value used a different storage error. After sharing the
validator and widening only the bounded private-file read, the four CLI cases
and the related export/restore regressions passed.

```text
uv run --project server pytest \
  server/tests/test_core_backup_restore_cli_secrets.py \
  server/tests/test_core_backup_contract.py \
  server/tests/test_core_backup_empty_restore.py -q
```

## Remaining S09.1 gates

Production component-volume capture, component restore and rollback, full
deployment configuration portability, Client import UX, independent review,
and exact-head CI remain open.
