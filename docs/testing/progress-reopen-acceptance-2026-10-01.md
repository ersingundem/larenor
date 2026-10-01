# Evidence-bound progress reopening — 1 October 2026

The progress gate used to reject every decrease in a commit trailer. That made
truthful revocation of an accepted item impossible after a changed-source
regression: keeping the old `done` count was misleading, while correcting the
queue to `awaiting_ci` caused `progress_regressed`.

The gate now reads each repository-owned queue from the immutable Git tree for
the commit and each direct parent. Every trailer must equal its own queue
snapshot. A lower done count is accepted only when the queue diff proves all of
the following:

- each removed done item is the same named task moving from `done` to exactly
  `awaiting_ci` or `reworking`;
- its previous acceptance entries remain byte-for-byte present, its completion
  commit is cleared, and its other authority, dependency, scope and acceptance
  fields are unchanged;
- its changed reason adds a named, nonempty regular Git blob present in that
  commit or an exact bounded GitHub Actions run token; directories, symlinks,
  traversal paths, URL suffixes and empty files are rejected;
- no historical node is deleted, no item becomes newly done in the same
  regression edge, totals do not shrink, and queue plus selected F01–F63 done
  decreases equal the exact reopened item sets.

External queue fixtures retain the original monotonic behavior because they do
not have immutable repository history. Merge commits are checked separately
against every direct parent, so a second-parent regression cannot be hidden by
topological ordering.

TDD used disposable Git repositories with the real validated queue schema. The
RED run showed that unnamed reopening and deleted historical evidence were
accepted by the old gate. The GREEN command was:

```text
PYTHONPATH=tool python3 -m unittest tool.tests.check_commit_progress_test
```

It passed 18 tests. The suite covers a valid K07/K08 reopening, an F06 selected
feature reopening, forged first-commit trailers, missing named evidence,
deleted historical evidence or nodes, retained completion commits, invalid
target status, directory/symlink/empty/traversal/spoofed evidence references,
immutable head-tree ownership, merges, disconnected histories, and the
existing trailer/report behavior. This policy records loss of
acceptance; it does not turn an awaiting-CI item back into accepted work or
replace the missing CI evidence.

The combined progress, queue-schema and commit-wrapper gate passed 50 tests.
The full immutable `origin/main..52f9bac6` history also passed, which confirms
that loading every historical repository queue does not reinterpret accepted
legacy commits under the new reopening rule.
