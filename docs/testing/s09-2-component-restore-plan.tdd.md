# S09.2 exact component restore plan

Date: 24 September 2026

This first component-restore slice creates a read-only plan. It accepts the
strict `BackupCapture` produced after encrypted bundle authentication and
semantic payload validation, then binds every component payload to a current
installation authority snapshot. It performs no Engine call, path selection,
volume write, pause, unpause, stage, publication, or recovery-journal update.

The plan carries the authenticated snapshot ID; pinned service version and
config/data schema; exact sorted volume resource IDs; payload digest and byte
length; installation revision; and each opaque volume binding revision. Host
paths, payload bytes, credentials, private authority failures, and binding IDs
are hidden from `repr` and error text.

## TDD evidence

The RED command was:

```text
cd server
PYTHONPATH=. /Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q \
  tests/test_core_backup_component_restore.py
```

Collection failed before production code existed:

```text
ModuleNotFoundError: No module named \
  'larenor_server.core_backups.component_restore'
```

The GREEN focused batch was:

```text
cd server
PYTHONPATH=. /Users/ersingundem/oikos/server/.venv/bin/python -m pytest -q \
  tests/test_core_backup_component_restore.py \
  tests/test_core_backup_components.py \
  tests/test_core_backup_component_installation_authority.py
```

Result: **27 passed**. The two warnings are upstream Starlette/httpx
deprecation warnings; there are no skips.

Ruff `0.14.10` over the new module and test, Python bytecode compilation,
`tool/check_security_policy.py`, the 125-task/63-feature queue validator and
`git diff --check` all pass on the final tree.

| Guarantee | Focused evidence |
| --- | --- |
| Authenticated snapshot, component versions/schemas, sorted volume IDs, digests, sizes, installation revision and binding revisions form one immutable plan | `test_plan_binds_authenticated_snapshot_and_exact_current_target` |
| Missing or unknown services, duplicate services/volumes, incomplete volume sets and shared volume bindings publish no plan | `test_plan_rejects_unknown_missing_duplicate_or_shared_authority` |
| Service, config-schema or data-schema drift fails closed | `test_plan_rejects_version_or_schema_drift` |
| A second read-only authority snapshot must exactly equal the first; private exceptions never enter output | `test_plan_rejects_authority_drift_and_hides_private_failure` |
| Malformed objects and per-volume oversize metadata fail before the authority is read | `test_plan_rejects_malformed_or_oversize_capture_before_target_publish` |
| Existing encrypted component capture and durable installation-authority behavior remains green | existing S09.1 focused suites |

## Remaining S09.2 work

This slice deliberately stops before host effects. The later restore adapter
must convert durable installed receipts to this opaque authority view, stage
all component payloads without committing any one target, retain a bounded
lease/quiescence boundary through publication, and add a durable cross-resource
recovery journal with restart reconciliation and rollback. Wrong-password,
tamper, interruption and empty-Core recovery behavior remains owned by the
existing encrypted restore contract. S09.2 stays pending; queue and feature
counters remain **26/125** and **0/63**.
