# S09.1 component backup contract

Date: 23 September 2026

This narrow slice extends the existing encrypted Core bundle contract with
managed component-volume payloads. It introduces no Docker, host-volume,
restore, or device write path. A future privileged adapter must supply the
read-only component snapshots through the bounded quiescence boundary.

## User journeys

1. As a Core administrator, I want every captured component volume bound to
   its pinned service, config schema, and data schema so that a partial or
   incompatible component backup cannot be reported as compatible.
2. As an operator, I want the Core database and component payloads captured
   inside one bounded consistency cut so that the manifest cannot combine
   unrelated points in time.
3. As a backup holder, I want component payloads protected by the existing
   authenticated encrypted envelope and strict digest checks.

## TDD evidence

The RED checkpoint is commit `85fe3428`. The new test module failed during
collection because `ComponentVolumeSnapshot` and the quiescence boundary did
not exist:

```text
ImportError: cannot import name 'ComponentVolumeSnapshot'
1 error during collection
```

The GREEN command was:

```text
cd server
uv run --locked --no-sync python -m pytest \
  tests/test_core_backup_components.py \
  tests/test_core_backup_contract.py \
  tests/test_core_backup_empty_restore.py
```

Result: `28 passed`. The two warnings are upstream Starlette/httpx deprecation
warnings and are not test skips or behavior failures.

`coverage.py` over the three backup suites reports **90%** statement coverage
for `larenor_server.core_backups` (515 statements, 50 missed), above the TDD
coverage gate for this slice.

| Guarantee | Test | Type | Result |
| --- | --- | --- | --- |
| Component config/cache bytes share the Core write-lock cut and a five-second provider deadline | `test_component_volumes_share_the_bounded_cut_and_stay_encrypted` | integration | PASS |
| The encrypted envelope does not expose component payload bytes and opens with exact payload digests | `test_component_volumes_share_the_bounded_cut_and_stay_encrypted` | integration | PASS |
| Pinned service version, config/data schema, and exact managed volume identities fail closed independently | `test_component_version_schema_and_volume_compatibility_fail_closed` | API contract | PASS |
| A provider that exceeds the quiescence deadline releases its boundary and returns no manifest | `test_component_quiescence_deadline_releases_and_returns_no_manifest` | boundary | PASS |
| A partial managed volume set returns no manifest | `test_partial_component_volume_set_fails_closed` | boundary | PASS |
| Component payload restore is rejected before any publication path | `test_component_payload_restore_is_rejected_before_publication` | restore guard | PASS |
| Wrong passphrase, tamper, truncation, strict archive membership, and empty-Core restore regressions remain green | existing Core backup contract and empty-restore suites | regression | PASS |

## Deliberate limits and remaining S09.1 work

The default Core has no privileged component snapshot provider, so it exports
no component volumes until an independently reviewed adapter is configured.
The adapter must implement bounded process quiescence and read-only streaming
from the exact journal-bound managed volumes. Partial service volume sets,
unknown versions, schema drift, invalid payloads, and deadline overruns already
fail closed at this contract.

Component payload restore remains intentionally unsupported: authenticated
bundles with component volumes are rejected before staging because this slice
has no authority to write host volumes. Atomic component restore/rollback,
large-volume streaming limits, native amd64/arm64 acceptance, Client download
and restore UX, independent review, and exact-head CI remain open. S09.1 stays
`pending`; queue and feature counters do not change.
