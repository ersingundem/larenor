# F08 standalone AI runtime evidence — 2026-09-30

F08 is an admission and execution boundary for local AI work. It does not
accept an executable, model path, URL, image path, environment variable, or
command argument from the Client. A private administrator-owned catalog binds
each supported job kind to one fixed standalone executable and exact SHA-256
identities for that executable and its model/artifact files. Missing or invalid
configuration is reported as `workerUnavailable`; queued rows remain queued.

Normal deployment keeps systemd authority on the host. Core never receives the
private provider catalog and does not bind the host D-Bus: it calls a dedicated
UID 10003 host worker through a mode `0660`, GID 10002 Unix socket. Both ends
check `SO_PEERCRED`; the worker accepts only Core UID 10001 and Core checks the
socket owner and group before every request. The worker uses the UID 10003 user
manager at `/run/user/10003/bus`; it does not receive root or unrestricted
polkit authority. Missing linger, user bus, controller delegation, socket, or
provider identity leaves the capability unavailable.

The reviewed host package installs `larenor-ai` as UID/GID 10003, adds only
supplementary IPC GID 10002, and creates these fixed paths:

- private catalog: `/etc/larenor-server/host-workers/ai/runtime.json`, owner
  10003 and mode `0600`;
- runtime state: `/var/lib/larenor-server/host-workers/ai`, owner 10003 and
  mode `0700`;
- host socket: `/var/lib/larenor-server/host-workers/ipc/ai/runtime.sock`;
- Core socket: `/run/larenor-workers/ai/runtime.sock`.

The catalog must select `manager: "user"`, `/usr/bin/systemd-run`,
`/usr/bin/systemctl`, the fixed state directory, and at least one real
standalone provider whose executable and every model artifact have exact
SHA-256 values. The package never creates that private catalog or chooses a
model. Explicit package activation enables linger for `larenor-ai`, starts
`user@10003.service`, checks the private catalog through that user bus, and
only then enables `larenor-ai-worker.service`. Normal Core composition carries
only the socket, UID, and GID; it has no provider path or D-Bus mount.

The worker runs each job as a transient systemd service, so the provider process and all
of its children share the same cgroup. The service is created with `CPUQuota`,
`MemoryMax`, `MemorySwapMax=0`, `TasksMax`, and `RuntimeMaxSec`, plus a private
network and restricted filesystem view. This does not claim that a separate
Ollama or other daemon is bounded: production providers must perform inference
inside the launched service. The provider unit cannot access the user-manager
bus path, so it cannot create a sibling transient unit outside its assigned
cgroup. The runtime reads `MemoryPeak`, `CPUUsageNSec`,
exit status, and systemd result from the exact unit. A successful job also
requires a provider receipt and output file whose job, dispatch, provider,
length, and SHA-256 all match. `RemainAfterExit` keeps a fast successful unit
observable until that receipt is committed; a separate durable `released_at`
step then stops and releases the transient unit.
After the terminal receipt is stored, release removes only the three exact
dispatch-owned descriptor/output/receipt names and fsyncs the private state
directory; the durable DB receipt retains metrics and the output digest.

The persistent lifecycle is:

1. Reserve one dispatch in SQLite before OS I/O.
2. CAS `reserved` to `starting` before `systemd-run`.
3. Read the exact systemd unit after start and on the background dispatcher.
4. Persist observed `running`, terminal, cancelled, or uncertain status.

A restart may safely start a still-`reserved` row because the pre-I/O CAS never
happened. A `starting` row is only observed; it is never submitted again, so a
lost acknowledgement cannot duplicate provider work. A reserved row can be
cancelled locally without contacting systemd. Cancellation of an attempted
dispatch persists intent before `systemctl stop` and then records readback.

The focused local gate is:

```text
cd server
uv run pytest -q \
  tests/test_f08_systemd_runtime.py \
  tests/test_f08_ai_worker_ipc.py \
  tests/test_f08_ai_runtime_dispatch.py \
  tests/test_f08_f11_final.py
```

On the macOS development host this executes the real standalone fixture
process and verifies its durable output/receipt, plus the exact systemd command
and state machine using a bounded control-process fixture. The Linux-only test
is skipped honestly because this host has no systemd or cgroup v2 service
manager.

The mandatory Linux deployment gate is opt-in:

```text
cd server
LARENOR_F08_SYSTEMD_ACCEPTANCE=1 \
  uv run pytest -q \
  tests/test_f08_ai_worker_ipc.py::test_actual_uid10003_user_manager_runs_through_uid10001_ipc
```

That gate creates the same unprivileged user-manager boundary as deployment,
starts the host worker as UID 10003, and calls it from a UID 10001 process with
only supplementary IPC GID 10002. The provider is a real process in the user
manager cgroup; the client requires its terminal metrics and verified receipt,
then releases the exact unit. Deployment remains unavailable until this gate
passes on the target Linux host with delegated CPU, memory, and pids controllers.
The fixture proves the process boundary only; it is deliberately not presented
as inference or a supported production model.

CI runs the same test as the isolated `f08-linux-cgroup` job in
`.github/workflows/server-test.yml`. Root is used only to create the isolated
UIDs, groups, and linger user manager; the worker and transient provider remain
UID 10003 and the client remains UID 10001. The required
`server-test` aggregate fails unless that job passes, and the test verifies the
transient unit is collected and its private dispatch files are removed.

Primary contracts:

- Linux cgroup v2 defines `memory.max` as the hard memory limit and `cpu.max`
  as the CPU bandwidth limit: <https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html>
- systemd resource control maps `CPUQuota`, `MemoryMax`, `MemorySwapMax`, and
  `TasksMax` to the unit cgroup:
  <https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html>
- `systemd-run` creates a transient service and accepts unit properties before
  the executable starts:
  <https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html>
- `systemctl show` and `stop` provide bounded unit readback and cancellation:
  <https://www.freedesktop.org/software/systemd/man/latest/systemctl.html>
- `loginctl enable-linger` starts a user manager at boot and keeps it after the
  last login session ends:
  <https://www.freedesktop.org/software/systemd/man/latest/loginctl.html>

## First actual Linux CI preparation correction

Exact `d8f17838f` run `36737286388` stopped before the IPC test in user-manager
preparation. The untraced log does not prove which command stopped. Review
found a definite permission bug: the runner attempted `test -S` inside the
UID10003 mode0700 runtime directory. The check now runs under sudo, manager
startup is bounded/nonblocking, and a failed readiness check prints unit
status/journal. actionlint and focused workflow policy passed; a changed exact
commit run is needed to establish actual IPC/cgroup acceptance.

## Actual Ubuntu managed-Python düzeltmesi

Exact `e2da860e1` Server koşusu `36738496557` gerçek UID10003 user manager bus aşamasını geçti. Worker başlangıcı uv managed CPython stdlibine erişemedi (`ModuleNotFoundError: encodings`). CI sadece venv izinlerini açıyordu; managed Python kurulumunun okuma/geçiş izinleri de worker için açıldı. Bu uygulama sonucu veya yeşil Linux kabulü değildir; değişmiş HEAD tekrar actual Linux kapısına gönderilir.

Exact `2c07cca6c` actual Linux run `36740147929` user manager ve izin adımlarını geçti; venv ile managed Python `/home/runner` altındaki RUNNER_TEMPte olduğundan farklı UID üst dizini geçemedi. Yeni CI bu iki runtimeı `/tmp` altında kurar ve pytestten önce actual UID10003 ile `import encodings; import larenor_server` çalıştırır. Provider fixture ve state de `/tmp` altındadır. Linux kabul sonucu hâlâ açık; aynı SHA rerun edilmedi.

Exact `daa0ea819` scoped run `36743289498` proved the dedicated user manager,
UID 10001 to UID 10003 IPC, provider identity, terminal success, and verified
output receipt. It then failed because the acceptance test incorrectly required
the observed `MemoryPeak` to be no greater than `MemoryMax`. The Linux cgroup v2
contract says `memory.max` is the hard limit but usage may temporarily exceed it;
`memory.peak` records the maximum observed usage. The gate therefore requires a
positive bounded scalar metric and separately verifies the exact live
`MemoryMax`, `MemorySwapMax`, `TasksMax`, and CPU quota properties. A later exact
run is still required for a green result.

## Actual cgroup stress gate

The same mandatory hosted Linux job now also runs
`test_actual_user_manager_enforces_memory_pids_and_cpu_throttle_over_ipc`.
Three owned fixture providers deliberately exceed 64 MiB memory, fork beyond
TasksMax=8, and perform CPU work under CPUQuota=20%. Acceptance requires kernel
`memory.events` OOM/kill evidence, `pids.events` denial evidence, and actual
`cpu.stat` throttling with exact `cpu.max` readback. It also requires terminal
IPC results and subsequent unit/cgroup removal. Local execution recorded
17 passes and 3 explicit Linux skips; the actual stress result is still open.
Manual F08 and host diagnostics have separate concurrency groups, so one does
not cancel the other. Full required Server acceptance still includes both jobs.
