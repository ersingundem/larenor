# S09.1 host-owned component snapshot worker client

Date: 23 September 2026

This slice starts at the current `origin/main` and does not touch any file
changed by the open pull requests at that base.

## Three delivered jobs

1. `Settings` exposes an optional component-backup worker socket and exact UID.
   The port is disabled by default; relative/control paths, reused worker paths,
   invalid UIDs, and a nonzero UID without a socket fail with one static startup
   code that does not echo environment input.
2. `ComponentSnapshotWorkerClient` authenticates the private `0600`/`0660` Unix
   socket inode and Linux peer UID, sends the remaining worker budget, enforces
   one five-second total deadline, validates
   an exact 64 KiB JSON header, and reads at most 128 payloads bounded to 64 MiB
   each and 256 MiB total. Length and SHA-256 must match before any snapshot is
   yielded.
3. The packaged runtime owns the configured client. Quiesce and release share
   one random request ID and authenticated connection; malformed frames,
   unexpected EOF, timeout, digest mismatch, stale socket identity, or missing
   release acknowledgement fail closed. The earlier internal boundary injection
   remains available for focused tests and takes precedence.

The protocol carries only catalog identity/version fields and snapshot bytes.
It never carries a Docker endpoint, host path, credential, token, or write
operation. The API-side socket client does not start or discover a worker.

## RED to GREEN evidence

The focused test first failed during collection with:

```text
ModuleNotFoundError: No module named
'larenor_server.core_backups.component_worker'
```

After the client, settings, and packaged runtime wiring were added, the focused
batch is:

```sh
cd server
uv run --locked --no-sync python -m pytest \
  tests/test_core_backup_component_worker.py \
  tests/test_core_backup_component_wiring.py \
  tests/test_core_backup_components.py \
  tests/test_core_backup_contract.py \
  tests/test_runtime.py -q
```

Result: **31 passed**. The tests cover default-off and static configuration
failure, a real AF_UNIX framed payload/release round trip, untrusted-peer and
digest rejection, packaged runtime ownership, and the existing route/component
contract.

## Remaining S09.1 gates

S09.1 remains pending. A reviewed privileged host worker with component-specific
stop/snapshot/resume policy, component restore and rollback, large-volume native
amd64/arm64 acceptance, independent review, and exact-head CI remain open. This
slice does not change `docs/execution-queue.json`, task status, or the
evidence-backed counters **26/125** and **0/63**.
