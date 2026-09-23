# S09.1 privileged component boundary wiring

Date: 23 September 2026

This slice starts from `origin/main` and changes neither the active K07 runtime
files nor the concurrent Client component-blocker files.

## Acceptance boundary

1. The packaged `create_configured_app` entry point can receive one internal,
   privileged component-backup boundary and installs it in the Core backup
   contract before the application is returned or can serve requests.
2. The real authenticated backup route captures the boundary's complete
   catalog-bound component set and releases the quiescence context.
3. The parameter remains internal composition state: there is no request,
   environment, plugin manifest, or Client field that can select it. Omitting
   it retains the existing no-component default.

This is the production composition port for a future host-owned snapshot
adapter. It does not read a Docker socket, stop a component, or grant volume
write authority.

## TDD evidence

The first RED run failed because `create_app` had no
`component_backup_boundary` argument. After wiring that layer, the test was
raised to the packaged runtime entry point and failed again because
`create_configured_app` did not carry the port. The final focused command is:

```sh
uv run --locked --no-sync python -m pytest \
  tests/test_core_backup_component_wiring.py \
  tests/test_core_backup_components.py \
  tests/test_core_backup_contract.py \
  tests/test_runtime.py -q
```

Result: **27 passed**. The new route-level regression proves that both expected
Jellyfin volumes cross the real composition chain and that the boundary is
released exactly once.

## Remaining S09.1 gates

S09.1 remains pending. A reviewed host-owned snapshot adapter, actual
quiescence lifecycle, component restore/rollback, large-volume native
acceptance, independent review, and exact-head CI remain open. This slice does
not change `docs/execution-queue.json`, task status, or the counters **26/125**
and **0/63**.
