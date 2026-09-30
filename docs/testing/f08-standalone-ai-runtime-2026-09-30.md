# F08 standalone AI runtime evidence — 2026-09-30

F08 is an admission and execution boundary for local AI work. It does not
accept an executable, model path, URL, image path, environment variable, or
command argument from the Client. A private administrator-owned catalog binds
each supported job kind to one fixed standalone executable and exact SHA-256
identities for that executable and its model/artifact files. Missing or invalid
configuration is reported as `workerUnavailable`; queued rows remain queued.

The worker runs as a transient systemd service, so the provider process and all
of its children share the same cgroup. The service is created with `CPUQuota`,
`MemoryMax`, `MemorySwapMax=0`, `TasksMax`, and `RuntimeMaxSec`, plus a private
network and restricted filesystem view. This does not claim that a separate
Ollama or other daemon is bounded: production providers must perform inference
inside the launched service. The runtime reads `MemoryPeak`, `CPUUsageNSec`,
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
  tests/test_f08_systemd_runtime.py::test_actual_systemd_cgroup_runs_standalone_provider_and_reads_receipt
```

That gate uses the actual configured systemd manager, launches the standalone fixture
as a real process, reads back `MemoryMax`, `MemorySwapMax`, `TasksMax`, and
`CPUQuotaPerSecUSec`, then requires nonzero CPU accounting, bounded peak memory,
and a verified provider receipt. Deployment remains unavailable until this gate
passes on the target Linux host with delegated CPU, memory, and pids controllers.
The fixture proves the process boundary only; it is deliberately not presented
as inference or a supported production model.

CI runs the same test as the isolated `f08-linux-cgroup` job in
`.github/workflows/server-test.yml`. The hosted Ubuntu runner uses the system
manager under `sudo` only for this synthetic fixture. The required
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
