from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import sys

import pytest


ROOT = Path(__file__).resolve().parents[2]
ADAPTER_PATH = ROOT / "tool/f62_gateway_saf_android_client.py"
FIXTURE_PATH = ROOT / "tool/f62_rdpgw_owned_fixture.py"


def load_adapter():
    spec = importlib.util.spec_from_file_location("f62_android_adapter", ADAPTER_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def private_write(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(value)
    path.chmod(0o600)


def source_bundle(tmp_path: Path, module, scenario: str = "direct"):
    _, _, _, paths = module.scenario_spec(scenario)
    source = tmp_path / "source"
    manifest = {
        "schemaVersion": 1,
        "targetPatchSha256": module.TARGET_PATCH_SHA256,
        "targetSourceManifestSha256": module.TARGET_MANIFEST_SHA256,
        "compileLogSha256": "a" * 64,
        "files": {},
    }
    for relative in sorted(paths):
        raw = (ROOT / relative).read_bytes()
        private_write(source / relative, raw)
        manifest["files"][relative] = hashlib.sha256(raw).hexdigest()
    manifest_path = tmp_path / "source-manifest.json"
    private_write(manifest_path, json.dumps(manifest).encode())
    return source, manifest_path, manifest


def descriptor(tmp_path: Path) -> tuple[Path, dict]:
    nonce = "a" * 64
    value = {
        "schemaVersion": 2,
        "nonce": nonce,
        "testClass": "com.ersingundem.larenor.rdp.RdpPackagedGatewaySafAcceptanceTest",
        "testName": "gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain",
        "gatewayHost": "10.0.2.2",
        "gatewayPort": 4443,
        "gatewayUsername": "gw_owned",
        "gatewayPassword": "private-gateway-secret",
        "gatewayDomain": "LARENOR",
        "gatewayPin": "SHA256:" + "A" * 43,
        "targetHost": "10.219.1.2",
        "targetPort": 3390,
        "targetUsername": "target_owned",
        "targetDomain": "LARENOR",
        "targetPassword": "private-target-secret",
        "targetPin": "SHA256:" + "B" * 43,
        "expectedUploadSha256": "b" * 64,
        "expectedOutboundSha256": "c" * 64,
        "witnessPath": str(tmp_path / "private-witness.json"),
    }
    path = tmp_path / "fixture.json"
    private_write(path, (json.dumps(value) + "\n").encode())
    return path, value


def test_device_descriptor_is_closed_and_keeps_secrets_off_arguments(tmp_path: Path) -> None:
    module = load_adapter()
    path, original = descriptor(tmp_path)
    fixture = module.validate_generic_descriptor(path)
    raw = module.make_device_descriptor(
        fixture,
        source_sha256="d" * 64,
        test_sha256="e" * 64,
        fixture_source_sha256="f" * 64,
    )
    value = json.loads(raw)
    assert set(value) == module.DEVICE_KEYS
    assert value["gatewayPassword"] == original["gatewayPassword"]
    assert value["targetPassword"] == original["targetPassword"]
    assert value["gatewayDomain"] == "LARENOR"
    source = ADAPTER_PATH.read_text()
    instrument = source[source.index('"shell", "am", "instrument"'):]
    instrument = instrument[:instrument.index("parse_instrumentation")]
    assert "gatewayPassword" not in instrument
    assert "targetPassword" not in instrument


def test_generic_descriptor_rejects_missing_domain_and_existing_witness(tmp_path: Path) -> None:
    module = load_adapter()
    path, value = descriptor(tmp_path)
    del value["gatewayDomain"]
    private_write(path, json.dumps(value).encode())
    with pytest.raises(module.AdapterError):
        module.validate_generic_descriptor(path)

    path, value = descriptor(tmp_path / "second")
    private_write(Path(value["witnessPath"]), b"stale")
    with pytest.raises(module.AdapterError):
        module.validate_generic_descriptor(path)


def test_source_manifest_binds_every_file_and_exact_test(tmp_path: Path) -> None:
    module = load_adapter()
    source, manifest_path, manifest = source_bundle(tmp_path, module)
    manifest_sha, test_sha = module.validate_source_manifest(manifest_path, source)
    assert manifest_sha == hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    assert test_sha == manifest["files"][module.TEST_PATH]

    test = source / module.TEST_PATH
    private_write(test, test.read_bytes() + b"\n")
    with pytest.raises(module.AdapterError):
        module.validate_source_manifest(manifest_path, source)


def test_android_build_receipt_binds_both_apks_product_and_verifier(tmp_path: Path) -> None:
    module = load_adapter()
    files = {}
    for name, raw in {
        "app.apk": b"app", "test.apk": b"test", "product.json": b"product",
        "verifier.py": b"verifier",
    }.items():
        path = tmp_path / name
        private_write(path, raw)
        files[name] = path
    receipt = {
        "schemaVersion": 1,
        "appApkSha256": module.sha256(files["app.apk"]),
        "testApkSha256": module.sha256(files["test.apk"]),
        "productNativeReceiptSha256": module.sha256(files["product.json"]),
        "sourceManifestSha256": "a" * 64,
        "testSourceSha256": "b" * 64,
        "productVerifierSha256": module.sha256(files["verifier.py"]),
        "applicationId": module.APP_ID,
        "testApplicationId": module.TEST_ID,
        "instrumentationRunner": module.RUNNER,
    }
    path = tmp_path / "build.json"
    private_write(path, json.dumps(receipt).encode())
    module.validate_build_receipt(
        path, app_apk=files["app.apk"], test_apk=files["test.apk"],
        product_receipt=files["product.json"], source_manifest_sha256="a" * 64,
        test_source_sha256="b" * 64, product_verifier=files["verifier.py"],
    )
    private_write(files["test.apk"], b"changed")
    with pytest.raises(module.AdapterError):
        module.validate_build_receipt(
            path, app_apk=files["app.apk"], test_apk=files["test.apk"],
            product_receipt=files["product.json"], source_manifest_sha256="a" * 64,
            test_source_sha256="b" * 64, product_verifier=files["verifier.py"],
        )


def instrumentation(success: bool = True, scenario: str = "direct") -> bytes:
    module = load_adapter()
    test_class, test_name, _, _ = module.scenario_spec(scenario)
    tail = (
        "INSTRUMENTATION_STATUS: class=" + test_class + "\n"
        "INSTRUMENTATION_STATUS: current=1\n"
        "INSTRUMENTATION_STATUS: id=AndroidJUnitRunner\n"
        "INSTRUMENTATION_STATUS: numtests=1\n"
        "INSTRUMENTATION_STATUS: stream=.\n"
        "INSTRUMENTATION_STATUS: test=" + test_name + "\n"
        "INSTRUMENTATION_STATUS_CODE: 1\n"
        "INSTRUMENTATION_STATUS: class=" + test_class + "\n"
        "INSTRUMENTATION_STATUS: current=1\n"
        "INSTRUMENTATION_STATUS: id=AndroidJUnitRunner\n"
        "INSTRUMENTATION_STATUS: numtests=1\n"
        "INSTRUMENTATION_STATUS: stream=.\n"
        "INSTRUMENTATION_STATUS: test=" + test_name + "\n"
        "INSTRUMENTATION_STATUS_CODE: 0\n"
        "INSTRUMENTATION_CODE: -1\n"
    )
    if not success:
        tail += "FAILURES!!!\n"
    return tail.encode()


def test_instrumentation_requires_exact_single_named_success() -> None:
    module = load_adapter()
    module.parse_instrumentation(instrumentation())
    with pytest.raises(module.AdapterError):
        module.parse_instrumentation(instrumentation(False))
    with pytest.raises(module.AdapterError):
        module.parse_instrumentation(instrumentation().replace(b"numtests=1", b"numtests=2"))
    with pytest.raises(module.AdapterError):
        module.parse_instrumentation(instrumentation() + instrumentation())


def test_private_fixture_real_shadow_mode_is_source_bound() -> None:
    source = FIXTURE_PATH.read_text()
    assert 'sp.add_parser("run-android")' in source
    assert "validate_full_target_build_receipt" in source
    assert 'value.get("sourceManifestSha256") != TARGET_SOURCE_MANIFEST_SHA' in source
    assert '"/sec:nla"' in source
    assert 'f"/sam-file:{target_sam}"' in source
    assert '"/may-interact"' in source
    assert '"gatewayDomain": "LARENOR"' in source
    assert "LARENOR_F62_TARGET_WITNESS" in source
    assert "EnableDrive: true" in source
    assert "DisableRedirect: false" in source


def test_full_shadow_receipt_binds_binary_patch_and_source_manifest(tmp_path: Path) -> None:
    spec = importlib.util.spec_from_file_location("f62_owned_fixture", FIXTURE_PATH)
    assert spec and spec.loader
    fixture_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture_module)
    shadow = tmp_path / "freerdp-shadow-cli"
    private_write(shadow, b"owned-shadow")
    shadow.chmod(0o700)
    receipt = {
        "schemaVersion": 1,
        "sourceRevision": fixture_module.TARGET_REVISION,
        "sourceArchiveSha256": fixture_module.TARGET_ARCHIVE_SHA,
        "targetPatchSha256": fixture_module.TARGET_PATCH_SHA,
        "sourceManifestSha256": fixture_module.TARGET_SOURCE_MANIFEST_SHA,
        "cmakeArgumentsSha256": "a" * 64,
        "shadowBinarySha256": fixture_module.sha256(shadow),
        "xfreerdpBinarySha256": "b" * 64,
        "witnessSchemaVersion": 2,
        "deviceName": "LrnXfer",
    }
    path = tmp_path / "receipt.json"
    private_write(path, json.dumps(receipt).encode())
    fixture_module.validate_full_target_build_receipt(path, shadow)
    receipt["sourceManifestSha256"] = "c" * 64
    private_write(path, json.dumps(receipt).encode())
    with pytest.raises(fixture_module.FixtureError):
        fixture_module.validate_full_target_build_receipt(path, shadow)


def test_adapter_uses_stdin_run_as_and_bounded_witness_read() -> None:
    source = ADAPTER_PATH.read_text()
    assert '"exec-in", "run-as", APP_ID' in source
    assert "input_bytes=bytes(descriptor)" in source
    assert "cat > {device_descriptor} && chmod 600" in source
    assert '"rdpGatewaySafNonce", nonce' in source
    assert '"rdpGatewaySafSourceSha256", source_digest' in source
    assert '"rdpGatewaySafTestSha256", test_digest' in source
    assert '"exec-out", "run-as", APP_ID, "dd"' in source
    assert '"bs=2049", "count=1"' in source
    assert "len(readback.stdout) > 2048" in source


def test_no_acceptance_upgrade_or_raw_secret_output() -> None:
    combined = ADAPTER_PATH.read_text() + FIXTURE_PATH.read_text()
    assert "featureAccepted\": True" not in combined
    assert "print(descriptor" not in combined
    assert "print(fixture" not in combined
    assert "gatewayPassword=" not in combined
    assert "targetPassword=" not in combined


@pytest.mark.parametrize("scenario", ["direct", "public"])
def test_full_adapter_uses_stdin_and_returns_exact_closed_witness(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    scenario: str,
) -> None:
    module = load_adapter()
    descriptor_path, fixture = descriptor(tmp_path)
    test_class, test_name, test_path, _ = module.scenario_spec(scenario)
    fixture.update(testClass=test_class, testName=test_name)
    private_write(descriptor_path, json.dumps(fixture).encode())
    source, manifest_path, manifest = source_bundle(tmp_path, module, scenario)
    app = tmp_path / "app.apk"
    test_apk = tmp_path / "test.apk"
    product = tmp_path / "product-native-receipt.json"
    for path, value in ((app, b"app"), (test_apk, b"test"), (product, b"product")):
        private_write(path, value)
    verifier = tmp_path / "product_android_native.py"
    private_write(verifier, b"#!/usr/bin/env python3\nraise SystemExit(0)\n")
    verifier.chmod(0o700)
    state = tmp_path / "adb-state"
    state.mkdir(mode=0o700)
    adb = tmp_path / "adb"
    fake = f'''#!{sys.executable}
import json, os, pathlib, sys
state = pathlib.Path(os.environ["FAKE_ADB_STATE"])
args = sys.argv[1:]
if args[:1] == ["install"]:
    print("Success")
    raise SystemExit(0)
if args[:4] == ["exec-in", "run-as", "{module.APP_ID}", "sh"]:
    raw = sys.stdin.buffer.read()
    (state / "descriptor.json").write_bytes(raw)
    raise SystemExit(0)
if args[:3] == ["shell", "am", "instrument"]:
    descriptor = json.loads((state / "descriptor.json").read_text())
    witness = {{
      "schemaVersion":2,"nonce":descriptor["nonce"],
      "testClass":"{test_class}","testName":"{test_name}",
      "tests":1,"failures":0,"errors":0,"skipped":0,
      "directTargetBlocked":True,"gatewayPinMatched":True,"targetPinMatched":True,
      "frameAcknowledged":True,"nativeDrainConfirmed":True,
      "safReadbackSha256":descriptor["expectedOutboundSha256"],"ownersRetired":True}}
    (state / "witness.json").write_text(json.dumps(witness,separators=(",",":")))
    print({instrumentation(scenario=scenario)!r}.decode(), end="")
    raise SystemExit(0)
if args[:4] == ["exec-out", "run-as", "{module.APP_ID}", "dd"]:
    sys.stdout.buffer.write((state / "witness.json").read_bytes())
    raise SystemExit(0)
if args[:3] == ["shell", "run-as", "{module.APP_ID}"] and "rm" in args:
    raise SystemExit(0)
raise SystemExit(3)
'''
    private_write(adb, fake.encode())
    adb.chmod(0o700)
    source_sha = module.sha256(manifest_path)
    test_sha = manifest["files"][test_path]
    build = tmp_path / "android-build-receipt.json"
    private_write(build, json.dumps({
        "schemaVersion": 1,
        "appApkSha256": module.sha256(app),
        "testApkSha256": module.sha256(test_apk),
        "productNativeReceiptSha256": module.sha256(product),
        "sourceManifestSha256": source_sha,
        "testSourceSha256": test_sha,
        "productVerifierSha256": module.sha256(verifier),
        "applicationId": module.APP_ID,
        "testApplicationId": module.TEST_ID,
        "instrumentationRunner": module.RUNNER,
    }).encode())
    native_dir = tmp_path / "native"
    native_dir.mkdir(mode=0o700)
    monkeypatch.setenv("LARENOR_F62_RDGW_DESCRIPTOR", str(descriptor_path))
    monkeypatch.setenv("FAKE_ADB_STATE", str(state))
    private_log = tmp_path / "instrumentation.log"
    result = module.main([
        "--scenario", scenario,
        "--adb", str(adb), "--python", sys.executable,
        "--product-verifier", str(verifier), "--product-native-dir", str(native_dir),
        "--product-receipt", str(product), "--app-apk", str(app),
        "--test-apk", str(test_apk), "--android-build-receipt", str(build),
        "--source-root", str(source), "--source-manifest", str(manifest_path),
        "--fixture-source", str(FIXTURE_PATH), "--private-log", str(private_log),
    ])
    assert result == 0
    witness = json.loads(Path(fixture["witnessPath"]).read_text())
    assert witness["tests"] == 1
    assert witness["failures"] == witness["errors"] == witness["skipped"] == 0
    assert witness["safReadbackSha256"] == fixture["expectedOutboundSha256"]
    assert private_log.stat().st_mode & 0o777 == 0o600


def test_public_gate_cannot_consume_a_direct_named_result(tmp_path: Path):
    module = load_adapter()
    path, _ = descriptor(tmp_path)
    with pytest.raises(module.AdapterError):
        module.validate_generic_descriptor(path, scenario="public")
    with pytest.raises(module.AdapterError):
        module.parse_instrumentation(instrumentation(), scenario="public")
    module.parse_instrumentation(instrumentation(scenario="public"), scenario="public")


@pytest.mark.parametrize("port", ["gatewayPort", "targetPort"])
def test_boolean_port_is_not_an_integer_endpoint(tmp_path: Path, port: str):
    module = load_adapter()
    path, value = descriptor(tmp_path)
    value[port] = True
    private_write(path, json.dumps(value).encode())
    with pytest.raises(module.AdapterError):
        module.validate_generic_descriptor(path)


def test_source_manifest_cannot_omit_provider_or_registered_runtime(tmp_path: Path):
    module = load_adapter()
    source, path, manifest = source_bundle(tmp_path, module, "public")
    runtime = next(p for p in manifest["files"] if p.endswith("RdpPublicBridgeRuntimeContractTest.kt"))
    del manifest["files"][runtime]
    private_write(path, json.dumps(manifest).encode())
    with pytest.raises(module.AdapterError):
        module.validate_source_manifest(path, source, scenario="public")


def test_public_source_manifest_requires_bridge_admission_runtime_and_native_lock(tmp_path: Path):
    module = load_adapter()
    source, path, manifest = source_bundle(tmp_path, module, "public")
    required = module._PUBLIC_PRODUCT_SOURCE_PATHS
    assert required <= manifest["files"].keys()
    for relative in sorted(required):
        changed = json.loads(json.dumps(manifest))
        del changed["files"][relative]
        candidate = tmp_path / (hashlib.sha256(relative.encode()).hexdigest() + ".json")
        private_write(candidate, json.dumps(changed).encode())
        with pytest.raises(module.AdapterError):
            module.validate_source_manifest(candidate, source, scenario="public")
