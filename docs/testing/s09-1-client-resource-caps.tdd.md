# S09.1 Client backup resource caps

Date: 23 September 2026

The Client parsed the generic 512 MiB resource ceiling but did not enforce the
narrower limits already declared by the Core backup contract. A stale or
malicious Core response could therefore present a non-AES-256 key, an oversized
Core/family/component resource, or component volumes above the aggregate limit
as a valid manifest before restore preflight.

## Acceptance boundary

This slice closes three independent Client checks:

1. The `aes256-v1` vault-key resource is exactly 32 bytes.
2. The Core database is at most 128 MiB, the family-board database is at most
   32 MiB, and each declared managed-component volume is at most 64 MiB.
3. Declared managed-component volume bytes total at most 256 MiB. The
   `component-index` metadata resource is not counted as a managed volume.

Every boundary value remains accepted. One byte beyond any boundary fails with
the existing static `invalid_response` code. No backup bytes, digest, path, or
secret is added to logs, errors, or model string output.

## TDD evidence

All three RED regressions failed because the old parser returned a
`CoreBackupManifest`: 31/33-byte keys, resources one byte above each individual
cap, and five individually valid volumes totaling 256 MiB plus one byte. The
GREEN parser rejects each case while accepting exact boundaries.

The full Client backup model/controller, streaming file-access, and EN/TR widget
regression set passes **32 tests**. Focused Flutter analysis reports no issues;
generated sources are untracked build products. Repository policy, security,
queue, progress, format, and diff checks are run on the final commit.

## Remaining S09.1 gates

S09.1 remains pending. Production component snapshot/restore authority,
component rollback and interruption recovery, imported-bundle UX,
native/provider acceptance, independent review, and exact-head CI remain
separate gates. This slice does not change `docs/PROGRESS.md`,
`docs/execution-queue.json`, or the counters **26/125** and **0/63**.
