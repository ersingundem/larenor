# S09.1 restore database resource cap

Date: 23 September 2026

The authenticated bundle contract limits `core-database` to 128 MiB, but the
empty-target staging and restart-recovery paths reread that resource with the
424 MiB whole-bundle ceiling. A locally altered or interrupted restore state
could therefore make recovery hash and publish a database which no valid
bundle is allowed to carry.

## Acceptance boundary

This narrow Server slice keeps the database resource limit through three
restore states:

1. The post-validation staged database read uses `MAX_DATABASE_BYTES` before a
   recovery journal can be created.
2. Restart preflight verifies the staged database with the same resource limit
   before publishing the key, family board, or database.
3. If a prior attempt already published the database, restart revalidates that
   target with the resource limit before creating the initialized marker or
   removing the authoritative journal.

The exact 128 MiB boundary remains accepted. An oversized staged or published
database fails with the existing static `restore_recovery_invalid` recovery
classification; the initial staging path retains its existing private-file
failure. No digest, path, database contents, or backup secret is added to an
error or log surface.

## TDD evidence

Four RED regressions failed because the restore module had no database-specific
limit: initial staging, restart preflight before publication, restart
revalidation after database publication, and the exact boundary. The GREEN
implementation imports the single Server contract constant and replaces only
the two whole-bundle ceiling uses for the Core database.

The focused database-cap, recovery-preflight, empty-restore, and bundle-limit
suites pass **21 tests** with only the two existing Starlette/httpx deprecation
warnings. Focused Ruff and bytecode compilation pass. The repository policy
suite passes **383 tests** with four documented native-fixture skips; security,
queue, progress, and diff checks also pass.

## Remaining S09.1 gates

S09.1 remains pending. Production component restore and rollback, interruption
recovery across component effects, native/provider acceptance, independent
review, and exact-head CI remain separate gates. This slice does not change
`docs/PROGRESS.md`, `docs/execution-queue.json`, or the counters **26/125** and
**0/63**.
