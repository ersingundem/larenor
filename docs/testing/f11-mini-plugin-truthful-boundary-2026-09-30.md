# F11 signed, resource-bounded mini-plugin runtime

Date: 2026-09-30

## Production contract

The fixed `home-resource-count` catalog entry is a packaged WebAssembly binary,
not Python metadata code and not a user upload. Core verifies all of these before
serving a mini-plugin request:

- the exact artifact SHA-256 and exact canonical manifest SHA-256;
- an Ed25519 signature over the full manifest using a packaged public key (the
  signing private key is not stored in the repository or runtime image);
- Wasmtime `49.0.0` and the closed `larenor.mini-plugin.v1` ABI;
- exactly one import,
  `larenor.current_home_resource_count()->i32`, and exactly the `memory` and
  `render` exports declared by the signed manifest.

Each render starts a new Wasmtime engine and store. Core enables fuel
consumption, supplies exactly 50,000 fuel units, limits the store to one 64 KiB
linear-memory page, one instance, one memory, zero tables, and installs a
one-tick epoch deadline with a host epoch increment scheduled after 100 ms.
Fuel is the deterministic instruction-work boundary. Epoch interruption is a
coarse wall-time backstop; the API does not describe it as a 100 ms CPU
receipt. The linker does not define WASI, filesystem, network, environment,
clock, key, or process imports. Component Model, function references, GC,
exceptions, tail calls, SIMD, relaxed SIMD, threads, multi-memory, and
memory64 are disabled in the engine configuration. The packaged artifact uses
none of those optional proposals.

The sole host function returns an integer already read from the current,
authorized home-resource SQLite transaction. Module code receives no actor,
credential, path, database handle, cross-home identifier, or arbitrary host
callback. Existing admin/session/current-home/revision gates, fixed-catalog
create, stop, idempotency, output-size checks, and maximum instance counts
remain in force.

Catalog and instance schema version 3 use execution class
`signed_packaged_wasm_v1`. Render responses include engine-produced evidence:
artifact and manifest digests, manifest signature verification, exact fuel
limit and consumption, linear-memory limit and observation, epoch settings,
WASI disabled, and the sole allowed import. These are enforced values and
measurements. The removed in-process claims of 50 ms CPU and 1 MiB memory were
not restored. The Flutter parser pins the same artifact and manifest digests
and rejects older or open response envelopes.

Arbitrary plugin upload remains unavailable. This fixed signed catalog still
executes real isolated Wasm and satisfies the packaged mini-plugin boundary
without exposing a general code-loading surface.

## Primary sources

- [Wasmtime Python API](https://bytecodealliance.github.io/wasmtime-py/):
  `Config.consume_fuel`, `Store.set_fuel`, `Store.set_limits`,
  `Store.set_epoch_deadline`, and `Engine.increment_epoch` define the enforced
  runtime controls. The store limiter specifies that `memory.grow` returns
  `-1` at the configured byte threshold.
- [Wasmtime security documentation](https://docs.wasmtime.dev/security.html):
  WebAssembly code can use only explicitly imported host functionality; the
  runtime provides the core sandbox and memory isolation.
- [Official wasmtime-py package](https://pypi.org/project/wasmtime/): `49.0.0`
  is the newest Python binding published on PyPI as of 2026-09-30. It supports
  Python 3.9 through 3.14 and publishes Python 3 wheels for Linux
  x86-64/aarch64 and macOS x86-64/arm64. Larenor pins this exact available
  binding version.
- [Wasmtime 49.0.1 release](https://github.com/bytecodealliance/wasmtime/releases/tag/v49.0.1):
  the upstream Rust engine release fixes fuel accounting for `call_ref` and
  exception throws, dynamic Component Model record lifting, and two WASI host
  defects. There is no `wasmtime-py==49.0.1` package on PyPI as of 2026-09-30.
  Larenor therefore keeps general and untrusted module upload unavailable,
  links no WASI, and disables the affected optional proposal surfaces. The
  fixed signed artifact remains core Wasm and its function-reference rejection
  is exercised against the actual configured engine.

## Evidence

Run from `server/` unless stated otherwise:

```text
uv run pytest tests/test_mini_plugin_wasm_runtime.py -q
13 passed

uv run pytest tests/test_mini_plugin_wasm_runtime.py tests/test_f08_f11_final.py \
  -q -k 'mini_plugin or f11'
17 passed

cd .. && flutter test \
  test/features/server/server_ai_f08_f11_core_loopback_test.dart
4 passed

uv run python tests/support/f11_flutter_acceptance.py
1 passed

flutter analyze lib/features/server/mini_plugins/data/server_mini_plugin_api.dart \
  lib/features/server/mini_plugins/domain/server_mini_plugin_models.dart \
  test/features/server/server_ai_f08_f11_core_loopback_test.dart \
  test/features/server/server_mini_plugin_normal_core_test.dart
No issues found

uv run --isolated --with 'wasmtime==49.0.1' python -c 'import wasmtime'
No solution found: there is no version of wasmtime==49.0.1

uv build --wheel --out-dir <fresh-directory>
wheel contains wasm_runtime.py, the .wasm artifact, manifest, and signature
```

The sandbox tests execute the actual Wasmtime engine. They prove the signed
artifact calls the authorized host capability, an infinite loop traps on fuel,
a large-fuel loop traps on epoch interruption, `memory.grow` is denied above
one page while memory remains 65,536 bytes, a WASI import cannot instantiate,
the engine rejects a module using `call_ref`, and artifact/manifest/signature
tampering fails closed. The normal-Core runner starts the production
FastAPI/Core server on TCP and drives catalog, create, render, evidence parsing,
stop, and stopped-render rejection through the actual Flutter client.
