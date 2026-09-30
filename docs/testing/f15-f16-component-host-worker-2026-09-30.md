# F15/F16 component host-worker deployment proof (2026-09-30)

F15 verified component updates and F16 component-aware recovery drills now use the
existing privileged component worker in the unified Linux deployment. Core keeps
no Docker socket. The host worker exposes only the bounded component protocol at
`/run/larenor-workers/root/component-backup.sock`, accepts the exact Core peer
UID `10001`, and publishes its socket for IPC group `10002`.

## Root boundary and fixed configuration

The component worker deliberately runs as host root. This is a bounded privileged
role rather than a general worker identity: production composition requires the
initial user namespace, `CAP_SYS_ADMIN`, a root-owned Btrfs executable, the
root-owned Docker Unix socket and the existing root-owned installation journals.
Docker documents that access to the daemon socket grants root-level authority;
assigning a nominal non-root UID through the `docker` group would not reduce that
authority. The service therefore keeps the real privilege visible and limits its
inputs to the current installation receipts, packaged catalog, fixed Btrfs
capture root, current Docker peer identity and exact Core IPC peer.

The production paths are fixed:

- component socket: `/var/lib/larenor-server/host-workers/ipc/root/component-backup.sock`;
- resource, volume and container journals:
  `/var/lib/larenor-server/host-workers/installation/{resources,volumes,containers}`;
- COW state: `/var/lib/larenor-server/host-workers/component-backup/captures`
  and `capture-journal.json`;
- engine: root-owned `/var/run/docker.sock`;
- snapshot executable: root-owned `/usr/bin/btrfs`.

Both the installation and component services run the fixed journal-set verifier
before opening their main runtime. The component worker then performs the
existing live source reconstruction, exact update-command validation, durable
update intent, rollback snapshot, Docker readback and restart reconciliation.
Recovery drills consume the same authenticated component capture through normal
Core and restore its bounded archives only in an effect-disabled temporary Core.

## First-install journal authority

A clean unified host previously created three empty journal directories with
`systemd-tmpfiles`. The journal classes intentionally refuse to initialize an
already existing empty directory, so neither installation nor component startup
could succeed. The package now creates only the root installation state
directory. Explicit `install.py --activate` runs
`larenor-installation-journals initialize` before enabling any unit.

Initialization writes a durable intent before the first journal. This permits a
crash between the three creations to resume. It then validates all three stores
and atomically publishes `journal-set.json` with their independent identities.
Once that receipt exists, verification and later activation never recreate a
missing or replaced store. A partial set without the initialization intent, a
corrupt receipt, policy drift, Docker endpoint drift or journal identity drift
fails with one static error.

The helper also requires `root/installation.json` to bind the exact fixed journal
paths and `/var/run/docker.sock` owner UID `0`. The installation worker still
performs its complete private policy validation; the helper only adds the
cross-service binding needed because the component worker consumes those same
receipts.

## Evidence and remaining manual limits

Automated evidence includes:

- `server/tests/test_installation_journal_set.py`: fresh initialization,
  restart verification, crash-intent resumption, no regeneration after history
  loss, and fixed policy binding;
- `server/tests/test_component_worker_normal_core.py`: normal configured Core,
  authenticated API, real AF_UNIX component server, backup plan and verified
  component-update inventory;
- `server/tests/support/f15_component_worker_ipc.py` through
  `server/tests/test_host_worker_systemd_linux.py`: hosted Linux root worker to
  Core UID `10001` kernel peer credentials and group-gated socket access;
- the existing component worker runtime/server, update rollback/recovery,
  component restore and recovery-drill tests;
- the existing amd64/arm64 native Btrfs workflow for read-only snapshot,
  interrupted startup recovery and release.

The local focused batch passed 54 tests with the hosted root/systemd case
explicitly skipped on macOS; the package/bundle/deployment batch passed 19 tests.
The mandatory hosted Linux gate must run the skipped unit and the existing native
Btrfs matrix before release.

No test here claims a household Docker mutation. The selected host must still
prove its actual `dockerd` executable/PID/socket, Btrfs mount topology and free
space. An administrator-triggered component update remains an explicit action;
a missing Docker readback, rollback proof or journal identity produces an
error/needs-attention result rather than a retry or success.

Primary references:

- Docker Engine security and daemon socket authority:
  <https://docs.docker.com/engine/security/> and
  <https://docs.docker.com/engine/install/linux-postinstall/>;
- Btrfs read-only snapshot and deletion commands:
  <https://btrfs.readthedocs.io/en/latest/btrfs-subvolume.html>;
- systemd service identity and filesystem access controls:
  <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>.
