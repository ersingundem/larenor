import shutil

import pytest
import wasmtime

from larenor_server.mini_plugins import wasm_runtime as runtime_module
from larenor_server.mini_plugins.wasm_runtime import (
    ARTIFACT_NAME,
    MANIFEST_NAME,
    SIGNATURE_NAME,
    MiniPluginRuntimeError,
    PackagedMiniPluginRuntime,
)


def _artifact_root():
    return (
        runtime_module.importlib.resources.files("larenor_server.mini_plugins")
        .joinpath("artifacts")
    )


def _wasm(wat):
    return bytes(wasmtime.wat2wasm(wat))


def test_signed_pinned_artifact_executes_only_current_home_capability():
    runtime = PackagedMiniPluginRuntime()
    execution = runtime.execute(23)

    assert execution.resource_count == 23
    evidence = execution.evidence.public()
    assert evidence == {
        "artifactSha256": runtime_module.ARTIFACT_SHA256,
        "manifestSha256": runtime_module.MANIFEST_SHA256,
        "manifestSignatureVerified": True,
        "engine": "wasmtime-49.0.0",
        "fuelLimit": 50_000,
        "fuelConsumed": 2,
        "linearMemoryLimitBytes": 65_536,
        "linearMemoryBytesObserved": 65_536,
        "epochDeadlineTicks": 1,
        "epochIncrementAfterMilliseconds": 100,
        "wasiEnabled": False,
        "allowedImports": [
            "larenor.current_home_resource_count()->i32",
        ],
    }


@pytest.mark.parametrize(
    "name",
    [ARTIFACT_NAME, MANIFEST_NAME, SIGNATURE_NAME],
)
def test_artifact_manifest_or_signature_tampering_is_rejected(tmp_path, name):
    artifact_root = tmp_path / "artifacts"
    shutil.copytree(_artifact_root(), artifact_root)
    path = artifact_root / name
    value = bytearray(path.read_bytes())
    value[0] ^= 1
    path.write_bytes(value)

    with pytest.raises(MiniPluginRuntimeError, match="mini_plugin_artifact_invalid"):
        PackagedMiniPluginRuntime(artifact_root)


def test_actual_engine_exhausts_fuel_for_nonterminating_artifact():
    runtime = PackagedMiniPluginRuntime()
    looping = _wasm(
        r'''(module
          (import "larenor" "current_home_resource_count"
            (func $current_home_resource_count (result i32)))
          (memory (export "memory") 1 1)
          (func (export "render") (result i32)
            (loop $again br $again)
            i32.const 0))'''
    )

    with pytest.raises(MiniPluginRuntimeError) as caught:
        runtime._execute_module(looping, 1, strict_abi=True)
    assert caught.value.code == "mini_plugin_execution_limit"
    assert caught.value.boundary == "fuel"


def test_actual_store_denies_memory_growth_past_one_page():
    runtime = PackagedMiniPluginRuntime()
    growing = _wasm(
        r'''(module
          (import "larenor" "current_home_resource_count"
            (func $current_home_resource_count (result i32)))
          (memory (export "memory") 1 10)
          (func (export "render") (result i32)
            i32.const 1
            memory.grow
            i32.const -1
            i32.eq))'''
    )

    execution = runtime._execute_module(growing, 1, strict_abi=False)
    assert execution.resource_count == 1
    assert execution.evidence.linearMemoryBytesObserved == 65_536


def test_actual_engine_epoch_interrupts_when_fuel_is_not_first(monkeypatch):
    runtime = PackagedMiniPluginRuntime()
    monkeypatch.setattr(runtime_module, "FUEL_LIMIT", 1_000_000_000)
    looping = _wasm(
        r'''(module
          (import "larenor" "current_home_resource_count"
            (func $current_home_resource_count (result i32)))
          (memory (export "memory") 1 1)
          (func (export "render") (result i32)
            (loop $again br $again)
            i32.const 0))'''
    )

    with pytest.raises(MiniPluginRuntimeError) as caught:
        runtime._execute_module(looping, 1, strict_abi=True)
    assert caught.value.code == "mini_plugin_execution_limit"
    assert caught.value.boundary == "epoch"


def test_wasi_import_is_absent_in_production_linker():
    runtime = PackagedMiniPluginRuntime()
    wasi = _wasm(
        r'''(module
          (import "wasi_snapshot_preview1" "fd_write"
            (func $fd_write (param i32 i32 i32 i32) (result i32)))
          (memory (export "memory") 1 1)
          (func (export "render") (result i32) i32.const 0))'''
    )

    with pytest.raises(MiniPluginRuntimeError, match="mini_plugin_artifact_invalid"):
        runtime._execute_module(wasi, 1, strict_abi=False)


def test_function_references_are_disabled_in_engine_profile():
    runtime = PackagedMiniPluginRuntime()
    call_ref = _wasm(
        r'''(module
          (type $render_type (func (result i32)))
          (func $value (type $render_type) (result i32) i32.const 1)
          (elem declare func $value)
          (memory (export "memory") 1 1)
          (func (export "render") (result i32)
            ref.func $value
            call_ref $render_type))'''
    )

    with pytest.raises(MiniPluginRuntimeError, match="mini_plugin_artifact_invalid"):
        runtime._module(runtime._engine(), call_ref, strict_abi=False)


@pytest.mark.parametrize("value", [-1, 513, True, 1.0])
def test_current_home_capability_is_bounded_integer(value):
    with pytest.raises(
        MiniPluginRuntimeError, match="mini_plugin_capability_invalid"
    ):
        PackagedMiniPluginRuntime().execute(value)
