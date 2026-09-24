# S09.2 durable component restore recovery journal

Date: 24 September 2026

This third component-restore slice adds a private, authenticated version-3
cross-resource journal around the synthetic Job2 boundary. The journal binds
the complete Job1 plan, snapshot, installation and volume binding revisions,
rollback receipts and staged payload receipts. It stores no payload bytes,
credentials or host paths.

Every state replacement writes a new mode-0600 file, fsyncs it, atomically
renames it and fsyncs the parent directory. A separate verified mode-0600
`flock` file serializes restore and recovery owners across processes. The
journal is capped at 256 KiB and authenticated with HMAC-SHA256 using an
injected 32-byte key that is never persisted.

Restart reconciliation verifies the HMAC, exact plan digest and exact planned
paused-container set before asking the injected boundary for the same operation
ID. Pre-commit transactions roll back to captured receipts; a durably
`committed` transaction finishes forward. Durable `rolled_back`,
`rollback_finalized`, `committed_finalized` and `released` phases make artifact
cleanup and release independently restartable. The default production boundary
still has no adapter and rejects component restore before any host effect.

## TDD evidence

The RED command was:

```text
cd server
PYTHONPATH=. /Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q \
  tests/test_core_backup_component_restore_recovery.py
```

Collection failed before the recovery module existed:

```text
ModuleNotFoundError: No module named \
  'larenor_server.core_backups.component_restore_recovery'
```

The focused recovery and Linux-boundary pair reports **41 passed** and one
Linux-only native skip on macOS. The grouped component restore, Docker adapter,
installation authority and durable recovery batch reports **89 passed** and
one Linux-only native skip. The two warnings are upstream Starlette/httpx
deprecation warnings.

The accepted S09.1 authority base is the merged native-capture squash
`e5763adfcc9306c5dfcffe312389065b6dbc6bd7`. The earlier restack onto
`9332419a2cba7421eded4cdd7983378070dbb916` remains historical evidence: it
preserved aggregate stable patch ID
`54a5de16a4ebf07aa5fe26b83c891fc2cacd5595`.

## Independent audit closure

The final three permanent regressions supersede earlier release-on-failure
behavior and close the native recovery audit:

| Boundary | RED evidence | GREEN commit |
| --- | --- | --- |
| An `acquiring` or `acquired` record must not claim an independent admin pause | native recovery unpaused the externally paused container | `ad07ae89236f79cb52018c51002d38ee2485f620` |
| Rollback evidence must survive failure to persist `rolled_back` | the first recovery deleted the rollback archive, so the second recovery could not repeat rollback | `95213ea9eb24540ebc88b59aba1500564f6f3588` |
| Commit and rollback artifact cleanup must finish before release, including cleanup-complete/phase-write-loss recovery | an immediate service write after unpause failed live digest finalization; missing artifacts after a failed `committed_finalized` write wedged recovery | `ae2a3f822e11941af6b7bb31f1adfceaf4619102` |

Ruff `0.14.10`, Python bytecode compilation, Android/security policy,
125-task/63-feature queue validation, the ten-commit progress gate and
`git diff --check` all pass. Queue and feature progress remains **26/125** and
**0/63**.

| Guarantee | Focused evidence |
| --- | --- |
| Restart after authority acquisition, quiescence, rollback snapshots, staging or pre-commit restores the original target | `test_restart_reconciles_each_precommit_crash_once` |
| A partial cross-volume commit is rolled back after restart and a second recovery is a no-op | `test_partial_commit_is_rolled_back_after_restart_and_recovery_is_idempotent` |
| A successful durable batch clears the journal only after one exact release | `test_successful_durable_batch_clears_journal_after_exact_release` |
| Crashes after durable rollback cleanup or release do not repeat either effect | `test_recovery_restart_skips_completed_rollback_or_release_exactly_once` |
| Acquiring/acquired recovery never adopts an unproven admin pause | `test_recovery_never_adopts_unproven_admin_pause` |
| A failed `rolled_back` journal write preserves rollback evidence for the next recovery | `test_rollback_artifacts_survive_rolled_back_journal_write_failure` |
| Commit cleanup is complete before unpause and remains idempotent if its phase write fails | `test_success_cleanup_finishes_before_unpause_allows_service_write`, `test_committed_cleanup_is_idempotent_before_phase_persist` |
| Journal mode, bound, HMAC, plan binding and absence of payload/path data fail closed | `test_v3_journal_is_private_authenticated_bounded_and_fail_closed` |
| A second process cannot acquire the active restore journal owner lock | `test_recovery_journal_serializes_cross_process_owners` |
| Without an injected reviewed boundary, production restore remains disabled | `test_default_durable_boundary_keeps_component_restore_disabled` |

## Remaining S09.2 work

The journal and Linux boundary now cover native crash and power-loss behavior,
but S09.2 still requires exact-head dual-architecture CI and product-level
restore exposure review before the queue item can close. S09.2 stays pending;
counters remain **26/125** and **0/63**.
