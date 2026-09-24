# S09.2 Linux component restore adapter evidence

Status: narrow Job4 implementation evidence; S09.2 remains open.

Progress remains `26/125` queue items and `0/63` feature checklist items.

## Three delivery jobs

1. `f527b03a` maps accepted durable installation receipts to secret-free, exact restore authority targets.
2. `07bcdafb` retains volume-root and parent descriptors, validates deterministic archive input, stages on the same filesystem, and rejects path, inode, schema, revision, traversal, link, and malformed archive drift.
3. `f0fde359` connects the exact Docker authority to the root-inode-preserving Linux publisher and durable v3 recovery coordinator. The boundary is disabled unless explicitly constructed with the exact durable authority, Docker adapter, and Linux engine types.

## RED evidence

The first production-boundary journey failed after directory-root exchange: the volume root inode changed, so durable installation authority correctly rejected post-commit revalidation and refused unpause. The failing focused run was `2 failed` in `test_core_backup_component_linux_restore.py`.

Additional RED cases covered invalid operation path content, a real child `SIGKILL` after the first publication exchange, recovery from quiesced/staging/pre-commit/committed checkpoints, partial two-volume commit, initially-paused restart adoption, and rollback-only artifact cleanup.

## GREEN contract

The Linux engine keeps the authority-owned volume-root inode unchanged. It writes a mode-0600 rollback archive through a retained parent descriptor, fsyncs rollback and staging artifacts, and publishes bounded child entries with Linux `renameat2` exchange or no-replace moves. Any partial publication is restored from the authenticated journal-bound rollback receipt before release. No host path, Docker response, archive entry, credential, or payload is returned in errors or receipt representations.

Recovery first authenticates the v3 journal and exact plan, then reopens current Docker/container/volume authority. Only this recovery path may adopt an exact currently-paused managed container; ordinary startup still rejects an initially-paused container. Release uses the original caller deadline and remains exactly once.

The durable coordinator persists `released` before deleting rollback artifacts. A crash after release therefore reopens the exact session only for idempotent finalization; it does not replay pause, commit, rollback, or unpause effects.

## Verification

- `test_core_backup_component_linux_restore.py`: 15 passed and one Linux-only native `renameat2` test skipped on macOS. The real POSIX `SIGKILL` test passed locally.
- Grouped component Linux restore, Docker adapter, installation authority,
  plan/coordinator, and durable recovery suite: 83 passed and one Linux-only
  native test skipped on macOS (84 collected).
- Ruff 0.14.10, compile, diff-check, security scan, queue validation, and progress validation are required before commit.

Linux CI runs the non-skipped native `renameat2` journey on each configured production architecture. The portable test seam is used only on non-Linux developer hosts.

## Dedicated native acceptance

`.github/workflows/component-restore-native.yml` is the required, scope-aware
native gate for this contract. Its GitHub-hosted matrix runs the exact grouped
restore suite on `linux/amd64` and `linux/arm64`; the architecture guard rejects
a runner/platform mismatch before pytest starts. The suite includes the real
Linux `renameat2` publication journey, the fork-and-`SIGKILL` restart fixture,
Docker container/volume ownership, durable installation authority, atomic
staging, rollback, and authenticated v3 recovery.

The workflow loads the scope classifier from the reviewed base revision for
pull requests and fails open when its evidence is incomplete. Restore engine,
authority, adapter, recovery, fixture, dependency-lock, or workflow changes run
both matrix legs. Documentation, unrelated client code, and other changes with
no executable native restore input skip the matrix while the always-running
aggregate still produces the required acceptance result.
