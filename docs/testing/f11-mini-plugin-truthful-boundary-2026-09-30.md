# F11 truthful fixed mini-plugin boundary

Date: 2026-09-30

## Runtime contract

The shipped `home-resource-count` operation is fixed server code. It does not
load, interpret, or execute user-supplied code. Its only input is the already
authorized current-home registry transaction, and its only provider capability
is `home.resource_count.read`.

The version 2 catalog and instance projections expose only limits the current
runtime actually enforces:

- no network operation exists in the fixed render path;
- no host or scratch filesystem operation exists in the fixed render path;
- the serialized render result is rejected above 1 KiB;
- Core admits at most 64 instances and 8 running instances;
- the existing admin, current-home, session, rate, and revision checks remain
  part of every operation.

The former catalog fields claiming 50 ms of CPU and 1 MiB of memory per
invocation were removed. The in-process SQLite metadata operation had no
per-invocation CPU or memory enforcement, so those values were not receipts.
The Client now accepts only `mini-plugin-catalog-v2` and
`builtin_metadata_v2`; a legacy response carrying the unsupported claims fails
closed.

This slice does not satisfy an arbitrary-plugin runtime requirement. A future
arbitrary-plugin design needs a separately isolated worker with measured CPU
and memory enforcement, a fixed signed package format, and an authority-bound
IPC receipt. The fixed builtin remains useful and truthful without claiming
that larger execution surface.

## Evidence

Run from the repository root unless stated otherwise:

```text
cd server && uv run pytest tests/test_f08_f11_final.py -q -k f11
4 passed

flutter test test/features/server/server_ai_f08_f11_core_loopback_test.dart
4 passed

flutter analyze lib/features/server/mini_plugins \
  test/features/server/server_ai_f08_f11_core_loopback_test.dart
No issues found
```

The server acceptance asserts the exact v2 catalog, absence of CPU and memory
claims, the 1 KiB output boundary, current-home/admin confinement, idempotent
creation, stop behavior, and denial outside the authorized home. The Flutter
acceptance crosses a real loopback HTTP server and exercises catalog, create,
render, and stop with strict parsing.
