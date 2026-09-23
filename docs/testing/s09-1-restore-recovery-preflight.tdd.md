# S09.1 restore recovery publication preflight

Date: 23 September 2026

An interrupted empty-target restore leaves a durable journal and private staged
key, family-board, and Core database files. Recovery previously verified and
published those artifacts one at a time. If a later staged file was corrupt or
missing, earlier valid artifacts had already moved into the target before the
recovery failed.

## Acceptance boundary

1. Recovery validates every staged or already-published artifact against the
   journal before it starts a new publication pass.
2. A corrupt late database leaves the key, family board, and database targets
   untouched while preserving the authoritative journal for diagnosis or a
   later valid retry.
3. Existing crash continuation remains idempotent: once all artifacts verify,
   recovery publishes them in the same order and keeps the journal until stage
   cleanup completes.
4. This slice changes no Client API/export code or bundle-size contract. S09.1
   remains pending; counters stay at **25/125** and **0/63**.

## TDD evidence

The new test first failed because recovery published the vault key before it
detected the corrupted staged database. The preflight pass made the regression
and the existing empty-restore suite pass **16 tests**:

```text
uv run --project server pytest \
  server/tests/test_core_backup_recovery_preflight.py \
  server/tests/test_core_backup_empty_restore.py -q
```

## Remaining S09.1 gates

Production component-volume capture, component restore and rollback, full
deployment configuration portability, Client import/restore UX, independent
review, and exact-head CI remain open.
