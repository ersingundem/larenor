# Helper base state-error family diagnostics

Native run 11 (`34273975969`) used exact source
`bd031251a97289c3d6dd4d4f4f04dc1df3c379a3`. Both native jobs reached the
owned helper base start and failed with the same closed result:
`phase=helper_base_start code=helper_base_state_error_unclassified`.

The failed log was downloaded exactly once to
`/private/tmp/larenor-bd03125-native11-failed.log`: 70,209 bytes, SHA-256
`37654a4e183b644beaeffc175234e1d0350e195ef6039d5bb58326e5bdd0baad`.
No success receipt was produced. The result proves that the valid Engine state
contains a non-empty error outside the previously reviewed runtime, exec,
permission, storage, daemon, missing-container and wait families. It does not
expose the error or establish its cause.

Commit `35d05b6ed427c358a70c395fc8690d238e590c72` privately reduces that remaining
error to five fixed, non-secret families:

| Closed code | Reviewed bounded signal family |
| --- | --- |
| `helper_base_isolation_failed` | Cgroup, security-profile, namespace, rootfs or mount wording. |
| `helper_base_host_resource_failed` | Host memory, process or file-descriptor exhaustion wording. |
| `helper_base_path_failed` | Missing-path or invalid-path-type wording. |
| `helper_base_identity_failed` | Container user/group lookup wording. |
| `helper_base_configuration_failed` | Invalid-argument or invalid-configuration wording. |

When more than one new family matches, the public result is the closed
`helper_base_state_error_ambiguous` code. No matched substring, raw Engine
error, path, URL, environment value, user/group value or container identifier
is emitted.

The five desired family outcomes first failed against the previous
unclassified result. The final state suite passed 34 cases, the combined state
and stderr suites passed 66 cases, all 270 Jellyfin tests passed, and all 218
dependency-free policy tests passed. Python compilation and diff validation
were clean. Independent review found no open P1/P2 issue in the exact commit;
it confirmed the closed allowlist, ambiguity behavior, Python 3.12–3.14 syntax,
single bounded inspect, cancellation and raw-data boundaries.

The same owned container ID and socket, one 10-second/65,536-byte state read,
one start attempt, private error handling, process-group cleanup and no-retry
behavior remain in force. Native run 12 must observe one of the fixed family,
ambiguous or still-unclassified codes. Engine and installation acceptance
remain open and `installAvailable=false`.
