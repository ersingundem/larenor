# S09.1 component schema marker integrity

Date: 23 September 2026

Core backup manifests bind each persisted component schema marker to the
captured database. The marker reader previously converted values with `int()`
and silently skipped non-positive or malformed rows. Canonically different
database state could therefore be reported as the same manifest version, and
some oversized or unsafe markers reached response-model validation instead of
the static service-unavailable boundary.

## Three-job acceptance boundary

1. Schema values must be canonical positive decimal text. A stored `01` can no
   longer be normalized and advertised as version `1`.
2. Schema versions must fit the manifest's `1..2^31-1` contract. Oversized
   values fail before plan construction or encrypted export.
3. Schema marker names must be bounded ASCII alphanumeric/underscore keys.
   Unsafe keys cannot enter a manifest, response, log or encrypted metadata
   index.

All three violations map to the static `server_unavailable` response for
plan, export and restore-validation endpoints. The corrupted marker name and
value are not reflected. Authenticated bundle payload validation uses the same
strict reader and retains its existing decryption/incompatibility boundary.

## RED to GREEN evidence

The RED run failed all three cases because every corrupted marker still
produced a successful backup endpoint response. The GREEN run passes all **3**
parameterized cases; each case exercises the three public backup contract
endpoints:

```text
uv run --project server pytest \
  server/tests/test_core_backup_schema_marker_integrity.py -q
```

## Remaining S09.1 gates

Production component-volume capture and restore, full deployment
configuration portability, Client import UX, independent review and exact-head
CI remain open. S09.1 stays `pending`; evidence-backed counters remain
**26/125** and **0/63**.
