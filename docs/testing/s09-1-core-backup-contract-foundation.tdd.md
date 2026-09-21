# S09.1 Core backup contract foundation

21 September 2026. This slice establishes the first executable Core-side
backup contract. It does not close S09.1: encrypted bundle publication,
managed component-volume bytes, restore apply/rollback, and Client download
remain follow-up work.

## Three acceptance criteria

1. **One consistent cut.** An admin-only plan derives the SQLite image, the
   separate 256-bit vault key, a path-free deployment configuration, and the
   component schema index while holding one database write boundary. Every
   resource carries an exact byte length, SHA-256 digest, version, and shared
   snapshot identity. The captured database passes `integrity_check` and its
   stored key check matches the captured vault key.
2. **No cut through active effects.** Accepted bounded transfers and queued or
   running install/configuration workers prevent a ready plan. The API returns
   only bounded reason codes, never host paths, credentials, resource payloads,
   or exception text.
3. **Fail-closed restore compatibility.** Contract, Core, database schema, and
   every component schema version are checked before restore work can begin.
   Missing, duplicate, renamed, oversized, or malformed resources are rejected
   by strict request models. The endpoints require a current administrator and
   are present in protected OpenAPI.

## TDD evidence

The RED run had four failures: both endpoints were absent, no coherent capture
existed, and no restore compatibility check was available. The GREEN run
passes the four new contract/API tests together with the admin migration and
Core context transaction suites: **35 passed**, with no skips. Ruff is clean
for the new module and tests. Queue validation, security policy, and diff checks
remain required before publication.

S09.1 remains `pending`; this foundation does not change the evidence-backed
queue or selected-feature counters.
