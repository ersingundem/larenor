# S09.1 database schema binding

Date: 23 September 2026

This narrow Server slice closes a semantic gap in authenticated Core backups.
The manifest schema inventory and `component-index` were already required to
match each other, but they were not bound to the metadata inside the captured
`core-database`. A producer with the backup passphrase could therefore alter
both public schema declarations, recompute the resource digest, and create a
cryptographically valid bundle whose declarations did not describe its SQLite
cut.

## Acceptance boundary

1. Bundle opening reads only the bounded `core-database` image in an isolated,
   query-only in-memory SQLite connection. The private copy normalizes the WAL
   header so validation does not create or depend on a sidecar file. SQLite VM
   work is capped at 100,000 steps.
2. The `metadata` object must be a real table in `sqlite_schema` with exactly
   the expected `key TEXT PRIMARY KEY` and `value TEXT NOT NULL` columns. Views,
   virtual/hidden/extra columns, and budget interruption fail closed.
3. `databaseSchemaVersion` must equal the database's `schema_version`
   metadata, and `componentSchemaVersions` must equal the positive `*_schema`
   metadata captured from the same database image.
4. Missing, malformed, oversized, or unreadable database images and schema
   drift fail through the existing static `backup_decryption_failed`
   classification. No metadata value, path, or backup secret crosses the API
   boundary.

## TDD evidence

The RED regression created a real encrypted bundle, incremented one component
schema in both the manifest and canonical component index, recomputed the
resource length and SHA-256 digest, and left the SQLite payload unchanged. The
old implementation accepted that bundle. A second case binds the manifest's
Core database schema version to the same image.

Independent review then found that an authenticated SQLite image could replace
`metadata` with a recursive view and make validation consume unbounded VM work.
Two RED regressions proved that a small recursive view and a 50,000-row scan
were accepted. Exact `sqlite_schema`/column/primary-key checks and the VM budget
make both fail through the same static classification.

The GREEN focused run covers four database binding/adversarial cases, the exact
encrypted-envelope ceiling, and the broader backup contract, component, and
empty-Core restore suites: **37 passed** with only the two existing
Starlette/httpx deprecation warnings. Focused Ruff and bytecode compilation
passed. The repository policy
suite passed **383 tests** with four documented native-fixture skips; security,
queue, progress, and diff checks also passed.

## Remaining S09.1 gates

S09.1 remains pending. Production component restore and rollback, deployment
configuration portability, interruption recovery across component effects,
native/provider acceptance, independent review, and exact-head CI remain
separate gates. This slice does not change `docs/PROGRESS.md`,
`docs/execution-queue.json`, or the counters **26/125** and **0/63**.
