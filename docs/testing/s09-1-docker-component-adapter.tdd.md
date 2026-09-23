# S09.1 Docker component snapshot adapter

Date: 23 September 2026

This stacked Linux adapter converts the durable installation authority into
exact live `ComponentVolumeSource` records and owns bounded container
pause/unpause effects. It uses only an authenticated synthetic Unix Docker
Engine in tests; it never writes component data or performs restore. S09.1 is
still open, so queue progress remains **26/125** and selected-feature progress
remains **0/63**.

## Delivered jobs

1. **Closed Engine routes.** Full lowercase 64-hex container IDs admit only
   `GET /v1.47/containers/{id}/json`,
   `POST /v1.47/containers/{id}/pause`, and
   `POST /v1.47/containers/{id}/unpause`. Effects require a literal-`True`
   dispatch gate after same-stream API 1.47 validation and accept only exact
   bodyless 204 framing. Query, body, custom-header, traversal, redirect,
   transfer-encoding and response-body variants fail closed. RED `bc7585ee`;
   GREEN `8ba2bad4`.
2. **Exact durable volume sources.** A full container inspect must match the
   installed binding, current running state, every generated appdata
   name/target/source mount, and each exact volume label receipt. The selected
   host path must remain an absolute non-symlink directory, and the complete
   set must have unique paths and device/inode identities before durable
   authority binds it. Raw daemon values and paths never enter diagnostics.
   RED `9022524a`; GREEN `6b999bd7`.
3. **One-shot reconciled quiescence.** Pause and unpause each send at most one
   POST. A normal 204 and a timeout after the daemon applied the effect both
   require a fresh full container inspect, fresh exact volume receipt checks,
   exact path device/inode checks, and authority post-gate before success.
   Authority drift before dispatch prevents POST; drift after dispatch cannot
   publish success. Process-local attempted/owned state permits cleanup of an
   uncertain effect without replay, while a new process rejects an initially
   paused container and never adopts or unpauses it. RED `51fae3c2`; GREEN
   `9d43e5c4`.

## Focused evidence

```text
PYTHONPATH=server /Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q \
  server/tests/test_engine_http.py \
  server/tests/test_volume_resources.py \
  server/tests/test_volume_transport.py \
  server/tests/test_volume_effects.py \
  server/tests/test_core_backup_component_installation_authority.py \
  server/tests/test_core_backup_component_snapshot_provider.py \
  server/tests/test_core_backup_component_docker_adapter.py
```

Result: **411 passed, 2 existing platform skips** from **413 collected**. The
new adapter file contributes 12 synthetic Unix Engine tests, including normal
effects, timeout-after-effect reconciliation, no POST replay, pre/post authority
drift, exact label/mount/path identity and restart-paused rejection.

## Remaining boundary

This portable adapter proves quiescence only under the documented installed
authority contract that the paused managed container is the sole writer. It
does not claim atomicity against a hostile or shared host writer. That stronger
boundary still requires an authority-held Linux read-only/COW snapshot adapter
and native amd64/arm64 acceptance. Crash recovery deliberately fails closed on
an initially paused container rather than adopting an effect whose ownership
cannot be proved. No queue or feature completion is claimed.
