# Helper base start state diagnostics

Native run 7 (`34260536889`) used exact source
`bd1a604ab46873a2fc967eb3806ca60562609690` and failed on both GitHub-hosted
native architectures with
`phase=helper_base_start code=fixture_command_exit_failed`. Its failed log was
downloaded exactly once to
`/private/tmp/larenor-bd1a604-native7-failed.log`: 70,222 bytes, SHA-256
`8ac144f5069622b8bcb5fd63d55bbdcfd9d481fd92637f599005df91ec8a70c4`.
The previous bounded private stderr classifier found no known family. This is
still failure evidence; it does not prove a Jellyfin install, persistent
storage, or a particular Docker/runtime cause.

Commit `dd49b4dabdbd0eb9ac8166c364db1d1cb8ff7774` adds one bounded, read-only
state observation after the single exact-base `start --attach` attempt fails.
The observation addresses only the 64-hex container ID returned by the earlier
owned-daemon create. It uses that same verified owned socket and empty Docker
configuration, requests only `{{json .State}}`, accepts at most 65,536 bytes,
and has an explicit 10-second deadline. There is no second start, create,
build, restart, adoption, external socket fallback, or installation grant.

The state read reduces private fields to these closed outcomes:

| Closed code | Required observation |
| --- | --- |
| `helper_base_process_oom` | Docker explicitly reports `OOMKilled=true`. |
| `helper_base_process_dead` | Docker explicitly reports `Dead=true`. |
| `helper_base_process_running` | Running, paused, restarting, or running status remains after the failed attach. |
| `helper_base_process_nonzero` | Exited state with a nonzero integer exit code. The code does not claim a signal cause. |
| Existing start family | The bounded private `State.Error` matches exactly one existing known family. |
| Original closed start code | The state response is unavailable, malformed, inconsistent, oversized, unknown, or does not refine the failure. |

`State.Error`, exit numbers, status strings, container identity, paths, URLs,
environment values, and command output are never emitted or persisted. The
whole response exists only in bounded process memory. A diagnostic read error
cannot replace the original closed code. `KeyboardInterrupt` and other
`BaseException` cancellation still propagate through the existing whole-owned-
daemon cleanup. The original 20-second start deadline remains; the optional
post-failure state read has its own 10-second deadline.

The initial TDD run produced 15 real failures because the state reducer did not
exist. The focused reducer suite then passed 15 cases. The first combined
Jellyfin/volume/engine run passed 862 cases and retained three existing
platform-specific skips out of 865 collected. After the final conservative
classification and 10-second bound, all 249 Jellyfin cases passed. All 215
dependency-free policy tests and 24 execution-queue tests passed;
`tool/check_security_policy.py`, Python compilation and `git diff --check`
also passed. Branch-inclusive coverage of the runner plus launcher rounds to
98% in the local coverage report.

Independent review found and closed two P2 issues in the draft. First, an exit
code of 128 or above was named as a signal even though a process can explicitly
return the same value. That label and branch were removed; every nonzero exited
result now retains the cause-neutral `helper_base_process_nonzero` name.
Second, the synthetic daemon initially checked the wrong format-argument index,
so the integration test exercised only fallback. The fixture now recognizes
the exact `{{json .State}}` argv and a non-stubbed launcher test proves one
`ExitCode=17` state observation becomes the closed process-nonzero result. Final
independent review of the clean production/test commit was CLEAR. A new
exact-source native run remains the only way to learn whether this state
observation identifies the hosted-runner failure. `installAvailable` remains
false.
