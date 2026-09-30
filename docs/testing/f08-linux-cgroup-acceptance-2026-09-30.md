# F08 hosted Linux cgroup acceptance — 2026-09-30

## Accepted revision and run

- Git revision: `09a912b4002f062757583df24f499731f507432c`
- Workflow run: [Server API & Storage Tests 36750577813](https://github.com/ersingundem/larenor/actions/runs/36750577813)
- Job: `f08-linux-cgroup` (`110007863246`)
- Result: successful on the GitHub-hosted Linux runner

The job ran these committed acceptance cases as root only to create the isolated
test identities and cgroup environment:

- `test_actual_uid10003_user_manager_runs_through_uid10001_ipc`
- `test_actual_user_manager_enforces_memory_pids_and_cpu_throttle_over_ipc`

## Evidence established

The gate created the dedicated AI worker user manager as UID 10003 and called it
through the real Unix socket boundary from Core UID 10001 with IPC GID 10002.
The worker launched actual transient user-manager units through the production
runtime rather than an injected provider.

The stress cases observed kernel cgroup v2 state for each exact transient unit:

- `memory.max` caused a real OOM kill and Core reported a failed
  `resource_limit` result without an output receipt;
- `pids.max`/`TasksMax` rejected excess child processes and Core reported a
  failed provider result without an output receipt;
- `cpu.max` was `20000 100000`, `cpu.stat` recorded throttling, and the bounded
  provider still completed with a verified output receipt;
- release removed the durable dispatch files and the failed transient unit and
  cgroup were collected after the exact-unit `reset-failed` path.

The companion IPC case also proved that the production user-manager sandbox can
start and observe a normal bounded provider after removing only the unsupported
`ProtectKernelModules=` request from unprivileged user-manager jobs. System
manager jobs retain that property.

## Evidence limits

This gate used committed synthetic providers and isolated GitHub-hosted Linux
users. It did not contact household devices, accounts, models, or services. It
proves the Linux UID, Unix socket, systemd user-manager, cgroup enforcement,
receipt, and cleanup boundaries. It does not establish model quality, hardware
accelerator support, household deployment configuration, or performance on the
target host. Those remain deployment or device-specific evidence.
