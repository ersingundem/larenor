# S09.1 offline restore input ownership

Date: 23 September 2026

The offline restore command already required private, bounded regular files and
shared the export passphrase validator. It still loaded the backup envelope
before validating the much smaller passphrase file, retained the source UTF-8
bytes for the whole restore, and treated a normal CRLF-terminated secret file
differently from its LF equivalent.

## Three-job acceptance boundary

1. Read and validate the private passphrase file before allocating the backup
   envelope. Invalid secret input must never open the bundle.
2. Accept exactly one terminal LF or CRLF outside the passphrase while keeping
   the existing 16..128 character, 512-byte and control-character rules.
3. Decode from a mutable buffer and overwrite that source buffer on both
   success and validation failure. Python's decoded `str` remains subject to
   normal runtime lifetime; this change does not claim complete process-memory
   erasure.

The encrypted bundle format, Scrypt/AES-GCM parameters, restore publication,
component-volume behavior and Client transport do not change.

## RED to GREEN evidence

The focused RED run produced four failures because neither input helper
existed. Independent review then found that wrapping `private_read` in a
`bytearray` wiped only a copy while the original immutable bytes remained.
RED `1a414531` proves the exact I/O buffer was not owned; GREEN `dc74e86b`
reads directly into one bounded mutable buffer and wipes it on every exit.
The GREEN smoke passes the five new ordering/termination/cleanup
regressions and the eight existing CLI secret/error regressions. The final
single verification batch also includes encrypted-contract and empty-target
restore coverage:

```text
uv run --project server pytest \
  server/tests/test_core_backup_restore_input_ownership.py \
  server/tests/test_core_backup_restore_cli_secrets.py \
  server/tests/test_core_backup_empty_restore.py \
  server/tests/test_core_backup_contract.py -q
40 passed
```

## Remaining acceptance

S09.1 stays pending. The privileged component snapshot PR is independent; a
production component restore/rollback boundary, deployment acceptance,
import/apply UX, independent review and exact-head CI remain open. Queue and
selected-feature counters stay at **26/125** and **0/63**.
