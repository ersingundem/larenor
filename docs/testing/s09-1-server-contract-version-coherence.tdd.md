# S09.1 Server contract-version coherence TDD evidence

## Scope

The Client already treats backup contract versions as exact shapes, while the
Server accepted mixed manifests. This slice closes three independent Server
contract gaps:

1. Contract v1 rejects the component-era `components` and
   `consistencyBoundary` fields, including empty values.
2. Contract v2 requires both fields and a non-null bounded consistency
   boundary, including when the component list is empty.
3. Authenticated mixed-v1 bundles fail with the static
   `backup_decryption_failed` classification, while a real four-resource v1
   bundle with component-index v1 remains readable and restorable.

The v1 archive writer now omits the component-era fields and emits canonical
manifest JSON. This changes no current v2 export bytes, resource caps, key
handling, passphrase behavior, or restore publication order.

## RED

Command:

```text
cd server
PYTHONPATH=. /Users/ersingundem/oikos/server/.venv/bin/python -m pytest \
  tests/test_core_backup_server_contract_version.py -q
```

All three tests compiled and failed for the intended behavior:

- v1 preflight returned 200 for component-era fields;
- v2 preflight returned 200 after both component fields were omitted;
- an encrypted mixed-v1 bundle opened successfully.

## GREEN

The same focused suite passed 3/3 after adding the exact pre-validation shape.
The broader backup batch covered contract, managed components, empty restore,
and configuration compatibility alongside the new regressions.

Focused Ruff checks cover the changed Server modules and tests. Repository
security, execution queue, commit progress, and diff gates run on the final
exact head before push.

## Progress boundary

S09.1 remains pending because production component restore/rollback, deployment
acceptance, independent review, and exact-head CI remain open. Counters stay
`26/125` implementation and `0/63` validation.
