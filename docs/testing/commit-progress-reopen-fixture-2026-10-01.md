# Commit-progress reopening fixture — 1 October 2026

The progress-reopening tests previously copied the repository's live
`docs/execution-queue.json` from `HEAD` and then assumed K07 and K08 were
accepted. That made the validator test depend on current product state. Once
the truthful queue moved those items to `awaiting_ci`, 11 reopening cases
failed before exercising the transition they were meant to validate.

The test fixture now builds a disposable accepted-history queue. It retains
the production schema and dependency graph, then marks only the historical
targets, checkpoints, and their complete dependency closure as `done`.
Required evidence kinds receive completed, passing synthetic references bound
to the fixture commit, including a repository-owned regular evidence blob.
Every unrelated non-group node is `pending`, so reopening a target cannot
leave an accepted dependent behind. The live queue is read only for its schema
and graph; its current statuses, completion commits, reasons, and evidence do
not determine the historical fixture.

A dedicated regression validates that K07 and K08 are accepted, have every
required evidence kind, and have no finishing blockers before any reopening
mutation. The existing suite continues to prove exact evidence-bound
reopening and fail-closed handling for missing or deleted evidence,
directories, symlinks, empty blobs, traversal and spoofed CI references,
retained completion commits, invalid statuses, deleted nodes, dependency
violations, merges, and disconnected histories. Production validators and
the live execution queue were not changed.

Focused validation:

```text
python3 -m unittest tool.tests.check_commit_progress_test
```

Result: 19 tests passed.

Combined validation:

```text
python3 -m unittest \
  tool.tests.check_commit_progress_test \
  tool.tests.execution_queue_test \
  tool.tests.commit_with_progress_test
```

Result: 51 tests passed. The earlier combined gate contained 50 tests; the
additional test is the new synthetic accepted-history integrity regression.
