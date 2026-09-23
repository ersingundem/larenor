# S09.1 isolated component capture boundary

Date: 23 September 2026

This slice replaces the production composition point for component backups
with an authority-bound read-only/COW capture lease. It does not implement
restore, clean-install recovery, or native amd64/arm64 acceptance, and it does
not close S09.1. Queue progress remains **26/125** and selected-feature
progress remains **0/63**.

## Three delivered jobs

1. **Exact isolated lease.** A native capture engine must return one complete,
   separately rooted descriptor set for the durable installation sources. Each
   descriptor is a live `O_RDONLY`, `O_CLOEXEC` directory with a distinct
   device/inode identity. Service, container, volume, installed revision,
   service version and both schema versions match exactly. Every volume names
   the same bounded capture generation and exactly one journaled container
   writer. Mixed generations, shared writers and writable/malformed handles
   fail before a payload is visible. RED `6fc18470`; GREEN `56d59d09`. RED
   `f52f0b7c`; GREEN `0b2d2d77` adds the cross-volume generation invariant.
2. **Bounded lifecycle and drift.** Capture and revalidation run under one
   deadline. The lease is revalidated before and after descriptor consumption,
   and every acquired set is released exactly once on success, malformed
   metadata, authority drift, archive failure or consumer interruption. The
   managed provider archives only those descriptors while the exact Docker
   container remains paused, then releases the capture before publishing
   immutable ZIP payloads. RED `3f7fb315`; GREEN `f9acc9d1`.
3. **Real adapter composition.** `UnixDockerComponentSnapshotAdapter.provider`
   derives the source set from the durable container and volume journals and
   combines its reconciled one-shot pause ownership with the isolated capture
   boundary. Production composition fails closed when no native capture engine
   is supplied; the portable live-path fallback is not selected through this
   adapter entry point. RED `d0a9489d`; GREEN `46291dc2`.

## Focused evidence

```text
PYTHONPATH="$PWD/server:$PWD/server/tests" \
  /Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q \
  server/tests/test_core_backup_component_isolated_capture.py \
  server/tests/test_core_backup_component_docker_adapter.py \
  server/tests/test_core_backup_component_snapshot_provider.py \
  server/tests/test_core_backup_component_installation_authority.py
```

The exact branch also runs the component worker/server/wiring group, Python
compilation, queue validation, security policy and `git diff --check` before PR
creation. Result: **88 passed** across the eight-file grouped package.

## Remaining S09.1 gates

The privileged Linux process must supply the native read-only/COW engine and
prove its filesystem operation plus restart journal on amd64 and arm64. This
slice deliberately models that engine as a narrow trusted boundary instead of
claiming a sequential directory copy is atomic against a host writer. Full
backup-contract closure still needs the combined database, key,
configuration and component consistency evidence. Restore remains S09.2;
clean-install, upgrade and recovery CI remain S09.3.
