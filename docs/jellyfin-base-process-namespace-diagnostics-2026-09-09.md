# Helper base process namespace diagnostics

Native run 16 (`34287061380`) used exact source
`b4e8620f993e35fe231c71ddba6961eaba70577a`. Both `linux/amd64` and
`linux/arm64` reached
`phase=helper_base_start code=helper_base_proc_process_namespace_observed`.
No success receipt or public artifact was produced.

The failed-job log was downloaded once to a private temporary path. It is
70,230 bytes and its SHA-256 is
`c9ba3dd9cbd9891036426bc927aa79538a5c49eb8dac48f1e3ffb10c876cb83a`.
Repository evidence retains only that digest, byte count and the closed
phase/code pair. It does not retain the private Engine error, namespace path
or process identifier.

## Closed namespace observations

Commit `4fa3c2a2aa033615c9a0edf9711fcda7ba58e6bd` maps recognized numeric-process
namespace leaves to a fixed allowlist:

| Namespace leaf | Closed observation code |
| --- | --- |
| `net` | `helper_base_proc_process_net_namespace_observed` |
| `mnt` | `helper_base_proc_process_mnt_namespace_observed` |
| `ipc` | `helper_base_proc_process_ipc_namespace_observed` |
| `uts` | `helper_base_proc_process_uts_namespace_observed` |
| `pid` | `helper_base_proc_process_pid_namespace_observed` |
| `pid_for_children` | `helper_base_proc_process_pid_children_namespace_observed` |
| `user` | `helper_base_proc_process_user_namespace_observed` |
| `cgroup` | `helper_base_proc_process_cgroup_namespace_observed` |
| `time` | `helper_base_proc_process_time_namespace_observed` |
| `time_for_children` | `helper_base_proc_process_time_children_namespace_observed` |

Two or more recognized leaves produce
`helper_base_proc_process_namespaces_ambiguous`. An unknown leaf preserves the
broader process-namespace observation. Matching is anchored to the complete
parsed `/proc/<numeric>/ns/<leaf>` token. The numeric process segment is used
only to validate shape and is never returned.

General state-family matching now removes parsed paths from its message view.
This prevents a path leaf such as `cgroup` from also claiming a cgroup
configuration failure. Path location and namespace classification continue to
use the bounded private path tokens.

## Verification

All ten recognized leaves and the multi-leaf case failed against the broader
result before implementation. The final exact commit passes 75 state, 107
combined state/stderr, all 311 Jellyfin and all 218 dependency-free policy
tests under Python 3.12.14. Python compilation and diff validation pass.
Independent final review is CLEAR. The isolated locked Server workflow on
exact source `ce5479ac26f76a024bacef058c1002444dd85cef` passed all 3,988 tests
with two warnings:
[Server CI](https://github.com/ersingundem/larenor/actions/runs/34287937523).

The single start attempt, one bounded 10-second/64-KiB owned-state inspect,
no-retry rule, cancellation behavior and whole-namespace cleanup are
unchanged.

## Native result

Native run 17 executed this reducer on both architectures and selected the
numeric-process `net` namespace leaf. A runner-procfs candidate was rejected
before native execution because it would separate PID-namespace thread IDs
from the procfs numeric view. A cgroup-owned mount-only daemon lifecycle is the
implemented repair boundary; its ownership, cleanup and verification evidence
is documented in the
[owned cgroup lifecycle](jellyfin-owned-cgroup-lifecycle-2026-09-09.md).
Real Engine installation acceptance remains open and `installAvailable=false`.
