# S09.1 managed component volume provider

Date: 23 September 2026

This stacked slice supplies the read-only volume-capture boundary behind the
private component worker. It deliberately does not wire a Docker daemon or an
installation-journal implementation into production yet, and it does not close
S09.1.

## Three delivered jobs

1. **Deterministic bounded archive.** Catalog-managed directories are opened
   from `/` through descriptor-relative `O_NOFOLLOW` traversal. Snapshot ZIPs
   use fixed metadata and sorted entries, reject links, hardlinks, special
   files, path replacement and directory mutation, and enforce entry, depth,
   deadline, per-volume and aggregate byte limits.
2. **Exact quiescence ownership.** Each unique service container is paused once
   in sorted order and every dispatched pause is reconciled in reverse order,
   including a timeout or exception after the pause side effect. Capture or
   consumer failure still attempts every unpause without exposing controller
   details.
3. **Installed-authority binding.** Every source carries the exact installed
   service/schema versions, installation revision and directory inode. A
   required private authority revalidates the complete immutable source set
   before pause, after capture and again after the consumer finishes while the
   containers remain paused. Shared containers, incomplete service volume
   sets, nested/aliased paths, catalog drift, path swaps and release-time
   authority drift fail closed.

## RED and GREEN evidence

- `d0a65ffa` defined archive, rollback and bound requirements before the module
  existed; `0b652611` implemented the first provider.
- Independent review found uncertain pause, unbound installation metadata and
  pre-capture path-swap gaps. `3026a109` reproduced them; `09b1f835` bound the
  provider to exact installed authority and inode identity.
- Review then found authority could drift while the consumer held the snapshot.
  `5b4337e2` reproduced that exit race; `503f97ce` added the final pre-release
  revalidation. The worker server separately delays its `released` frame until
  provider exit and unpause have succeeded.

The focused package command is:

```text
PYTHONPATH="$PWD/server" /Users/ersingundem/oikos/server/.venv/bin/pytest -q \
  server/tests/test_core_backup_component_snapshot_provider.py \
  server/tests/test_core_backup_component_worker_server.py \
  server/tests/test_core_backup_component_worker.py \
  server/tests/test_core_backup_components.py \
  server/tests/test_core_backup_component_wiring.py
```

Result: **44 passed**. Python compilation and `git diff --check` also pass.

## Remaining S09.1 gates

The installation journal must still construct the authority from exact durable
receipts, and a packaged Linux Docker Engine adapter must prove pause state,
uncertain-effect reconciliation, restart recovery and volume identities on
amd64 and arm64. Restore/rollback and interruption recovery remain S09.2/S09.3
work. Queue progress stays **26/125** and selected-feature progress stays
**0/63**.
