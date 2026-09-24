# S09.1 Linux capture capability evidence

## Scope

This slice adds the fail-closed host capability contract used before the
packaged privileged component worker can own Btrfs read-only snapshots. It does
not add or change snapshot mutation, release, or restore behavior.

## RED

Before production code existed, the focused test collection failed with
`ModuleNotFoundError` for
`component_linux_capture_preflight`. This proved the new preflight and runtime
composition contract were absent.

## GREEN guarantees

| Guarantee | Evidence |
| --- | --- |
| Only Linux effective UID 0 with `CAP_SYS_ADMIN` can produce a capability receipt | `test_preflight_returns_exact_secret_free_btrfs_capability` and the unsupported-host matrix |
| The private capture-root path, held directory FD, mount identity, namespace, writable Btrfs type, and non-idmapped state must agree exactly | `test_preflight_rejects_unsupported_or_stale_host_without_details` |
| Capability drift is denied without host paths or kernel details | `test_preflight_revalidation_fails_closed_on_identity_drift` |
| `/proc/self/status` `CapEff` evidence is canonical, bounded, unique, and strict | capability parser matrix |
| The packaged runtime carries the verified receipt into its capture composition | `test_runtime_composes_durable_authority_docker_adapter_and_capture` |
| Native amd64/arm64 acceptance verifies the real root-owned Btrfs fixture before snapshot tests | `test_core_backup_linux_cow_capture_native.py` |

Focused unit command:

```text
uv run --project server pytest -q \
  server/tests/test_core_backup_linux_capture_preflight.py \
  server/tests/test_core_backup_component_worker_runtime.py \
  server/tests/test_core_backup_linux_cow_capture.py
```

Result: `33 passed`. The workflow policy test and Python compile check also
passed. Queue validation and the progress-message dry run remained at
`26/125` and `0/63`.

The real native test remains owned by
`.github/workflows/component-capture-native.yml`; it requires the ephemeral
root Btrfs fixture and therefore is not run on a non-Linux developer host.
