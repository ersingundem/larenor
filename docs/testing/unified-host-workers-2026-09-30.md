# Unified host workers: Linux packaging and authority proof (2026-09-30)

This slice packages the already implemented F22/F25/F27/F28/F29 installation
backend and the F30 archive worker as optional host services. It deliberately
does not put Docker mutation authority in the Core container. The preflight and
installation processes run on the Linux host, retain the existing Docker Unix
socket, daemon executable and peer PID checks, and expose only their bounded IPC
contracts to Core.

## Fixed identity and filesystem layout

The unified Core remains UID/GID `10001:10001`. The archive process and Unmanic
run as the media library owner UID/GID `1000:1000`. The installer creates the
non-secret IPC group `larenor-ipc` with GID `10002`; Core receives this one
supplementary group. Kernel Unix peer credentials still require the exact
service UID, so group access alone cannot impersonate Core or a worker.

The bridge reuses the existing private Core `/data` bind instead of adding a new
persistent mount:

- host: `/var/lib/larenor-server/host-workers/ipc`
- Core container: `/run/larenor-workers`
- root worker sockets: `root/preflight.sock`, `root/installation.sock`
- archive sockets: `archive/archive-read.sock`, `archive/archive-action.sock`
- Core authority socket: `core/archive-authority.sock`

Socket directories are owner-specific mode `0750`; sockets are mode `0660`,
group `10002`. Peer UID validation is unchanged. This placement preserves the
existing exact private-mount upgrade receipt.

The four authenticated F30 read endpoints are published only on host loopback:
Jellyfin `8096`, Sonarr `8989`, Radarr `7878`, and qBittorrent WebUI `8080`.
The archive collector itself permits only `127.0.0.1` and the exact ports from
the verified deployment plan. These bindings are required because the worker
runs in the host namespace; no service API is exposed on a LAN interface.

Root mutation state is under
`/var/lib/larenor-server/host-workers/installation`. Archive state is under
`/var/lib/larenor-server/host-workers/archive`. Operator policy is under
`/etc/larenor-server/host-workers`; every private file is mode `0600` and owned
by the service UID. The installer never creates policy, keys or credentials.

## Offline package and activation

`build_bundle.py` copies a pre-resolved wheelhouse into a new bundle and records
every wheel SHA-256. The server wheelhouse must contain `larenor-server` and all
of its locked runtime dependencies. The Unmanic wheelhouse must contain Unmanic
`0.4.1` built from upstream revision
`1c324b8fc3974ffce3d7cc945adb938fe7182910` and all of its dependencies. The
installer uses `pip --no-index --no-deps`, then `pip check`; installation cannot
resolve or download packages.

Example from an exact checkout, after the two reviewed wheelhouses have been
built:

```bash
python3 deploy/larenor-server/host_workers/build_bundle.py \
  --server-wheels /secure/build/server-wheels \
  --unmanic-wheels /secure/build/unmanic-wheels \
  --source-revision "$(git rev-parse HEAD)" \
  --platform linux/amd64 \
  --output /secure/build/larenor-host-workers
sudo python3 deploy/larenor-server/host_workers/install.py \
  --bundle /secure/build/larenor-host-workers/bundle.json --check
sudo python3 deploy/larenor-server/host_workers/install.py \
  --bundle /secure/build/larenor-host-workers/bundle.json --install
```

Installation is non-activating. It verifies hashes, creates isolated server and
Unmanic virtual environments, generates the two deterministic Larenor plugin
archives, installs the exact sysusers/tmpfiles/systemd assets, and atomically
selects the release. It does not start a service.

Before activation the administrator must create these exact files:

- root-owned: `root/preflight.json`, `root/installation.json`
- UID 1000-owned: `archive/runtime.json`, `archive/resolver.json`,
  `archive/callback.key`, `archive/encoder.json`, `archive/callback.json`

The preflight policy must be version 3 with the real `/var/run/docker.sock`,
the observed socket owner, `/usr/bin/dockerd`, and one to sixteen approved host
roots. The installation policy uses the same Docker identity, a current worker
policy binding, exact bootstrap image digest, and the three installed journal
directories. `--activate` invokes every worker's non-mutating `--check-config`
path before it enables units.

The archive runtime schema is `schemaVersion: 1` plus
`resolverCatalog`, `readSocket`, `actionSocket`, `authoritySocket`, `coreUid`,
`unmanicPort`, `callbackPort`, `journalRoot`, `terminalRoot`, `callbackKeyFile`,
`ffmpeg`, `ffprobe`, `quotaBytes`, and `socketGid`. For this package `coreUid` is
`10001`, `socketGid` is `10002`, and the worker-side socket paths use the host
IPC root above. The resolver catalog binds the private store/work/retained
roots, a raw 32-byte authentication key, and each approved Jellyfin root to its
real host library root. Caller supplied paths are never accepted.

Activation provisions the deterministic encoder and terminal callback ZIPs via
Unmanic's own `PluginsHandler.install_plugin_from_path_on_disk` API before the
loopback service starts. The operator must then configure exactly one Unmanic
library whose path equals the resolver `workRoot`, enable exactly
`larenor_archive_encoder` and `larenor_archive_terminal`, and keep scanning and
inotify disabled for the isolated work-copy library. The packaged unit fixes
Unmanic's config, cache, plugin, log, userdata and isolated work library paths
under the UID 1000 archive state root. The archive worker refuses
to expose action IPC until that live readback and both FFmpeg executables pass.

```bash
sudo python3 deploy/larenor-server/host_workers/install.py --activate
```

## Validation and remaining manual evidence

Local focused evidence:

- Focused media archive/Core IPC and runtime tests passed; three Linux-only UID/systemd cases are intentionally skipped on macOS.
- 56 package, deployment, bundle and workflow gates passed before F08 AI packaging additions.
- Both historical native-capacity acceptance tests passed after binding CURRENT_REVISION to the exact checked-out HEAD. This revision is available even in a shallow final-squash checkout; the historical BASE remains fixed. A deleted feature branch object is never required.

The hosted `linux/amd64` and `linux/arm64` matrix now installs the server
environment, runs the real forked UID 1000/10001 AF_UNIX + kernel peer credential
test, copies the exact production unit files into systemd, verifies them with
`systemd-analyze verify`, and confirms systemd reports each unit loaded. This is
in addition to the existing real Docker install/upgrade/restart receipt chain.

Still manual, and therefore not claimed by this slice:

- building the reviewed Unmanic wheel at the pinned upstream revision on each
  target architecture;
- the target host's real Docker daemon executable/PID/socket identity;
- the selected UID 1000 library mounts, free space and media files;
- administrator policy, service credentials and Unmanic library configuration;
- an actual archive encode on the target CPU/FFmpeg build.

## Primary-source basis

- Docker warns that daemon access can grant host-level authority and documents
  rootless/user-namespace alternatives: <https://docs.docker.com/engine/security/>.
- systemd defines `User=`, `SupplementaryGroups=`, filesystem protection and
  read/write path allowlists in `systemd.exec`:
  <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>.
- Unmanic's pinned source exposes `--address`, `--port`, plugin management and
  local plugin installation at revision `1c324b8`:
  <https://github.com/Unmanic/unmanic/tree/1c324b8fc3974ffce3d7cc945adb938fe7182910>.
- Unmanic's official Docker deployment documents separate configuration, cache
  and library mounts: <https://docs.unmanic.app/docs/installation/docker>.

## Stable venv installation path

Pip console scripts record their interpreter using an absolute shebang. The installer formerly created a venv in a temporary release directory and then renamed it, leaving these paths stale. Python explicitly documents that venvs are not movable ([official Python 3.12 documentation](https://docs.python.org/3.12/library/venv.html)). The installer now builds at the final private release path, executes all installed worker `--help` entrypoints before publishing the receipt, and changes only the current symlink after validation. Existing receipts are also checked by executing the installed entrypoints.

`python3 -m unittest tool.tests.host_worker_release_paths_test -v`: 1 passed. This uses real offline pip, venvs and executable console scripts from tiny path-fixture wheels; it verifies activation through the current symlink and reproduces rejection of a relocated venv. These wheels are explicitly test fixtures, not provider evidence. The full production offline bundle install and real host service activation remain Linux acceptance gates. An interrupted final directory without a valid receipt fails closed; this change does not silently recreate existing or corrupt releases.

The target host must provide a root-owned, non-symlink `/opt` whose group and
other write bits are clear. The installer verifies every release ancestor and
does not repair an unsafe host filesystem. GitHub's disposable hosted Linux
image currently provides a root-owned but writable `/opt`; the hosted-only
acceptance fixture opens that exact directory with `O_NOFOLLOW`, verifies its
UID, GID and inode through the descriptor, and normalizes only its mode to
`0755` before exercising the unchanged production installer.

## Separate IPC mount correction

Core data and secrets retain UID10001 mode0700. Host workers cannot traverse that private directory. Shared IPC is therefore bound separately from `/var/lib/larenor-server/host-workers/ipc` to `/run/larenor-workers`, with root-owned mode0750 GID10002 parent and owner-specific child directories. The host-worker parent is root-owned0711; private journals remain0700. Core needs narrow write access for its authority socket; it receives no host Docker socket. Linux hosted acceptance starts normal Core against private0700 data and the separate mount; macOS cannot prove cross-UID/systemd behavior.

## Integral Core clock restart correction

Exact `8b0de547afcdd71cd390e41101bee76752dd21cd`, hosted run `36760057118`, passed production bundle installation and reached the actual installed Core IPC proof. The second Core startup failed with `resource_reservation_catalog_invalid`: the prior mesh fixture uses an integral clock, while SQLite REAL columns read its timestamps back as floats. The catalog had hashed JSON `2000` before storing JSON `2000.0` on read. Both default catalog creation and catalog mutation now normalize timestamps to float before signing. Verification remains strict; no stored hash is recomputed or silently repaired. Two normal-Core restart/command-replay regressions and the existing F40 suite passed (12 tests). The next exact hosted Linux gate remains required.

## Hosted cleanup correction

Exact `b23e543ee30f064ad779d37cc45f7050f7125a16`, hosted run `36760951195`, passed all four installed-Core, cross-UID IPC and systemd acceptance tests. The job nevertheless failed in its EXIT trap because subprocesses had written root-owned bytecode beneath the runner-owned disposable source tree. Cleanup now uses noninteractive sudo only for the exact freshly allocated `/tmp/larenor-host-proof.XXXXXX` tree, with `--one-file-system`; it preserves a prior test failure status and treats cleanup failure as failure. Installer and worker permission checks are unchanged. Bash syntax and the existing workflow policy suite passed; a new exact hosted run is still required.

## Exact hosted Linux acceptance result

[Run 36762186381](https://github.com/ersingundem/larenor/actions/runs/36762186381) completed successfully at exact commit `888dfd46f197808f91eaf0f85a4878e15ed27f8e`. The real production offline bundle, installed Core, four cross-UID IPC/systemd acceptance tests and disposable cleanup passed. This closes the named host gate at that commit; it does not assert broad CI success for later branch commits or physical provider acceptance.
