# S09.1 durable installation authority

Date: 23 September 2026

This stacked slice turns the private installation journals into the exact
read-only authority required by the managed component snapshot provider. It
does not connect to Docker, resolve volume mountpoints, pause containers, or
close S09.1. Queue progress remains **26/125** and selected-feature progress
remains **0/63**.

## Three delivered jobs

1. **Typed journal views.** `ManagedWorkerJournal.installed()` publishes only a
   succeeded create/start pair with the same installation, binding and
   container identity. `VolumeCreateJournal.intents()` publishes strict typed
   intents. Both require their existing private journal lock; neither exposes
   raw SQLite rows or performs an effect. RED `ea5a86ea`; GREEN `9a34da7d`.
2. **Exact appdata receipt snapshot.** The authority joins those views by the
   durable installation and generated volume identities, rebinds them to the
   packaged catalog, requires every service appdata mount exactly once, and
   excludes the shared media-library volume. Missing, prepared, stale-catalog,
   wrong-target and nonterminal receipts fail with one static error. RED
   `708c9ad6`; GREEN `8f26a54e`.
3. **Fail-closed revalidation.** The provider source set must match the captured
   service/container/version/schema/volume/revision tuple exactly. Duplicate,
   missing or shared path identities, expired deadlines, catalog drift, journal
   corruption, duplicate service identities and shared container identities do
   not replace the captured authority. RED `590cccba`; GREEN `e2606bc0`.

Independent audit then found that a structurally valid installed container from
an older or foreign plan could be joined to current volume receipts. RED
`cedab984` preserves five plan, catalog, manifest, image and component-config
drifts. GREEN `8621834b` re-derives the complete stored binding from the current
stack component, packaged catalog, worker policy, container journal identity,
pinned image and terminal volume receipts before publishing authority.

## Focused evidence

```text
PYTHONPATH="$PWD/server" /Users/ersingundem/oikos/server/.venv/bin/pytest -q \
  server/tests/test_core_backup_component_installation_authority.py \
  server/tests/test_core_backup_component_snapshot_provider.py \
  server/tests/test_managed_container_binding.py \
  server/tests/test_volume_create_journal.py \
  server/tests/test_plugin_worker.py \
  server/tests/test_installation_runtime.py
```

Result: **232 passed**. The queue and selected-feature counts remain unchanged
because the Linux Docker adapter, durable effect recovery and native acceptance
gates are still open.

The next Linux adapter must still inspect the exact Docker Engine container and
volume receipts, resolve and retain the volume path identities, reconcile
uncertain pause/unpause effects, and provide restart recovery on amd64 and
arm64. A generic Docker Engine named volume is not a COW snapshot API; shared or
hostile host writers remain outside this portable sole-writer contract.
