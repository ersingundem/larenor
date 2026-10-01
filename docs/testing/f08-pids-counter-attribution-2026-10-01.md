# F08 PID counter attribution repair (2026-10-01)

## Observed Linux failure

The exact `721952a` Linux run `36832137026`, job `110270960128`, passed the
owned IPC case and then failed while reading the assistant unit's leaf
`pids.events`: the leaf path had disappeared. The bounded log establishes the
missing leaf but does not establish whether the provider exited, the unit hit a
runtime policy, or systemd removed an empty failed unit. This repair therefore
does not assign one of those causes.

## Live-leaf attribution rule

The earlier proposed parent-counter fallback was rejected: a foreign sibling can
increment and disappear between snapshots, so a surviving parent delta cannot
identify the removed owned leaf. A missing or recreated leaf now always fails.

Before releasing the owned task-limit fixture, the Linux gate records:

- the exact leaf inode and `pids.max=8`;
- leaf `pids.events` and `pids.events.local` baselines;
- a private, fixed `eagain` marker written by the owned provider only after its
  exact `fork()` call returns `EAGAIN`.

The provider keeps all seven forked children alive after writing the marker.
Before acknowledging observation, the gate requires the same leaf inode,
`pids.max=8`, `pids.current=8`, and a new `max` event in both leaf
`pids.events` and leaf `pids.events.local`. The fixed marker synchronizes the
observer but is never sufficient evidence by itself. Requiring the exact local
cgroup counter and current task count excludes an unrelated per-user or global
fork failure. The later exact unit observation must still be
`failed/provider_failed` with no output.

This follows the Linux cgroup v2 contract: `pids.max` is the hard task limit,
fork/clone returns `EAGAIN` when that policy would be violated,
`pids.events:max` is hierarchical by default, and `pids.events.local` records
only the current cgroup. Keeping the owned children alive makes the leaf itself
the required evidence surface.
See the authoritative kernel documentation for
[PID interface files](https://docs.kernel.org/admin-guide/cgroup-v2.html#pid-interface-files),
[the `pids_localevents` mount option](https://docs.kernel.org/admin-guide/cgroup-v2.html#mounting),
and [empty cgroup removal](https://docs.kernel.org/admin-guide/cgroup-v2.html#organizing-processes-and-threads).

## Fail-closed boundaries and timing

The gate rejects a missing or recreated leaf, a changed `pids.max`,
`pids.current` below the configured maximum, either missing or unchanged leaf
counter, a historical positive value, an unsafe marker, and a marker not bound
to the exact dispatch ID. The provider cleanup remains in `finally`, so timeout
and failure reap every owned child. The repair does not extend the production
runtime, fixture deadline, task limit, or observation deadline.

The failed run's bounded output establishes only that the leaf had disappeared.
It does not distinguish provider exit, runtime retirement, or another lifecycle
cause. The new handshake prevents accepting any of those states as proof.

## Local verification

`server/.venv/bin/python -m pytest -q server/tests/test_f08_cgroup_stress_fixture.py`
passes 21 portable tests. They cover the exact configured task limit,
same-inode leaf attribution, live `pids.current`, both leaf counter deltas,
historical-positive rejection, missing and recreated leaves, private fixed
marker validation, and child retention plus cleanup around the observation
acknowledgement. `python3 -m py_compile` covers all three edited Python modules.

The local macOS host cannot run the actual systemd/cgroup v2 acceptance test.
The repair remains awaiting a changed-source Linux run and does not claim the
prior failure is resolved on Linux.

## Independent root verification and review

The root portable gate passed 21 tests, and pinned Ruff 0.14.1 passed all
three Python modules. A separate reviewer confirmed that removal of parent
attribution closes the transient-sibling false-green gap. Private root output:
`/private/tmp/larenor-root-verify-20261001/f08-final.log` and `f08-ruff.log`.
Actual changed-source Linux/systemd acceptance remains required.
