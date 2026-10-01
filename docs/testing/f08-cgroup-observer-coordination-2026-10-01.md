# F08 owned cgroup observer coordination — 1 October 2026

Exact `5325c083970096fc84da2daa63b6b2a2f208aed2`, Actions
[run 36816909489](https://github.com/ersingundem/larenor/actions/runs/36816909489),
failed the stress test at `memory.events` with `FileNotFoundError` (errno 2).
The separate actual Core-UID-to-AI-UID IPC test passed. This is a counter
observation failure, not a new listener-bind failure or an accepted stress run.

The old fixture began allocating immediately, then tried to keep its parent
alive with a two-second sleep. That does not protect observation from the
normal systemd OOM policy. The pinned
[systemd v255 service contract](https://github.com/systemd/systemd/blob/v255/man/systemd.service.xml)
and [implementation](https://github.com/systemd/systemd/blob/v255/src/core/service.c)
show that `OOMPolicy=stop` stops the unit after a child OOM event. The
[kernel cgroup v2 contract](https://docs.kernel.org/admin-guide/cgroup-v2.html)
allows empty cgroups to be removed and defines hierarchical `memory.events`.
The exact hosted retirement mechanism remains unproved by the retained log.

The owned fixture now waits for a private dispatch-bound start acknowledgement.
Before releasing it, the test reads the actual leaf's 64 MiB memory limit and
zero swap limit, then snapshots its parent's hierarchical memory counters,
local counters, inode, and sibling counters. Acceptance requires a new parent
OOM/kill delta, unchanged parent identity/local/sibling observations, and the
exact unit's Core IPC `failed/resource_limit` result with no output receipt.
Historical positive counters cannot pass. Production OOM behavior and limits
are unchanged. Tasks/CPU fixtures also wait for the observer's acknowledgement
before exiting; kernel task/throttling counters and cleanup remain mandatory.

The private acknowledgement has an eight-second bound, exact dispatch/stage,
owned 0700 directory and regular 0600 file with no symlink following. Portable
tests exercise a real subprocess, absence of receipts before both barriers,
malformed/symlink/public acknowledgements and bounded missing acknowledgement.
Root's focused fixture/systemd/IPC set passed 31 tests; two explicitly opted-in
Linux gates remain skipped on macOS. This is coordination evidence only. A
fresh changed-source Linux stress run is required.
