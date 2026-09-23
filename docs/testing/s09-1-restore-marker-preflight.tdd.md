# S09.1 interrupted-restore marker preflight

Date: 23 September 2026

An interrupted empty-Core restore keeps its journal authoritative until the
key, family board, database and initialization marker are all published. The
recovery path previously validated an existing `.initialized` marker only
after publishing the three data artifacts. A corrupt or policy-invalid marker
could therefore leave a newly partial target before recovery failed.

## Three-job acceptance boundary

1. A private marker with wrong bytes is rejected before publishing the vault
   key, family board or Core database.
2. A marker symlink is rejected at the same preflight point and is normalized
   to the static `restore_recovery_invalid` error.
3. A marker with non-private permissions is also rejected before publication
   with the same static error. Storage paths and underlying policy details do
   not enter CLI output or recovery state.

The exact existing marker remains valid for idempotent interrupted recovery.
When no marker exists, recovery still creates the private marker only after all
journal-bound artifacts have been verified and published, then retains the
journal until stage cleanup completes.

## RED to GREEN evidence

The focused RED run failed all three new cases: wrong marker content published
the target key before failing, while symlink and public-permission markers
exposed internal storage-policy error codes. The GREEN run passes all **4**
recovery-preflight cases:

```text
uv run --project server pytest \
  server/tests/test_core_backup_recovery_preflight.py -q
```

## Remaining S09.1 gates

Production component-volume capture and restore, full deployment
configuration portability, Client import UX, independent review and exact-head
CI remain open. S09.1 stays `pending`; evidence-backed counters remain
**26/125** and **0/63**.
