# S09.1 component snapshot worker server

Date: 23 September 2026

This slice completes the server half of the private component-snapshot IPC contract. It does not yet pause containers, read host volumes, restore component data, or close S09.1.

## Three delivered jobs

1. **Private listener ownership.** The host worker binds only an absolute, bounded Unix path inside an existing owner-matched directory that is not group/world writable. The socket is mode `0600`, accepts only the configured peer UID, and cleanup unlinks only the exact inode it created.
2. **Exact quiescence lifecycle.** A strict protocol/version/request/timeout frame opens one provider-owned quiescence context. Bounded, catalog-compatible snapshots are sorted and streamed with exact SHA-256 descriptors. The context stays held until the same request sends the exact release frame; foreign releases and disconnects release the provider without completing the operation.
3. **Recoverable single-flight service.** The listener handles clients sequentially and remains available after a foreign peer, malformed exchange, or private provider exception. No exception text, path, payload, or host detail crosses the socket.

## RED and GREEN evidence

RED commit `642d57bf` added the host-worker contract and failed collection because `component_worker_server` did not exist.

The GREEN focused package runs:

```text
PYTHONPATH="$PWD/server" /Users/ersingundem/oikos/server/.venv/bin/pytest -q \
  server/tests/test_core_backup_component_worker_server.py \
  server/tests/test_core_backup_component_worker.py \
  server/tests/test_core_backup_components.py \
  server/tests/test_core_backup_component_wiring.py
```

Result: **16 passed**. The package covers client/server framing, digest and size bounds, peer identity, normal and foreign release, provider failure recovery, socket replacement cleanup, Core wiring, encrypted component capture and compatibility rejection.

## Remaining S09.1 gates

The packaged privileged provider still needs to pause the exact installed component set and create bounded read-only snapshots from the journal-bound managed volumes. Component restore/rollback, interruption recovery, large-volume amd64/arm64 acceptance, independent review and exact-head CI remain open. Queue progress stays **26/125** and selected-feature progress stays **0/63**.
