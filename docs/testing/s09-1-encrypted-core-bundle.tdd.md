# S09.1 encrypted Core bundle

21 September 2026. This slice builds on the versioned Core capture contract and
turns one accepted capture into a portable encrypted `.larenor-core` download.
It is intentionally stacked on the contract foundation until PR #302 merges.

## Three acceptance criteria

1. **Secrets stay encrypted.** The exact manifest, SQLite image, independent
   vault key, deployment configuration, and component schema index are packed
   behind Scrypt (`N=32768`, `r=8`, `p=1`) and AES-256-GCM with a random
   128-bit salt and 96-bit nonce. The response is `no-store`, attachment-only,
   and `nosniff`; plaintext schema, admin data, and vault key bytes do not occur
   in the downloaded envelope.
2. **Integrity fails closed.** The opener accepts only the fixed format marker,
   exact file set, bounded sizes, strict manifest, and matching per-resource
   length and SHA-256. A wrong passphrase, changed ciphertext, truncated file,
   renamed member, malformed manifest, or digest mismatch returns the same
   static `backup_decryption_failed` result.
3. **Bounded execution.** Export still refuses every active-effect blocker,
   limits the Core database to 128 MiB, allows only one expensive Scrypt/export
   worker at a time, never echoes the write-only passphrase, and releases the
   concurrency gate on every result.

## TDD evidence

The RED run added three failing journeys for the absent export endpoint,
decrypt/open boundary, and active-effect rejection. GREEN plus the bounded
concurrency regression passes **39 Server tests** across the backup contract,
admin migration, and Core context transaction suites. New backup modules and
tests are Ruff-clean.

S09.1 remains pending for managed component-volume payloads, atomic restore
apply/rollback, Android SAF download/restore UX, and exact merged CI.
