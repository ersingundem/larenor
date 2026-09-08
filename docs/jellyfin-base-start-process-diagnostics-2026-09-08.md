# Attached base start process diagnostics

Native run 5, source `25d438aed00b44cf10322a500a4dbb001c920dfd`, failed on
amd64 and arm64 at `phase=helper_base_start code=fixture_command_failed`.
The single preserved log `/private/tmp/larenor-25d438a-native5-failed.log` is
70,193 bytes, SHA-256
`c7444904c1bbeecb7f49d14725aeeb4d068800022938cc409b6fb24771cc9cd0`.
No second download or real Docker experiment was made. This result places the
failure after the pinned base pull, image inspection, create and created-state
checks, before helper build. It does not distinguish a nonzero attached-start
command from timeout, output overflow, spawn or I/O failure.

The existing bounded command runner now accepts a private strict boolean
`diagnose_process`, used only by the exact base `start --attach` call. It selects
these existing closed codes:

- `fixture_command_exit_failed`: the Docker CLI process returned nonzero.
- `fixture_command_timeout`: its total command deadline expired, including a
  wait after stdout EOF.
- `fixture_command_output_limit`: stdout exceeded the existing 128-byte bound.
- `fixture_command_spawn_failed`: process creation raised an OS error.
- `fixture_command_io_failed`: an OS error occurred after process creation.

No stderr is read, classified, retained or exported by this option. It stays
`DEVNULL`; the build's separate `diagnose_failure` option still exclusively owns
the existing bounded private stderr/matcher path. No second subprocess runner,
public CLI flag, error family, new daemon effect or fallback is introduced.
Both flags are exact booleans, validated before spawning. Default behavior for
all other calls is preserved.

The [Docker CLI attached-start implementation](https://github.com/docker/cli/blob/v27.5.1/cli/command/container/start.go)
can report both client/API/attach errors and the attached container's exit
status. Therefore a nonzero CLI code alone is not proof of runtime creation,
container exit or attach failure. This slice intentionally leaves that ambiguity
explicit instead of treating a guessed cause as a fix. A missing/wrong token on
CLI exit zero still reports the existing `fixture_protocol_failed`; successful
output must still pass the same final container/image/config/state readback.

The start deadline stays 20 seconds and stdout stays bounded to 128 bytes.
One create/start attempt, source binding, whole owned-daemon cleanup, process
group kill/reap, later build, UID/NoCopy/application health/restart checks and
success receipt schema are unchanged. `installAvailable` remains false. A
failed or uncertain start never replays or continues into build/installation.

The diagnostic branch was fast-forwarded from `07dc9fa` to the current main
`25d438a`; main itself was not edited. TDD: `b05372a` recorded five actual
subprocess runtime RED cases, all failing solely because their distinct causes
were flattened into the same code. `039007b` made all five pass. Test checkpoint
`225695b` adds 15 cases total, including exact 128/129-byte output, large discarded
stderr, no build-classifier invocation, invalid flag rejection, EOF-before-timeout
cleanup, only-one-call opt-in and actual owned-socket/environment forwarding.
The existing build forwarding test only adds the explicit new default false
field; its socket, environment and prior diagnostic expectations remain.

Final related tests: 225 PASS, zero skips, 6.46 seconds (15 new + 210 prior).
Runner plus unchanged launcher coverage is 97.18% including branches:
549/562 statements and 71/76 branches. All 215 existing policy tests passed in
51.294 seconds; syntax, static security-policy and diff checks passed.
Independent source review of `039007b` was CLEAR, without duplicate test or
Docker execution. Private logs/JUnit/coverage/receipt use
`/private/tmp/larenor-jellyfin-start-`.

The native root cause remains unresolved. There was no local Docker/daemon,
GitHub query/download/dispatch, push, home operation or full Core rerun. A future
reviewed native run must supply the next exact-source evidence. This diagnostic
change does not claim successful runtime, bootstrap or installation acceptance.
