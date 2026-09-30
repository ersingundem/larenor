# F18 production power recovery evidence — 2026-09-30

## Supported production boundary

Larenor accepts UPS state only from the packaged NUT bridge. `upsmon` invokes
the fixed `/usr/libexec/larenor-nut-notify` helper for `ONLINE`, `ONBATT`, and
`LOWBATT`. The helper sends only `UPSNAME` and `NOTIFYTYPE` over the private
Unix socket. The UID 10006 bridge verifies the NUT peer UID, durably reserves
the event in a SQLite WAL/FULL outbox, reads the configured UPS through the
SHA-256-pinned `upsc` executable, and posts the fixed authenticated Core
contract. A lost HTTP acknowledgement retries the identical persisted body and
sequence without another UPS read. Expired or conflicting head events block
the FIFO instead of skipping sequence numbers.

The Proxmox executor is the packaged UID 10005 worker. Its encrypted binding
contains the exact Core resource, service, binding and guest revisions plus the
pinned endpoint and token. Core sees only `/run/larenor-workers/proxmox`, checks
the socket owner/group/mode, the bounded health receipt owner/group/mode and
socket device/inode, then verifies the worker UID again with Unix peer
credentials on every request. The worker supports a fixed current-status GET
and the bounded power verbs already authorized by the Core preview/confirmation
journal. It accepts no command, URL, file, or credential from the wire.

## Package contract

- Core UID: 10001; shared IPC GID: 10002.
- Proxmox worker UID/GID: 10005; NUT bridge UID/GID: 10006.
- Host IPC: `/var/lib/larenor-server/host-workers/ipc/proxmox`.
- Core IPC: `/run/larenor-workers/proxmox`.
- Proxmox private files: `credential.bin` and `binding.key`, both mode 0600,
  owner 10005 under `/etc/larenor-server/host-workers/proxmox`.
- NUT private config: mode 0600, owner 10006 at
  `/etc/larenor-server/host-workers/power-recovery/nut-bridge.json`.
- NUT state: owner 10006 under
  `/var/lib/larenor-server/host-workers/power-recovery`.

Activation fails closed unless all private files, identities, supplementary
groups, pinned executables, CA digest, exact `MONITOR`, `NOTIFYCMD`, and EXEC
flags are present. After first installation of the `nut` to `larenor-power`
group membership, the operator must restart the NUT monitor so its existing
process receives the new supplementary group before a real notification gate.

## Evidence and remaining manual gates

Focused synthetic validation covers durable reservation/restart, exact-body
lost-ack retry, stale-event blocking, source revision conflicts, fixed `upsc`
execution, authenticated TLS delivery to a normal Core, private notification
IPC, Proxmox observation/effect IPC, health/inode binding, and normal Core
composition. The hosted Linux gate additionally runs UID 10005 to UID 10001
through the production ancestor ownership and GID 10002 boundary. No household
UPS or Proxmox mutation is part of automated acceptance.

Manual production acceptance remains sequential: provision the exact current
Core target revisions and Proxmox token into the sealed worker binding; verify
read-only current-status observation; restart NUT monitoring after group
provisioning; inject one documented NUT test notification; verify the Core
sequence/readback; then separately confirm one maintenance-window Proxmox
action with out-of-band console access.

Primary contracts:

- NUT `upsmon` NOTIFYCMD and EXEC behavior:
  <https://networkupstools.org/docs/man/upsmon.html>
- NUT `upsmon.conf` MONITOR/NOTIFY configuration:
  <https://networkupstools.org/docs/man/upsmon.conf.html>
- NUT instantaneous variable names:
  <https://networkupstools.org/docs/developer-guide.chunked/apas01.html>
- Proxmox VE guest status API schema:
  <https://pve.proxmox.com/pve-docs/api-viewer/index.html>
