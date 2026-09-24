# S09.1 Linux Btrfs capture lifecycle evidence

## Scope

This second slice binds the existing Btrfs read-only snapshot lifecycle to the
exact Linux capability receipt. It covers capture, live revalidation, release,
partial rollback, and restart cleanup. Restore remains outside this slice.

## RED

The focused lifecycle tests initially failed because `LinuxCowCaptureEngine`
did not accept a capability preflight or receipt. A separate RED proved that a
malformed capability could not be allowed through runtime composition.

## GREEN guarantees

| Guarantee | Evidence |
| --- | --- |
| Capture and revalidation retain the exact root device/inode, mount namespace, Btrfs type, privilege receipt, and every source path/FD identity | `test_capability_is_retained_and_release_is_exactly_once` and `test_source_is_bound_to_same_btrfs_device_namespace_and_fd` |
| Snapshot identifiers are unique, lowercase 32-byte hex identities before journal or backend dispatch | `test_generation_and_capture_ids_are_exact_and_unique` |
| Returned snapshot descriptors are directory-only, read-only, and close-on-exec | `test_capability_is_retained_and_release_is_exactly_once` |
| Source drift after a partial snapshot rolls the generation and journal back | `test_source_mount_drift_rolls_back_partial_capture` |
| Capability drift prevents unsafe path cleanup, closes descriptors, preserves the durable journal, and permits one restart cleanup after evidence returns | `test_capability_drift_retains_journal_until_safe_restart_cleanup` |
| Release deletes each snapshot once; a repeated release is a no-op failure | `test_capability_is_retained_and_release_is_exactly_once` |
| The native runner receives fixed argument arrays and maps diagnostics to one static error | `test_btrfs_backend_uses_only_fixed_read_only_operations` and `test_btrfs_runner_failure_is_static_and_source_free` |

Focused command:

```text
uv run --project server pytest -q \
  server/tests/test_core_backup_linux_capture_preflight.py \
  server/tests/test_core_backup_linux_cow_capture.py \
  server/tests/test_core_backup_component_worker_runtime.py
```

The amd64/arm64 native workflow owns real privileged Btrfs execution. Local
non-Linux runs intentionally skip its two fixture-dependent tests.

Focused result: `41 passed`. Queue and feature acceptance remain `26/125` and
`0/63`; this lifecycle slice does not close S09.1.

The grouped component capture package passed `187` tests with `2` explicit
native-fixture skips on this non-Linux host. The repository native workflow
continues to own real privileged Btrfs execution on amd64 and arm64.
