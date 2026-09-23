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
   containers remain paused, then once more after unpause reconciliation.
   Shared containers, incomplete service volume
   sets, nested/aliased paths, catalog drift, path swaps and release-time
   authority drift fail closed.

## RED and GREEN evidence

- `54741ac6` defined archive, rollback and bound requirements before the module
  existed; `17858702` implemented the first provider.
- Independent review found uncertain pause, unbound installation metadata and
  pre-capture path-swap gaps. `737e4d00` reproduced them; `02aa13c8` bound the
  provider to exact installed authority and inode identity.
- Review then found authority could drift while the consumer held the snapshot.
  `eec28d60` reproduced that exit race; `84b03105` added the pre-release
  revalidation. `11958183` and `ffdc51a3` close drift during unpause with a
  final post-reconciliation readback. `7cefe5fe` and `647a8e4c` close late
  same-name archive mutation by rechecking every captured entry fingerprint.
  `58d18f15` adds a malformed-deadline regression; the following implementation
  normalizes it before arithmetic or private value exposure. Finally,
  `238e003f` and `b5fdf91c` replace per-directory assurance with a root-wide
  recursive fingerprint rescan, closing mutation of a completed nested subtree
  while later siblings are archived.
  Independent exact-head review then found that `listdir` materialized an
  unbounded directory before the entry cap. RED `3f5fba8e` proves enumeration
  consumed past the 10,000-entry boundary; GREEN `28ac68d4` uses deadline-aware
  descriptor-relative `scandir` and rejects the first excess entry before any
  deterministic sort in both capture and recursive revalidation.
  The stacked worker server delays its `released` frame until provider exit and
  unpause have succeeded.

The focused package command is:

```text
PYTHONPATH="$PWD/server" /Users/ersingundem/oikos/server/.venv/bin/pytest -q \
  server/tests/test_core_backup_component_snapshot_provider.py \
  server/tests/test_core_backup_component_worker_server.py \
  server/tests/test_core_backup_component_worker.py \
  server/tests/test_core_backup_components.py \
  server/tests/test_core_backup_component_wiring.py
```

Result: **49 passed**. Python compilation and `git diff --check` also pass.

## Remaining S09.1 gates

The installation journal must still construct the authority from exact durable
receipts, and a packaged Linux Docker Engine adapter must prove pause state,
uncertain-effect reconciliation, restart recovery and volume identities on
amd64 and arm64. This portable reader assumes the paused managed container is
the sole writer. A shared or hostile host writer cannot be made atomic by any
finite sequential rescan; closing that stronger boundary requires the Linux
adapter to provide an authority-held read-only/COW filesystem snapshot. Restore/
rollback and interruption recovery remain S09.2/S09.3 work. Queue progress
stays **26/125** and selected-feature progress stays **0/63**.
