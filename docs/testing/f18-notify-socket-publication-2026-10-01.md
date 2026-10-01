# F18 NUT notification socket readiness publication — 1 October 2026

## Defect

`NutBridgeRuntime` previously bound the canonical filesystem pathname before
changing the socket to mode `0660` and before calling `listen()`. The production
sender validates the socket owner, group and exact mode before connecting. A
sender scheduled between those operations therefore returned
`bridge_unavailable`, even though the worker completed startup immediately
afterward. The broad Server gate observed this race in
`test_notify_ipc_ack_means_durable_enqueue_and_filters_environment`.

This is a real notification-loss window: a NUT `NOTIFYCMD` callback is a
one-shot producer and cannot treat pathname existence as readiness.

## Repair

The runtime now binds an unguessable temporary AF_UNIX pathname in the same
owned `0770` directory. It validates the bound socket identity, applies exact
mode `0660`, calls `listen()`, and only then atomically replaces the canonical
pathname. The canonical path is therefore either absent or points at a ready
listener; it is never the partially configured socket.

The existing trust boundary remains strict:

- the parent must be the exact current-UID/current-GID `0770` directory;
- an existing canonical entry must be a single-link socket owned by the current
  UID/GID with exact mode `0660`; symlinks and wrong-mode entries fail closed;
- the temporary and published entries must retain the same device/inode and
  exact owner, group, mode and link count;
- shutdown removes the canonical entry only when its full published identity,
  including `ctime`, still matches. A successor socket is never unlinked.

No sender deadline, notification schema, durable enqueue rule, peer-credential
check or retry behavior changed.

## TDD evidence

The new regression pauses the runtime immediately after the real AF_UNIX bind
and starts the production sender as soon as the canonical path appears. Against
the old implementation the sender deterministically observed the premature
path and failed:

```text
server/.venv/bin/pytest -q \
  server/tests/test_f18_nut_bridge.py::test_notify_socket_path_is_published_only_after_listener_is_ready
# 1 failed: NutBridgeError('bridge_unavailable')
```

With atomic publication, the same sender sees the canonical path only after the
listener is ready and the durable outbox contains exactly one notice. The final
focused gate was:

```text
server/.venv/bin/pytest -q \
  server/tests/test_f18_nut_bridge.py \
  server/tests/test_f18_nut_normal_core.py
# 19 passed, 1 existing Linux-only skip
```

The focused tests also reject wrong-mode and symlink canonical entries and
prove that closing an old runtime leaves a replacement socket identity intact.
The local run exercised filesystem AF_UNIX rename on macOS. Changed-source Linux
CI remains required before this evidence can be treated as cross-platform
acceptance; no physical UPS or household service was used.

Independent root verification: the notification suite, normal-Core suite and
new offline hold suite passed 28 tests with one existing Linux-only skip.
Pinned Ruff 0.14.1 passed for both edited Python modules. Root private output
is `/private/tmp/larenor-root-verify-20261001/f18-publication.log` and
`f18-publication-ruff.log`.

A separate reviewer confirmed the current owned-directory/single packaged
runtime composition. The existing worker lock is source-specific: supporting
multiple differently configured workers at the same canonical socket would
require a canonical-path-global lock. The current deployment has one worker.
