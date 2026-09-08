# Helper build failure classification

Manual native characterization #2 at source
`28792d1074b11f7bba89ba413b16c86b7ed6321e` failed on both architectures with
`phase=helper_build code=fixture_command_failed`. The preserved 70,183-byte log
has SHA-256 `4e81f20dc222db53cc06e361c6f9776c145ba3f7913b0b65c42a1c1cd7becf28`.
The preceding source, owned-daemon, image, two-volume and staging checks reached
the build call, but the log does not distinguish nonzero exit, output overflow,
deadline, spawn or I/O failure. No Dockerfile/Engine root cause is claimed.

The helper build now selects a private strict boolean `diagnose_failure=True`
on the existing bounded command runner. Its five closed failure codes are:

| Code | Observed command boundary |
| --- | --- |
| `fixture_command_exit_failed` | Child exited nonzero after stdout EOF. |
| `fixture_command_output_limit` | Stdout exceeded the unchanged 256-byte limit. |
| `fixture_command_timeout` | Output wait or final process wait exceeded the existing deadline. |
| `fixture_command_spawn_failed` | `Popen` raised an OS error before returning a child. |
| `fixture_command_io_failed` | An OS error occurred after a child was obtained. |

Other fixture commands retain `fixture_command_failed`. Only helper build opts
in; no CLI option or arbitrary diagnostic string is accepted. Stderr remains
`DEVNULL`, stdout is bounded and private, and no exit output, environment, paths
or secrets are exposed. The phase-safe launcher emits the selected static code.
The 600-second build deadline, 256-byte bound, source/context checks, owned socket,
environment, process-group cleanup and single build attempt are unchanged.

`e717f14` recorded five runtime RED cases through the real fixture consumer using
small real Python children and synthetic Docker dispatch. `cac8c9a` made those
five cases GREEN. The read-error injection was narrowed to the child's stdout
descriptor before the verified RED checkpoint, so it does not mistake Python's
internal process-spawn pipe for command output. `d78e8a5` adds positive boundary,
discarded large stderr, stdout-EOF timeout, strict selector and helper-only
selection tests: 13 new plus 139 existing cases passed (152 total, zero skips,
4.24 seconds). The existing 215 policy tests passed in 43.258 seconds.

Validation used the existing Server environment and six named fixture pytest
files, `python3 -m unittest discover -s tool/tests -p '*_test.py'`, the existing
security policy checker, AST syntax and `git diff --check`. Runner plus unchanged
launcher branch-inclusive coverage is 96.49% (487/502 statements, 63/68 branches).
Artifacts use `/private/tmp/larenor-jellyfin-build-`; the original native log is
preserved at `/private/tmp/larenor-28792d1-native-storage.log`.

No Docker, daemon, home access, workflow dispatch, GitHub query, download, push
or full Core test was performed. Workflow, helper image source/Dockerfile,
Server runtime and success receipt format are unchanged; `installAvailable`
remains false. A future reviewed native run must supply the missing command
boundary evidence before choosing any actual build repair.
