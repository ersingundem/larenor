# Keenetic host-worker production evidence — 30 September 2026

The optional unified Linux package runs the Keenetic RCI worker as dedicated
UID/GID `10008`, with supplementary IPC GID `10002`. The worker reads only
`/etc/larenor-server/host-workers/keenetic/policy.json` and its paired private
lease key. It writes only its Unix socket and authenticated health receipt in
`/var/lib/larenor-server/host-workers/ipc/keenetic`.

The policy schema is closed: version 1, adapter `rci`, and one absolute
`secretFile`. Router endpoint and account credentials remain in Core's
encrypted service store. Core issues a short-lived, one-use credential lease
only after current user, resource, service revision and component-egress
checks. The unit contains no endpoint, username, password or inline secret.

Normal Core verifies the worker-owned socket inode, group, health receipt and
live worker instance over authenticated Unix IPC. It does not trust the host
PID number from the Docker PID namespace. Before an RCI mutation, Core repeats
current authority and sends the sealed lease to the exact worker instance.
Afterward, success requires a fresh provider read with unchanged identity and a
strictly newer state revision containing the requested value.

`server/tests/test_keenetic_host_normal_core.py` starts the production worker
runtime, normal Core, a real Unix socket and an owned TCP RCI fixture. DNS and
peer pinning still expose an RFC1918 router identity; a trusted test connector
maps that identity to the owned loopback listener. The fixture accepts only the
fixed guest-network batch, returns causal RCI readback and records no credential
value. No household router is contacted.

Software evidence does not replace target-host proof. Installation must still
verify UID/GID ownership, private `0600` policy/key files, the separate
Core-owned 32-byte lease key, `0660` socket/`0640` health modes, systemd unit
loading, LAN reachability and the configured Keenetic firmware. A real router
mutation remains an explicit household manual gate.

The service hardening follows systemd's execution sandbox model, including
`ProtectSystem=strict`, explicit `ReadOnlyPaths`/`ReadWritePaths`, restricted
address families and `NoNewPrivileges`. See the upstream
[`systemd.exec`](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)
documentation. Keenetic's official command reference documents its authenticated
HTTP command interface; packaged Larenor support remains limited to the reviewed
RCI allowlist and supported firmware matrix.

Focused acceptance: 141 Keenetic tests and 9 package tests passed. This includes
normal Core, actual Unix IPC and owned TCP RCI causal success, replay without a
second POST, unchanged authoritative readback becoming unknown, and authority
revocation after dispatch becoming unknown without replay. Two production
pre-state/readback comparisons were corrected; successful mutation is accepted
only after fresh actor/ACL and immutable identity checks.

The hosted Linux test starts the actual RCI worker as UID10008, reads its
socket/health as UID10001 through the separate bind mount, and starts normal Core
with private0700 data and its own0600 key. It probes readiness without router
I/O. That test is skipped on macOS; a Linux result is still required. It verifies
real identities and composition, while the systemd asset load test verifies unit
hardening; it does not claim a production offline wheel was installed.

Keenetic primary references:

- [Official CLI command reference](https://storage.googleapis.com/docs.help.keenetic.com/cli/4.1/en/cli_manual_kn-2410.pdf)
- [Official authenticated HTTP proxy API](https://support.keenetic.com/carrier-dsl/kn-2111/en/55035-using-api-methods-through-the-http-proxy-service.html)
