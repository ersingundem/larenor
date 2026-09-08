# Helper base path-location diagnostics

Native run 12 (`34276890501`) used exact source
`282bcc1cbc97bd4a7020ccf019f32bac1c82dcf9`. Both native jobs reached the
owned helper base start and failed with the same closed result:
`phase=helper_base_start code=helper_base_path_failed`.

The failed log was downloaded exactly once to
`/private/tmp/larenor-282bcc1-native12-failed.log`: 70,199 bytes, SHA-256
`555a81b36a5713364ffdef8a658be8d76a763f832e1ec678329c08ff199e0cba`.
No success receipt was produced. The result proves that the private Engine
state error contains missing-path or invalid-path-type wording. Because none of
the cgroup, security-profile, namespace, rootfs or mount signals matched, the
result does not establish an isolation cause or disclose the affected path.

Commit `7f2a41e17e9baa3ea6557dd686351dd4fa10eeb1` privately classifies a path
failure by six fixed location families:

| Closed code | Reviewed bounded location family |
| --- | --- |
| `helper_base_image_path_failed` | Known executable or staged helper path inside the image. |
| `helper_base_proc_path_failed` | Linux procfs path. |
| `helper_base_sys_path_failed` | Linux sysfs path. |
| `helper_base_runtime_path_failed` | Runtime path rooted under `/run`. |
| `helper_base_engine_path_failed` | Owned ephemeral Engine root or standard Docker data root. |
| `helper_base_host_path_failed` | Docker-provided host files such as resolver or hostname files. |

More than one matching location becomes
`helper_base_path_location_ambiguous`; an unknown location stays at the generic
`helper_base_path_failed`. Only literal path prefixes identify a location.
Component names such as `containerd` do not. No actual path, error text,
container identifier, user value, environment value or matched fragment is
emitted.

Seven initial location outcomes first failed against the generic path result.
Independent review then found two factual naming/matching defects: “missing”
overstated ENOTDIR, and a bare runtime component could misclassify an unrelated
path. Neutral `*_path_failed` codes, a real ENOTDIR regression and a runtime
name-only negative regression close both findings. The final state suite passed
43 cases, the combined state and stderr suites passed 75 cases, all 279
Jellyfin tests passed, and all 218 dependency-free policy tests passed. Python
compilation and diff validation were clean.
Independent final review found no open P1/P2 issue in the exact commit and
confirmed both earlier findings closed.

The same owned container ID and socket, one 10-second/65,536-byte state read,
one start attempt, private error handling, process-group cleanup and no-retry
behavior remain in force. Native run 13 must observe one fixed location,
ambiguous or generic path result. Engine and installation acceptance remain
open and `installAvailable=false`.
