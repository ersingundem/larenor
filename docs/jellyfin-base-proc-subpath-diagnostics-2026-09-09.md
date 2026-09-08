# Helper base procfs subpath diagnostics

Native run 15 (`34284431981`) used exact source
`d5d58895d42ea4193c6129774c7b64300b4552df`. Both `linux/amd64` and
`linux/arm64` reached
`phase=helper_base_start code=helper_base_engine_proc_paths_observed`.
No success receipt or public artifact was produced.

The failed-job log was downloaded once to a private temporary path. It is
70,226 bytes and its SHA-256 is
`6a22d9e663d17e2856a7ac445d0f5a754e82725bd7b53147bc769c4f1e9a9d20`.
Repository evidence retains only that digest, byte count and the closed
phase/code pair. It does not retain the private Engine error, path values or
process identifiers.

## Closed procfs observations

Commit `12f6f0931fce17f91204e8cdeb767daef395fd9e` narrows the exact Engine and
procfs co-occurrence into six fixed subfamilies:

| Closed code | Neutral observation |
| --- | --- |
| `helper_base_proc_sys_net_path_observed` | A procfs network-sysctl path occurred. |
| `helper_base_proc_self_fd_path_observed` | A current-process file-descriptor path occurred. |
| `helper_base_proc_self_mountinfo_observed` | The exact current-process mountinfo path occurred. |
| `helper_base_proc_self_namespace_observed` | A current-process namespace path occurred. |
| `helper_base_proc_process_namespace_observed` | A numeric-process namespace path occurred. |
| `helper_base_proc_process_fd_path_observed` | A numeric-process file-descriptor path occurred. |

Two or more recognized procfs subfamilies produce
`helper_base_proc_subpaths_ambiguous`. Unrecognized procfs paths preserve the
broader `helper_base_engine_proc_paths_observed` result. Numeric process IDs
are recognized in private memory but are never included in a code, log,
receipt or artifact.

Path-family classification now operates on parsed absolute path tokens. A
`/proc/sys/...` path cannot also be mistaken for a sysfs-root path. Procfs
subfamilies are selected only from tokens rooted at `/proc/`; lookalike text
under another root is ignored, and `mountinfo` requires an exact leaf match.

## Verification

The eight initial cases and the two review regressions failed before their
respective implementation changes. The final exact commit passes 64 state,
96 combined state/stderr, all 300 Jellyfin and all 218 dependency-free policy
tests under Python 3.12.14. Python compilation and diff validation pass.
Independent final review is CLEAR. Full locked Server CI remains required
before the package is promoted.

The single start attempt, one bounded 10-second/64-KiB owned-state inspect,
no-retry rule, cancellation behavior and whole-namespace cleanup are
unchanged.

## Remaining gate

Native run 16 must execute this exact reducer on both architectures. Its
closed result will select the next bounded observation or repair boundary.
Real Engine installation acceptance remains open and
`installAvailable=false`.
