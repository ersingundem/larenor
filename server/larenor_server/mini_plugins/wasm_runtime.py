"""Signed, fixed-catalog WebAssembly runtime for bounded mini plugins.

The runtime never accepts module bytes, paths, or import definitions from an
API caller. It loads one packaged artifact, verifies its pinned manifest and
Ed25519 signature, validates a closed ABI, and exposes one scalar capability
that the caller must derive from its current authorized home transaction.
"""

from __future__ import annotations

import base64
import hashlib
import importlib.metadata
import importlib.resources
import json
import threading
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import wasmtime
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


ARTIFACT_NAME = "home_resource_count_v1.wasm"
MANIFEST_NAME = "home_resource_count_v1.manifest.json"
SIGNATURE_NAME = "home_resource_count_v1.manifest.sig"
ARTIFACT_SHA256 = "7bdd159c4e384d2413d04b0bbf6ee8b26c4ea179c089258269e44accee04a8bf"
MANIFEST_SHA256 = "d9d6888d352881fc02d0123160345648417621b6943c6a98212a25ced1578a28"
TRUSTED_PUBLIC_KEY = bytes.fromhex(
    "93e88da25290d2c25ddd23d69f1ba6c72e3065794d3b2a001d962510a3aa4d95"
)
WASMTIME_VERSION = "49.0.0"
FUEL_LIMIT = 50_000
LINEAR_MEMORY_LIMIT_BYTES = 65_536
EPOCH_DEADLINE_TICKS = 1
EPOCH_INCREMENT_AFTER_SECONDS = 0.100
MAX_RESOURCE_COUNT = 512


def packaged_runtime_contract() -> dict[str, Any]:
    return {
        "artifactId": "home-resource-count",
        "artifactVersion": 1,
        "artifactSha256": ARTIFACT_SHA256,
        "manifestSha256": MANIFEST_SHA256,
        "manifestSignatureAlgorithm": "Ed25519",
        "manifestSignatureVerified": True,
        "abi": "larenor.mini-plugin.v1",
        "engine": f"wasmtime-{WASMTIME_VERSION}",
        "allowedImports": [
            "larenor.current_home_resource_count()->i32",
        ],
        "wasiEnabled": False,
    }


class MiniPluginRuntimeError(Exception):
    """A closed runtime failure that is safe to map to a public error code."""

    def __init__(self, code: str, *, boundary: str | None = None):
        super().__init__(code)
        self.code = code
        self.boundary = boundary


@dataclass(frozen=True)
class MiniPluginExecutionEvidence:
    artifactSha256: str
    manifestSha256: str
    manifestSignatureVerified: bool
    engine: str
    fuelLimit: int
    fuelConsumed: int
    linearMemoryLimitBytes: int
    linearMemoryBytesObserved: int
    epochDeadlineTicks: int
    epochIncrementAfterMilliseconds: int
    wasiEnabled: bool
    allowedImports: tuple[str, ...]

    def public(self) -> dict[str, Any]:
        value = asdict(self)
        value["allowedImports"] = list(self.allowedImports)
        return value


@dataclass(frozen=True)
class MiniPluginExecution:
    resource_count: int
    evidence: MiniPluginExecutionEvidence


def _expected_manifest() -> dict[str, Any]:
    return {
        "abi": "larenor.mini-plugin.v1",
        "artifactId": "home-resource-count",
        "artifactSha256": ARTIFACT_SHA256,
        "artifactVersion": 1,
        "capabilities": ["home.resource_count.read"],
        "engine": {"name": "wasmtime", "version": WASMTIME_VERSION},
        "entrypoint": "render",
        "exports": [
            {
                "kind": "memory",
                "maximumPages": 1,
                "minimumPages": 1,
                "name": "memory",
            },
            {
                "kind": "function",
                "name": "render",
                "params": [],
                "results": ["i32"],
            },
        ],
        "imports": [
            {
                "kind": "function",
                "module": "larenor",
                "name": "current_home_resource_count",
                "params": [],
                "results": ["i32"],
            }
        ],
        "limits": {
            "epochDeadlineMilliseconds": 100,
            "epochDeadlineTicks": EPOCH_DEADLINE_TICKS,
            "fuelUnits": FUEL_LIMIT,
            "instances": 1,
            "linearMemoryBytes": LINEAR_MEMORY_LIMIT_BYTES,
            "memories": 1,
            "outputBytes": 1024,
            "tables": 0,
        },
        "schemaVersion": 1,
        "wasi": False,
    }


def _read(root, name: str, *, maximum: int) -> bytes:
    try:
        value = root.joinpath(name).read_bytes()
    except (FileNotFoundError, OSError):
        raise MiniPluginRuntimeError("mini_plugin_artifact_invalid") from None
    if not 1 <= len(value) <= maximum:
        raise MiniPluginRuntimeError("mini_plugin_artifact_invalid")
    return value


class PackagedMiniPluginRuntime:
    """Execute the one signed artifact through a fresh isolated Wasmtime store."""

    def __init__(self, artifact_directory: Path | None = None):
        root = artifact_directory or importlib.resources.files(
            "larenor_server.mini_plugins"
        ).joinpath("artifacts")
        artifact = _read(root, ARTIFACT_NAME, maximum=4096)
        manifest_bytes = _read(root, MANIFEST_NAME, maximum=8192)
        signature_text = _read(root, SIGNATURE_NAME, maximum=256)

        if hashlib.sha256(artifact).hexdigest() != ARTIFACT_SHA256:
            raise MiniPluginRuntimeError("mini_plugin_artifact_invalid")
        if hashlib.sha256(manifest_bytes).hexdigest() != MANIFEST_SHA256:
            raise MiniPluginRuntimeError("mini_plugin_artifact_invalid")
        try:
            signature = base64.b64decode(signature_text.strip(), validate=True)
            if len(signature) != 64:
                raise ValueError
            Ed25519PublicKey.from_public_bytes(TRUSTED_PUBLIC_KEY).verify(
                signature, manifest_bytes
            )
        except (InvalidSignature, ValueError):
            raise MiniPluginRuntimeError("mini_plugin_artifact_invalid") from None
        try:
            manifest = json.loads(manifest_bytes.decode("ascii"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise MiniPluginRuntimeError("mini_plugin_artifact_invalid") from None
        if manifest != _expected_manifest():
            raise MiniPluginRuntimeError("mini_plugin_artifact_invalid")
        try:
            installed_version = importlib.metadata.version("wasmtime")
        except importlib.metadata.PackageNotFoundError:
            raise MiniPluginRuntimeError("mini_plugin_runtime_unavailable") from None
        if installed_version != WASMTIME_VERSION:
            raise MiniPluginRuntimeError("mini_plugin_runtime_unavailable")

        # Validate the exact packaged ABI before any request can use it.
        engine = self._engine()
        self._module(engine, artifact, strict_abi=True)
        self._artifact = artifact

    @staticmethod
    def _engine() -> wasmtime.Engine:
        config = wasmtime.Config()
        config.consume_fuel = True
        config.epoch_interruption = True
        # wasmtime-py 49.0.0 is the newest published Python binding, while the
        # upstream engine's 49.0.1 fuel-accounting fixes are not yet available
        # through that binding. Keep the signed fixed artifact on the narrow
        # core-Wasm profile it needs and reject those optional proposal paths.
        config.wasm_component_model = False
        config.wasm_function_references = False
        config.wasm_gc = False
        config.gc_support = False
        config.wasm_exceptions = False
        config.wasm_tail_call = False
        config.wasm_simd = False
        config.wasm_relaxed_simd = False
        config.wasm_threads = False
        config.wasm_multi_memory = False
        config.wasm_memory64 = False
        config.max_wasm_stack = 64 * 1024
        return wasmtime.Engine(config)

    @staticmethod
    def _module(
        engine: wasmtime.Engine, artifact: bytes, *, strict_abi: bool
    ) -> wasmtime.Module:
        try:
            module = wasmtime.Module(engine, artifact)
        except wasmtime.WasmtimeError:
            raise MiniPluginRuntimeError("mini_plugin_artifact_invalid") from None
        if not strict_abi:
            return module

        imports = list(module.imports)
        exports = {item.name: item.type for item in module.exports}
        valid_import = (
            len(imports) == 1
            and imports[0].module == "larenor"
            and imports[0].name == "current_home_resource_count"
            and isinstance(imports[0].type, wasmtime.FuncType)
            and list(imports[0].type.params) == []
            and list(imports[0].type.results) == [wasmtime.ValType.i32()]
        )
        render_type = exports.get("render")
        memory_type = exports.get("memory")
        valid_exports = (
            set(exports) == {"memory", "render"}
            and isinstance(render_type, wasmtime.FuncType)
            and list(render_type.params) == []
            and list(render_type.results) == [wasmtime.ValType.i32()]
            and isinstance(memory_type, wasmtime.MemoryType)
            and memory_type.limits.min == 1
            and memory_type.limits.max == 1
            and not memory_type.is_64
            and not memory_type.is_shared
        )
        if not valid_import or not valid_exports:
            raise MiniPluginRuntimeError("mini_plugin_artifact_invalid")
        return module

    def execute(self, current_home_resource_count: int) -> MiniPluginExecution:
        if (
            type(current_home_resource_count) is not int
            or not 0 <= current_home_resource_count <= MAX_RESOURCE_COUNT
        ):
            raise MiniPluginRuntimeError("mini_plugin_capability_invalid")
        return self._execute_module(
            self._artifact,
            current_home_resource_count,
            strict_abi=True,
        )

    def _execute_module(
        self,
        artifact: bytes,
        current_home_resource_count: int,
        *,
        strict_abi: bool,
    ) -> MiniPluginExecution:
        """Private probe seam used to test the production sandbox itself."""
        engine = self._engine()
        module = self._module(engine, artifact, strict_abi=strict_abi)
        store = wasmtime.Store(engine)
        store.set_limits(
            memory_size=LINEAR_MEMORY_LIMIT_BYTES,
            table_elements=0,
            instances=1,
            tables=0,
            memories=1,
        )
        store.set_fuel(FUEL_LIMIT)
        store.set_epoch_deadline(EPOCH_DEADLINE_TICKS)
        linker = wasmtime.Linker(engine)
        linker.define_func(
            "larenor",
            "current_home_resource_count",
            wasmtime.FuncType([], [wasmtime.ValType.i32()]),
            lambda: current_home_resource_count,
        )
        try:
            instance = linker.instantiate(store, module)
            render = instance.exports(store)["render"]
            memory = instance.exports(store)["memory"]
        except (KeyError, wasmtime.WasmtimeError):
            raise MiniPluginRuntimeError("mini_plugin_artifact_invalid") from None

        fuel_before = store.get_fuel()
        timer = threading.Timer(EPOCH_INCREMENT_AFTER_SECONDS, engine.increment_epoch)
        timer.daemon = True
        timer.start()
        try:
            result = render(store)
        except wasmtime.Trap as error:
            boundary = {
                wasmtime.TrapCode.OUT_OF_FUEL: "fuel",
                wasmtime.TrapCode.INTERRUPT: "epoch",
            }.get(error.trap_code, "trap")
            raise MiniPluginRuntimeError(
                "mini_plugin_execution_limit", boundary=boundary
            ) from None
        finally:
            timer.cancel()
        fuel_after = store.get_fuel()
        observed_memory = memory.data_len(store)
        if (
            type(result) is not int
            or not 0 <= result <= MAX_RESOURCE_COUNT
            or not 0 <= fuel_after <= fuel_before <= FUEL_LIMIT
            or not 0 <= observed_memory <= LINEAR_MEMORY_LIMIT_BYTES
        ):
            raise MiniPluginRuntimeError("mini_plugin_execution_invalid")
        return MiniPluginExecution(
            resource_count=result,
            evidence=MiniPluginExecutionEvidence(
                artifactSha256=ARTIFACT_SHA256,
                manifestSha256=MANIFEST_SHA256,
                manifestSignatureVerified=True,
                engine=f"wasmtime-{WASMTIME_VERSION}",
                fuelLimit=FUEL_LIMIT,
                fuelConsumed=fuel_before - fuel_after,
                linearMemoryLimitBytes=LINEAR_MEMORY_LIMIT_BYTES,
                linearMemoryBytesObserved=observed_memory,
                epochDeadlineTicks=EPOCH_DEADLINE_TICKS,
                epochIncrementAfterMilliseconds=int(
                    EPOCH_INCREMENT_AFTER_SECONDS * 1000
                ),
                wasiEnabled=False,
                allowedImports=(
                    "larenor.current_home_resource_count()->i32",
                ),
            ),
        )
