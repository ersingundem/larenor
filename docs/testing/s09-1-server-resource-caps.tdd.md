# S09.1 Server backup resource caps

Date: 23 September 2026

The backup capture and Client parser enforce typed resource limits, but the
Server restore-validation model only bound the separate vault key to 32 bytes.
An authenticated manifest could therefore claim an oversized Core database,
family-board database, or managed-component set and still receive a successful
Server preflight response.

## Acceptance boundary

This narrow Server slice closes three manifest checks before any bundle bytes
are staged:

1. `core-database` is at most 128 MiB and `family-board` is at most 32 MiB.
2. Every declared managed-component volume is at most 64 MiB.
3. Declared managed-component volume bytes total at most 256 MiB. The
   `component-index` metadata resource is not counted as a managed volume.

Each exact boundary remains accepted. One byte over a resource or aggregate
boundary fails with the existing static `invalid_request` response. The limits
live beside the manifest model and the capture service imports the same values,
so capture, authenticated bundle opening, and restore preflight cannot drift.
No digest, path, payload, or backup secret is added to an error or log surface.

## TDD evidence

Four RED regressions proved that the old Server preflight returned HTTP 200 for
a Core database one byte over 128 MiB, a family board one byte over 32 MiB, a
component volume one byte over 64 MiB, and individually valid component volumes
totaling 256 MiB plus one byte. The same tests prove every exact boundary stays
accepted after the GREEN change.

The focused Server manifest-cap, backup-contract, component, final-envelope,
vault-key, and restore-configuration suites pass **28 tests** with only the two
existing Starlette/httpx deprecation warnings. Focused Ruff and bytecode
compilation pass. The repository policy suite passes **383 tests** with four
documented native-fixture skips; security, queue, progress, and diff checks also
pass.

## Remaining S09.1 gates

S09.1 remains pending. Production component restore and rollback, interruption
recovery across component effects, native/provider acceptance, independent
review, and exact-head CI remain separate gates. This slice does not change
`docs/PROGRESS.md`, `docs/execution-queue.json`, or the counters **26/125** and
**0/63**.
