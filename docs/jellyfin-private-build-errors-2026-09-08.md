# Private helper build error diagnostics

Native run `34238813425`, source
`5f0fa46241238b62677b9293308c90460b605893`, failed on amd64 and arm64 with
`phase=helper_build code=fixture_command_exit_failed`. The complete preserved
70,177-byte log has SHA-256
`e7bffd096f5a21f1034fe4b1a34f39484a1c8b2a3b8053fa71e08aa211d6db80`.
This rules out the runner's stdout limit, deadline, spawn and I/O failure codes;
it does not identify why Docker build exited nonzero. No local Docker experiment
or guessed Dockerfile change was made.

Only helper build's existing `diagnose_failure=True` path now drains stderr into
private bounded memory. Separate selector registrations drain stdout and stderr
without pipe deadlock; both reach EOF before exit is assessed. Stdout remains
limited to 256 bytes and the build keeps its 600-second total deadline. Stderr
has a new 64 KiB hard limit; overflow fails immediately and never classifies a
partial message. The buffer is cleared and both pipes close during existing
owned-process-group kill/reap cleanup. This is bounded data handling, not a
claim of cryptographic memory erasure.

Nonzero build outcomes can report closed signature classes for missing manifest,
missing platform, registry authentication/rate limit, runtime creation, build
context, TLS, DNS, storage and failed Dockerfile step. No matching signature
retains `fixture_command_exit_failed`; multiple classes produce
`helper_build_error_ambiguous`. Success remains success regardless of stderr
text. These are diagnostic signatures, not independent proof of a root cause
or an authorization decision. Raw stderr/stdout, paths, URLs, environment and
credentials are never printed, persisted or included in receipt artifacts.

This deliberately narrows the earlier helper-specific `DEVNULL` contract from
the [previous diagnostic slice](jellyfin-helper-build-diagnostics-2026-09-08.md).
All commands without diagnostic opt-in still use `DEVNULL`. The old large-stderr
success test remains on that default path; helper tests now assert the bounded
private-pipe path. Workflow, Dockerfile, helper/probe sources, Server production,
single build attempt, image/volume authority, native guards, source binding and
success receipt format remain unchanged. `installAvailable` stays false.

The independent static review found no proven Dockerfile/VFS incompatibility.
Docker's [legacy CLI implementation](https://github.com/docker/cli/blob/v27.5.1/cli/command/image/build.go)
can flush buffered progress plus the build error to stderr on quiet failure.
The 64 KiB bound therefore includes both, tested with 32 KiB of progress before
the final error. The [Moby build implementation](https://github.com/moby/moby/blob/v27.5.1/builder/dockerfile/internals.go)
passes the selected network mode to build containers; successful image/volume
preparation does not by itself prove a RUN container can start. These primary
sources explain the diagnostic design; they do not prove this CI's cause.

TDD checkpoints:

- `885a93f` → `1022da9`: 11 runtime RED → 11 GREEN cases through real small
  child processes and the actual synthetic build consumer.
- `f7f3f37` → `a4ba945`: bounded quiet progress exposed the initial 16 KiB cap
  (one RED), then all 12 cases passed at 64 KiB. An initial child-script newline
  escaping mistake produced a syntax-error exit; it was corrected before the
  verified RED and is not product evidence.
- `15f1897`: 172 related tests passed, zero skips, 4.92 seconds (20 new plus
  152 prior cases). Negative/positive cases cover unknown and ambiguous errors,
  malformed bytes, split signatures, exact dual-pipe bounds, error-looking
  stderr on exit zero, overflow and a descendant retaining the stderr pipe.

The existing 215 policy tests passed in 47.636 seconds. Branch-inclusive coverage
for runner plus unchanged launcher is 96.48%: 505/521 statements and 71/76
branches. Existing security policy checks, syntax, diff checks and the final
secret scan passed. An independent source review of `a4ba945` was CLEAR.
Private logs/JUnit/coverage/receipt use `/private/tmp/larenor-jellyfin-stderr-`;
the original log remains `/private/tmp/larenor-5f0fa46-native-storage.log`.

No GitHub query/download, dispatch, push, real Docker/daemon, home access or full
Core suite was run. A reviewed future native run must provide the next evidence;
this slice does not claim successful bootstrap, installation or physical-device
acceptance.
