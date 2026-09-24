# S09.2 atomic component restore staging boundary

Date: 24 September 2026

This second component-restore slice adds an injected boundary and coordinator
for a complete off-target staging cut. The default production boundary remains
disabled and returns the same static `component_restore_unavailable` error; the
tests use only an in-memory synthetic boundary and perform no Engine, host-path
or volume write.

The coordinator acquires the authority for the exact Job1 plan, quiesces the
sorted target tuple, captures every rollback snapshot receipt, stages every
authenticated payload, and revalidates the authority and deadline before its
single batch commit call. No volume can be committed while another volume is
unstaged or while the authority is stale. Provider errors, timeout before the
commit decision and authority drift invoke rollback and release exactly once.

## TDD evidence

The RED command was:

```text
cd server
PYTHONPATH=. /Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q \
  tests/test_core_backup_component_restore.py
```

Collection failed because the new production boundary did not exist:

```text
ImportError: cannot import name 'ComponentRestoreBoundary'
```

The focused GREEN test reports **19 passed** in the component restore module.
The final grouped command, including the S09.1 encrypted component-capture and
durable installation-authority regressions, reports **34 passed** with no
skips.

| Guarantee | Focused evidence |
| --- | --- |
| Exact authority acquisition, deterministic quiesce, all rollback snapshots, all stages, revalidation and one commit happen in that order | `test_coordinator_stages_every_volume_then_revalidates_before_one_commit` |
| Quiescence, snapshot provider, staging provider, authority drift and deadline failures leave the synthetic target unchanged | `test_coordinator_failure_rolls_back_and_releases_once_without_target_write` |
| Every acquired failure path calls rollback and release exactly once and never calls commit | `test_coordinator_failure_rolls_back_and_releases_once_without_target_write` |
| Production has no implicit host adapter and fails closed | `test_default_component_restore_boundary_rejects_without_host_effect` |

## Remaining S09.2 work

The boundary is intentionally synthetic. A later reviewed adapter must provide
real isolated snapshot/stage/atomic-swap operations, and the restore workflow
still needs a durable cross-resource journal with restart reconciliation and
rollback. No live restore or host-volume path is enabled here. S09.2 remains
pending; counters remain **26/125** and **0/63**.
