# Attached base start: bounded private stderr

Native run 6 (`34257672707`), exact source
`32d43fd54f7213b3d2cf548dcda7c86b05310606`, failed on both amd64 and arm64
with `phase=helper_base_start code=fixture_command_exit_failed`. The preserved
70,211-byte log is `/private/tmp/larenor-32d43fd-native6-failed.log`, SHA-256
`f5357a2f73df32572efcf306599d621609fe215e8d5347237c082b34e44acbb1`.
This proves a nonzero attached CLI process at the selected boundary. The old
runner discarded stderr; that log does not identify the cause. This change
does not retroactively diagnose or repair that native failure.

Only the existing pinned base `start --attach` call enables the private
`diagnose_start` option. Its stdout bound remains 128 bytes, its total deadline
remains 20 seconds, and the same single attempt, owned socket, empty Docker
configuration, fixed child environment and process-group cleanup apply. Both
pipes are drained concurrently. Stderr accepts at most 65,536 bytes; an extra
overflow-detection byte causes the existing static stderr-limit error before
classification. Reading, EOF and final process wait share the original
deadline. The parent is killed/reaped and both pipes are closed on every exit;
an exited parent cannot leave a descendant holding stderr past the deadline.

The complete bounded stderr is inspected only after both pipes reach EOF and
the process returns nonzero. No classification occurs on success, overflow,
I/O error or timeout. No raw stderr, path, URL, environment, token or container
identity enters the CLI diagnostic or receipt. The in-memory buffer is cleared
in `finally`; this is bounded transient handling, not a cryptographic memory
erasure guarantee. There is no retry or secondary diagnostic Docker command.

The closed, case-insensitive byte signatures are:

| Code suffix after `helper_base_` | Private signature family |
| --- | --- |
| `exec_failed` | `exec format error`, `executable file not found` |
| `permission_failed` | `permission denied`, `operation not permitted` |
| `storage_failed` | `no space left on device`, `read-only file system` |
| `daemon_unavailable` | `cannot connect to the docker daemon`, `error during connect:` |
| `container_missing` | `no such container:` |
| `wait_failed` | `error waiting for container:` |
| `runtime_failed` | Shim/OCI/runc/task-creation wrapper, only if no more specific family matched |
| `error_ambiguous` | More than one specific family matched |

A runtime wrapper and one specific family are a normal nested message, so the
specific family wins. Competing specific families remain ambiguous. Empty,
unmatched or arbitrary bytes retain `fixture_command_exit_failed`. In
particular, generic `Error response from daemon` and bare `no such file or
directory` do not establish a cause. Codes are diagnostic signatures; they do
not prove which file, container process, namespace, attach operation or daemon
operation failed and can never grant authority or convert failure to success.

Pinned primary sources justify this boundary: Docker CLI 27.5.1
[attached start](https://github.com/docker/cli/blob/v27.5.1/cli/command/container/start.go)
performs inspect, attach, wait subscription, start and stream handling, and can
also return the container's exit status;
[wait handling](https://github.com/docker/cli/blob/v27.5.1/cli/command/container/utils.go)
prints a dedicated wait-error prefix. Moby 27.5.1
[task creation](https://github.com/moby/moby/blob/v27.5.1/libcontainerd/remote/client.go),
[daemon errors](https://github.com/moby/moby/blob/v27.5.1/daemon/errors.go),
[client errors](https://github.com/moby/moby/blob/v27.5.1/client/errors.go) and
[request errors](https://github.com/moby/moby/blob/v27.5.1/client/request.go)
provide the runtime/exec/connect/missing-container families. Pinned Linux errno text is present
for both [amd64](https://github.com/moby/moby/blob/v27.5.1/vendor/golang.org/x/sys/unix/zerrors_linux_amd64.go)
and [arm64](https://github.com/moby/moby/blob/v27.5.1/vendor/golang.org/x/sys/unix/zerrors_linux_arm64.go).
These source facts do not establish the cause of run 6.

The earlier process-only option still uses `DEVNULL`. Build diagnostics retain
their separate existing matcher and byte limit; mixing build and start
selectors is rejected before spawning. Other command defaults remain the same.
The exact stdout success token and later container/image/config/state readback
remain required. This changes no Dockerfile, helper/probe, workflow, Server
runtime/API, mount/UID policy or installation grant. `installAvailable` remains
false.

## Reproducible local evidence

The isolated branch starts at the exact failed source. Runtime RED
`2d250bacbfebef46eed778fafa04986187c2b330` records 10 real child-process failures:
all reached the attached-start consumer and were flattened to the old generic
exit code. Minimal production GREEN
`c5adc673546958ebbca1229c1effc80784dfdd7f` passed all 10 in 0.31 seconds.
Final test checkpoint `0ff7e8e80a9e1d43c4fb86906c30b73a1b8c3e42` passes
32 new cases in 1.24 seconds, including exact concurrent pipe limits,
split/leading messages, ambiguity, invalid selectors, I/O/EOF deadline,
descendant cleanup, closed diagnostics and the single opt-in consumer.

The first related run had seven old mock-expectation failures (79 passed):
the attached-start mock still expected `DEVNULL`, and forwarding mocks omitted
the new default-false keyword. Only these explicit expectations changed;
the process-only `DEVNULL` and build assertions remain. The first extended
run had one malformed synthetic Python command due to newline escaping
(31 passed). Its fixture was corrected without production changes. Those
failures are preserved separately and are not additional behavioral RED proof.

Final related run: **257 PASS, zero skips, 7.70 seconds**, comprising the 32
new cases and all 225 preceding Jellyfin/helper cases. Branch-inclusive runner
plus unchanged launcher coverage is **97.28%**: 564/577 statements and 79/84
branches. Runner alone is 465/477 statements and 57/60 branches. All **215
policy tests passed in 50.194 seconds**. Security policy, syntax and diff checks
also passed. These are synthetic processes and local fixtures, not actual
native Docker acceptance. Test commands and direct child processes were
reaped; the descendant fixture verifies termination (absent or zombie), not
ownership of the operating system's later orphan-reaping step.

Independent read-only review of exact production `c5adc673546958ebbca1229c1effc80784dfdd7f`
and test checkpoint `0ff7e8e80a9e1d43c4fb86906c30b73a1b8c3e42` was **CLEAR**:
no new P1/P2 findings. The reviewer did not repeat tests or Docker/CI actions;
the final documentation commit does not change that reviewed source.

Private evidence uses `/private/tmp/larenor-jellyfin-base-stderr-`:
`source-red.log`, `minimal-green.log`, `related-initial.log`,
`related-green.log`, `extended.log`, `extended-green.log`,
`related-coverage.log`, `coverage.json` and `policy.log`. The exact frozen
commit and log hashes are recorded in `final-evidence.json` under that prefix.
No live Docker/HA/home call, CI query/download/dispatch, push or full Core
rerun was performed. New native acceptance remains a separate future gate.
