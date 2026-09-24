# S09.1 final capture authority exit

## Scope

This follow-up closes the ownership gap after a Linux Btrfs capture has built
its return value but the retained capture-root authority fails its final exit
revalidation. It does not add restore behavior or change queue counters.

## RED

The permanent regression sets `fail_on_capability_call=20`, after both
read-only snapshots and their returned descriptors exist. Before the fix, the
outer retained context rejected the capture after the inner cleanup scope had
already returned: two unpublished descriptors remained open, active source
ownership stayed set, and only a process restart could resume reconciliation.
The focused test failed with **14 open descriptors instead of 12**.

## GREEN guarantees

The retained capture context now invokes an ownership cleanup callback only
when its own post-yield validation fails. The callback closes every unpublished
snapshot descriptor exactly once and clears active source ownership. It leaves
the journal, generation, and read-only snapshots untouched so an independently
revalidated restart can reconcile them without deleting through lost
authority. The regression then creates a new engine, recovers the retained
journal, removes both snapshots through descriptor-bound operations, and clears
the journal.

Focused preflight, engine, and composition result: **54 passed**. The milestone
component-capture package ran **204 tests: 202 passed and 2 explicit native
fixture skips**. The three static amd64/arm64 workflow contracts passed.

S09.1 remains pending at **26/125** queue progress and **0/63** selected-feature
progress.
