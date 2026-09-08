# Helper base path co-occurrence diagnostics

Native run 14 (`34281674390`) used exact source
`1e73ea3b122eeaa64ae9254269bdad18ddec8a6c`. Both `linux/amd64` and
`linux/arm64` reached
`phase=helper_base_start code=helper_base_path_location_ambiguous`.
No success receipt or public artifact was produced.

The failed-job log was downloaded once to a private temporary path. It is
70,207 bytes and its SHA-256 is
`81409d865a87f785bda58094a978344e4ed37d6817f1562184744a8da5309bed`.
Repository evidence retains only that digest, byte count and the closed
phase/code pair. It does not retain the private Engine error or path values.

## Neutral closed observations

Commit `67b2a924844e7b762460dbd9b72a304476cb7ab7` adds five neutral outcomes for
an exact two-family set observed anywhere in the bounded private state error:

| Closed code | Observation |
| --- | --- |
| `helper_base_engine_image_paths_observed` | Owned Engine root and known image path families both occur. |
| `helper_base_engine_proc_paths_observed` | Owned Engine root and procfs path families both occur. |
| `helper_base_engine_sys_paths_observed` | Owned Engine root and sysfs path families both occur. |
| `helper_base_engine_runtime_paths_observed` | Owned Engine root and runtime path families both occur. |
| `helper_base_engine_host_paths_observed` | Owned Engine root and Docker host-file path families both occur. |

These codes claim co-occurrence only. If the exact two families also occur in
one parsed path token, the existing, stronger Engine-target relationship code
takes precedence. Three or more families, non-Engine pairs and unknown
combinations remain `helper_base_path_location_ambiguous`. Raw error and path
text never cross the private reducer boundary.

## Verification

All five co-occurrence cases first failed against the ambiguous result. The
final exact commit passed 54 state tests, 86 combined state/stderr tests, all
290 Jellyfin tests and all 218 dependency-free policy tests. Python compilation
and diff validation passed. Independent final review is CLEAR.

The single start attempt, one bounded 10-second/64-KiB owned-state inspect,
no-retry rule, cancellation behavior and whole-namespace cleanup are unchanged.

## Remaining gate

Native run 15 must execute this exact reducer on both architectures. A neutral
pair result will select the next observation or repair boundary without
overstating causality. Another ambiguous result will require a bounded exact-set
diagnostic. Real Engine installation acceptance remains open and
`installAvailable=false`.
