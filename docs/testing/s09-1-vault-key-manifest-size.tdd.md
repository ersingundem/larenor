# S09.1 vault-key manifest size contract

Date: 23 September 2026

The backup manifest already required the separate vault-key resource to use the
`vaultKey` kind and `aes256-v1` version, but its declared length still accepted
any value from one byte to 512 MiB. Restore preflight could therefore report a
31- or 33-byte AES-256 key manifest as compatible even though the real restore
would fail while binding that key to the database.

## Acceptance boundary

1. Every parsed backup manifest requires the `vault-key` resource to declare
   exactly 32 bytes, matching the existing AES-256 contract.
2. Both undersized and oversized declarations fail at request/model validation,
   before compatibility is reported or any restore staging can begin.
3. The key bytes, digest, passphrase, and host key path remain absent from API
   errors and logs. Existing kind, resource-set, version, digest, and encrypted
   bundle checks remain unchanged.

## TDD evidence

The RED preflight regression changed only the captured manifest's vault-key
length to 31 and 33 bytes. Both requests previously returned HTTP 200. After
binding the versioned resource to its exact key size, both return the existing
static HTTP 400 `invalid_request` response.

The focused manifest, encrypted contract, component, empty-target restore, and
CLI secret suites pass **38 tests** with only the two existing Starlette/httpx
deprecation warnings. Focused Ruff, bytecode compilation, repository policy,
security, queue, progress, and diff checks are run on the final commit.

## Remaining S09.1 gates

S09.1 remains pending. Production component snapshot/restore authority,
component rollback and interruption recovery, Client import UX, native/provider
acceptance, independent review, and exact-head CI remain separate gates. This
slice does not change `docs/PROGRESS.md`, `docs/execution-queue.json`, or the
counters **26/125** and **0/63**.
