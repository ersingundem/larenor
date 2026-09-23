# S09.1 offline restore lock ownership

Date: 23 September 2026

The empty-target restore path validated `.initialize.lock` through one file
descriptor, closed it, and then reopened the path with `Path.open`. A symlink
or inode replacement between those steps could move the advisory lock away
from the private file that had passed validation.

## Three-job acceptance boundary

1. Open the restore lock once with `O_NOFOLLOW | O_CLOEXEC`; require a regular
   file owned by the effective user, mode `0600`, and exactly one link.
2. Acquire `flock` on that same descriptor and recheck the path's device/inode
   after acquisition. A symlink or replacement fails with the static
   `restore_lock_invalid` code before bundle decoding or staging.
3. Keep the verified descriptor non-inheritable and exclusively locked for
   the complete restore lifecycle. The restore path must never reopen the
   preflighted lock through `Path.open`.

This slice does not change the encrypted bundle, payload compatibility,
publication journal, component-volume behavior or Client flow.

## RED to GREEN evidence

The initial focused RED run failed all three tests: the descriptor helper did
not exist and the integration path still called `Path.open` after preflight.
GREEN passed those tests. The adversarial follow-up added a fourth regression
that replaces the path immediately after `flock`; the post-lock identity check
rejects it before entering the restore body.

```text
uv run --project server pytest \
  server/tests/test_core_backup_restore_lock_ownership.py -q
4 passed
```

The final verification batch also covers the empty-target, recovery-preflight,
database-cap and encrypted-contract suites.

## Remaining acceptance

S09.1 stays pending. Production component restore/rollback, deployment
acceptance, Client import/apply UX, independent review and exact-head CI remain
open. Queue and selected-feature counters stay at **26/125** and **0/63**.
