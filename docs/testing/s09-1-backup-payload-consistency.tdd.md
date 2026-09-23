# S09.1 backup metadata consistency boundary

Date: 23 September 2026

This narrow Server slice closes an authenticated-bundle contract gap left by
the merged S09.1 foundations. `open_backup_bundle` previously verified AEAD,
the manifest, resource membership, byte lengths, and digests, but it did not
verify that the decrypted `core-configuration` and `component-index` metadata
described that same manifest. A producer with the valid backup passphrase
could therefore create a digest-valid bundle whose configuration exposed an
unexpected private field or whose component schemas differed from the public
manifest.

## Acceptance boundary

1. The decrypted Core configuration has the exact version-one shape and four
   boolean worker flags produced by the contract. Unknown fields and
   non-canonical encodings fail closed.
2. The component index has the exact contract version, schema map, and (for a
   version-two consistency cut) component records carried by the manifest.
   Schema or component drift fails closed even when its digest and encrypted
   envelope are valid.
3. Bundle-open failures remain the static `backup_decryption_failed` response;
   no payload value, private path, digest, or passphrase is reflected. Offline
   restore authenticates and decodes first, then maps the same semantic
   validator to its static `backup_incompatible` classification.

## TDD evidence

The RED command was:

```text
cd server
PYTHONPATH=. /Users/ersingundem/oikos/server/.venv/bin/python -m pytest \
  tests/test_core_backup_contract.py -q
```

It produced **2 failed, 10 passed**. Both new cases created cryptographically
valid bundles with recomputed resource lengths and SHA-256 digests; the old
implementation accepted the extra configuration path and component-schema
drift instead of raising `ApiError`. The GREEN rerun produced **12 passed**.

Independent review found that applying semantic validation inside the shared
decoder made the real offline restore path report `backup_decryption_failed`
instead of `backup_incompatible`. A real encrypted-bundle regression produced
**1 failed, 14 passed** before the decoder and semantic acceptance stages were
separated. It then passed while the ordinary open regression retained its
static decryption classification.

The broader locked backup regression command covered
`test_core_backup_contract.py`, `test_core_backup_components.py`, and
`test_core_backup_empty_restore.py`: **32 passed** with only two existing
upstream Starlette/httpx deprecation warnings. Coverage over
`larenor_server.core_backups` was **91%** (540 statements, 50 missed), above
the TDD gate. Focused Ruff static analysis and Python bytecode compilation
passed for the package and focused tests.

Repository policy verification ran **383 tests successfully** with four
documented native-fixture skips, and `tool/check_security_policy.py` passed.
`git diff --check` and the per-commit progress gate are run again on the final
commit.

## Remaining S09.1 gates

S09.1 remains pending. A reviewed privileged component snapshot adapter,
large-volume/native acceptance, component restore and rollback, interruption
recovery, Client restore UX, independent review, and exact-head CI remain
separate gates. This slice does not change `docs/execution-queue.json`, the
queue status, or the counters **25/125** and **0/63**.
