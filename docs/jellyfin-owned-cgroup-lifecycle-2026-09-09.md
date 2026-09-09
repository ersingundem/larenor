# Owned cgroup lifecycle for the native Jellyfin fixture

Native run 17 (`34289499126`) used exact source
`d7b20277f510dfd656ef9f153f877f0e033c6ed0`. Both `linux/amd64` and
`linux/arm64` reached
`phase=helper_base_start code=helper_base_proc_process_net_namespace_observed`.
No success receipt or public artifact was produced.

The failed-job log was downloaded once to a private temporary path. It is
70,235 bytes and its SHA-256 is
`0db35348fe1aff1f7177b174b5e961fe206e41d4d95c93693ca6dae290b65c09`.
Repository evidence retains only that digest, byte count and the closed
phase/code pair. It does not retain the private Engine error, namespace path or
process identifier.

## Rejected process-namespace candidate

An intermediate candidate combined a private PID namespace with the runner's
procfs view. Its local tests passed, but independent review found that thread
IDs inside the PID namespace would not share the numeric view exposed by that
procfs mount. The candidate was removed before push and before native
execution. It is not part of this package.

## Owned service and cgroup layout

Commit `30a2b3b5219ea1cfd02447b3537fb5cbe2ffcb3b` replaces the PID-namespace
approach with a transient systemd service and cgroup v2 ownership boundary:

```text
/system.slice/larenor-jellyfin-<nonce>.service/
├── daemon/
└── containers/
```

The service uses `Delegate=yes`, `DelegateSubgroup=daemon`, `Type=exec`,
`ExitType=main`, `Restart=no`, `KillMode=control-group` and
`SendSIGKILL=yes`. Start and runtime are bounded by 45 seconds and 1,200
seconds. The daemon receives only a private mount namespace through
`unshare --mount --propagation=private`; it does not create a PID namespace or
mount a replacement procfs.

Dockerd uses the cgroupfs driver and the exact default parent
`/system.slice/<unit>/containers`. Every internal Docker create/run request,
including the helper and Jellyfin container, declares the same parent. The
running Jellyfin process must also report a `/proc/<pid>/cgroup` path beneath
that parent.

## Capture and cleanup contract

Ownership is published only after all of these checks succeed:

- systemd reports the exact requested unit as loaded, active, running and
  transient, with the expected invocation, control group, main PID and
  delegation properties;
- the main PID is in the `daemon` subgroup;
- the cgroup directory, `cgroup.kill` and `cgroup.events` are opened with
  no-follow/close-on-exec protections;
- the held `cgroup.events` descriptor reports `populated=1`;
- a second directory descriptor has the same inode; and
- the systemd properties and main-PID membership still match after the
  descriptors are opened.

Any mismatch closes the temporary descriptors and leaves the instance
unowned. Cleanup never scans host processes, adopts a same-name unit, prunes
Docker globally or stops a unit by name. For an owned instance it writes once
to the pinned `cgroup.kill` descriptor and waits on the same pinned
`cgroup.events` descriptor until `populated=0`. `ENODEV` is accepted only from
that already authenticated events descriptor after the owned termination was
requested; it means the empty cgroup was retired. Every other read or write
error fails closed.

If the launch response is uncertain before ownership capture, the test does
not adopt the unit. The transient service's start/runtime bounds remain the
trusted runner-side containment mechanism.

## Workflow and verification

The native workflow now requires systemd 254 or newer, cgroup v2, readable
controllers and fixed executable paths for `systemd-run`, `systemctl`,
`unshare` and `dockerd` before either architecture starts.

The final local package passes all 351 Jellyfin-focused tests and all 219
dependency-free policy tests. Python compilation, security policy checks,
queue validation and diff validation pass. Independent final review is CLEAR,
including the descriptor capture race checks and the same-descriptor retirement
rule.

The isolated locked
[Server CI](https://github.com/ersingundem/larenor/actions/runs/34293524785)
passed all 4,027 tests with two warnings on exact source `30a2b3b`.
The promoted exact source then passed the
[main Server Container workflow](https://github.com/ersingundem/larenor/actions/runs/34294585502):
4,027 tests, both native architecture image builds and smoke tests, immutable
architecture publication and final manifest promotion.

## Native result

[Native run 18](https://github.com/ersingundem/larenor/actions/runs/34294788670)
passed on exact promoted source `6a054ea7ca5243d80e1340a70fc75401daa8e3e7`:

| Platform | Job duration | Artifact | Receipt SHA-256 |
| --- | ---: | --- | --- |
| `linux/amd64` | 2m16s | `jellyfin-storage-6a054ea7ca5243d80e1340a70fc75401daa8e3e7-X64` | `bcad2aa38eca3b6ea8fa7426352d89fb29356daf1c308fb9d47724e226f1bb0f` |
| `linux/arm64` | 1m31s | `jellyfin-storage-6a054ea7ca5243d80e1340a70fc75401daa8e3e7-ARM64` | `e37fc9742acf475dee6b517e613e3113b65db79e0ec670c8e1b43e51f92b3193` |

Each public receipt is 1,753 bytes. The repository verifier independently
accepted both downloaded receipts against the local exact checkout and their
declared platform. Both report two owned volumes, one container restart, a
ready pinned image and `observed_requires_bootstrap` for both appdata targets.
They preserve `bootstrapAccountConfigured=false` and
`installAvailable=false`.

This closes the two-architecture native acceptance for S06.3d. Account
bootstrap, operator installation authority, the complete media-resource
receipt in S06.3f, a real home deployment and physical-device acceptance
remain separate gates.
