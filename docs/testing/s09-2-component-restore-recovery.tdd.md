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

Restart reconciliation verifies the HMAC and exact plan digest before asking
the injected boundary for the same operation ID. Any incomplete transaction,
including a partial commit, rolls back to the captured receipts. Durable
`rolled_back` and `released` phases make recovery restartable; boundary effects
use the stable operation ID for idempotence. The default production boundary
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

The recovery module reports **20 passed**. The grouped component restore,
encrypted component capture and durable installation-authority batch reports
**58 passed**, with no skips. The two warnings are upstream Starlette/httpx
deprecation warnings.

The accepted S09.1 authority base is
`9332419a2cba7421eded4cdd7983378070dbb916`. Re-stacking the original three
S09.2 commits preserved aggregate stable patch ID
`54a5de16a4ebf07aa5fe26b83c891fc2cacd5595`.

## Independent audit closure

Four permanent regressions record the audit findings and their fixes:

| Boundary | RED evidence | GREEN commit |
| --- | --- | --- |
| A semantically valid, directly constructed `BackupCapture` must not reach restore authority without successful encrypted-bundle authentication | `test_plan_rejects_semantically_valid_capture_without_bundle_authentication` failed because no exception was raised | `d18e26a757f684257e19e029290a16184581a890` |
| Deadline or authority drift after commit, and release failure after commit, restore the old target with one bounded release attempt | all three cases in `test_post_commit_drift_or_release_failure_restores_target_once` failed | `da451146999b4ad34f4495a99061ba0d3fe0629a` |
| Failure to durably publish `released` after a successful release retains the honest `committed` journal and never invokes rollback or release again in the same run | `test_released_journal_failure_never_rolls_back_or_releases_again` observed `rolled_back` | `f1b74941581cf2f75a1e68755537becd03fcfe7c` |
| Every ordinary post-acquire recovery failure releases the recovered authority once while preserving the journal | authority, deadline, rollback and journal-persist cases all observed zero releases | `43ba49d49cffde11b1029b3abc2806289ca36545` |
| Durable commit must be followed by the same deadline and authority checks as the non-durable coordinator before publishing `committed` | both authority and deadline drift returned success with changed targets | `ff78a404ad804381270539e54b7cd29d0564b516` |
| A malformed raw recovered capability must remain available for one release even when strict session validation rejects it | the malformed session observed zero release attempts | `ff78a404ad804381270539e54b7cd29d0564b516` |

Ruff `0.14.10`, Python bytecode compilation, Android/security policy,
125-task/63-feature queue validation, the ten-commit progress gate and
`git diff --check` all pass. Queue and feature progress remains **26/125** and
**0/63**.

| Guarantee | Focused evidence |
| --- | --- |
| Restart after authority acquisition, quiescence, rollback snapshots, staging or pre-commit restores the original target | `test_restart_reconciles_each_precommit_crash_once` |
| A partial cross-volume commit is rolled back after restart and a second recovery is a no-op | `test_partial_commit_is_rolled_back_after_restart_and_recovery_is_idempotent` |
| A successful durable batch clears the journal only after one exact release | `test_successful_durable_batch_clears_journal_after_exact_release` |
| Crashes after durable rollback or release do not repeat either effect | `test_recovery_restart_skips_completed_rollback_or_release_exactly_once` |
| Journal mode, bound, HMAC, plan binding and absence of payload/path data fail closed | `test_v3_journal_is_private_authenticated_bounded_and_fail_closed` |
| A second process cannot acquire the active restore journal owner lock | `test_recovery_journal_serializes_cross_process_owners` |
| Without an injected reviewed boundary, production restore remains disabled | `test_default_durable_boundary_keeps_component_restore_disabled` |

## Remaining S09.2 work

The journal and coordinator are production-grade local persistence, but the
only exercising boundary remains synthetic. A separately reviewed Linux
snapshot/stage/swap adapter must provide real idempotent effects keyed by the
journal operation ID before live component restore can be enabled. Native
crash/power-loss acceptance and exact-head CI also remain open. S09.2 stays
pending; counters remain **26/125** and **0/63**.
