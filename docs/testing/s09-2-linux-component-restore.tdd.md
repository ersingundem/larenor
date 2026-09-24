# S09.2 Linux component restore adapter evidence

Status: narrow Job4 implementation evidence; S09.2 remains open.

Progress remains `26/125` queue items and `0/63` feature checklist items.

## Three delivery jobs

1. `f2fcb17e` maps accepted durable installation receipts to secret-free, exact restore authority targets.
2. `1a0d1517` retains volume-root and parent descriptors, validates deterministic archive input, stages on the same filesystem, and rejects path, inode, schema, revision, traversal, link, and malformed archive drift.
3. `73b61d17` connects the exact Docker authority to the root-inode-preserving Linux publisher and durable v3 recovery coordinator. The boundary is disabled unless explicitly constructed with the exact durable authority, Docker adapter, and Linux engine types.

The final recovery audit added three independent substantive fixes on base
`b4272e381e2dda2d027cea0d25c0ebea21715f06`:

4. `ad07ae89` authenticates the exact planned paused-container set and refuses
   to adopt any current pause while the journal is only `acquiring` or
   `acquired`.
5. `95213ea9` preserves rollback archives until `rolled_back` is durably
   persisted, then performs idempotent `rollback_finalized` cleanup while the
   service remains paused.
6. `ae2a3f82` finalizes a successful committed tree before release and recovers
   the cleanup-complete/journal-write-loss window from the live receipt digest.

## RED evidence

The first production-boundary journey failed after directory-root exchange: the volume root inode changed, so durable installation authority correctly rejected post-commit revalidation and refused unpause. The failing focused run was `2 failed` in `test_core_backup_component_linux_restore.py`.

Additional RED cases covered invalid operation path content, a real child `SIGKILL` after the first publication exchange, recovery from quiesced/staging/pre-commit/committed checkpoints, partial two-volume commit, initially-paused restart adoption, and rollback-only artifact cleanup.

## GREEN contract

The Linux engine keeps the authority-owned volume-root inode unchanged. It writes a mode-0600 rollback archive through a retained parent descriptor, fsyncs rollback and staging artifacts, and publishes bounded child entries with Linux `renameat2` exchange or no-replace moves. Any partial publication is restored from the authenticated journal-bound rollback receipt before release. No host path, Docker response, archive entry, credential, or payload is returned in errors or receipt representations.

Recovery first authenticates the v3 journal, exact plan and exact planned
paused-container set, then reopens current Docker/container/volume authority.
An `acquiring` or `acquired` record never adopts a current pause. Only a
`quiesced` or later record may adopt the journal-proven planned set; a missing
or foreign pause remains fail-closed. Release uses the original caller
deadline and remains exactly once.

Rollback restores the old tree but retains stage, trash and rollback archive
evidence until `rolled_back` is durable. It then deletes those artifacts,
persists `rollback_finalized`, and only then releases the service. Successful
commit cleanup follows the same ordering: live stage digest verification and
artifact deletion happen while paused, `committed_finalized` is persisted,
and release is last. A crash after cleanup but before the phase write is
idempotently recognized only when every artifact is absent and the live root
matches the corresponding rollback or stage receipt.

## Verification

- `test_core_backup_component_linux_restore.py`: 15 passed and one Linux-only native `renameat2` test skipped on macOS. The real POSIX `SIGKILL` test passed locally.
- Grouped component Linux restore, Docker adapter, installation authority,
  plan/coordinator, and durable recovery suite: 89 passed and one Linux-only
  native test skipped on macOS (90 collected).
- Native workflow contract: 5/5 passed.
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
