from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tool" / "f62_gateway_saf_acceptance_contract.py"


def _load():
    spec = importlib.util.spec_from_file_location("f62_gateway_saf_contract", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _source_root(tmp_path: Path) -> Path:
    source = tmp_path / "source"
    for relative in (
        "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
        "RdpPackagedGatewaySafAcceptanceTest.kt",
        "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
        "RdpOwnedSafDocumentsProvider.kt",
        "android/app/src/androidTest/AndroidManifest.xml",
    ):
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text((ROOT / relative).read_text(encoding="utf-8"), encoding="utf-8")
    return source


def test_current_owned_sources_pass_closed_contract(tmp_path: Path) -> None:
    module = _load()
    source = _source_root(tmp_path)
    receipt = module.verify_source(source)

    assert receipt["schemaVersion"] == 1
    assert receipt["clientWitnessSchemaVersion"] == 2
    assert receipt["testClass"] == (
        "com.ersingundem.larenor.rdp.RdpPackagedGatewaySafAcceptanceTest"
    )
    assert receipt["testName"] == (
        "gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain"
    )
    assert receipt["expectedPayloadLengths"] == {"upload": 91, "outbound": 93}
    assert receipt["sourceSha256"] == {
        path: hashlib.sha256((source / path).read_bytes()).hexdigest()
        for path in sorted(module.SOURCE_PATHS)
    }


@pytest.mark.parametrize(
    ("needle", "replacement"),
    (
        ("RdpPackagedRuntime(ownedActivity)", "FakeRuntime(ownedActivity)"),
        ("RdpSafTransferCoordinator(", "FakeTransferCoordinator("),
        ("inspectTargetThroughGateway", "inspectTargetDirectly"),
        ("transfers.drain(", "transfers.cancel("),
        ('assertState(drain.awaitMap(40), "sealed")', 'assertState(drain.awaitMap(40), "saved")'),
        ("assertProviderReadback", "assertMirrorOnly"),
        ('"Larenor-F62-Gateway-upload:"', '"LRNUPL01"'),
        ('"Larenor-F62-Gateway-outbound:"', '"LRNDWN01"'),
        ("assertWrongPinRejected", "ignoreWrongPin"),
        ('put("schemaVersion", 2)', 'put("schemaVersion", 1)'),
        ('File(canonicalRoot, "FromRemote/$name")', 'File(canonicalRoot, name)'),
        ('requireNotNull(host.requestCode),', 'requireNotNull(host.requestCode) + 1,'),
    ),
)
def test_rejects_acceptance_shortcuts(
    tmp_path: Path,
    needle: str,
    replacement: str,
) -> None:
    module = _load()
    source = _source_root(tmp_path)
    test_file = source / module.TEST_PATH
    text = test_file.read_text(encoding="utf-8")
    assert needle in text
    test_file.write_text(text.replace(needle, replacement, 1), encoding="utf-8")

    with pytest.raises(module.ContractError):
        module.verify_source(source)


def test_rejects_provider_or_manifest_weakening(tmp_path: Path) -> None:
    module = _load()
    source = _source_root(tmp_path)
    provider = source / module.PROVIDER_PATH
    provider.write_text(
        provider.read_text(encoding="utf-8").replace("MODE_READ_WRITE", "MODE_READ_ONLY", 1),
        encoding="utf-8",
    )
    with pytest.raises(module.ContractError):
        module.verify_source(source)

    source = _source_root(tmp_path / "second")
    manifest = source / module.MANIFEST_PATH
    manifest.write_text(
        manifest.read_text(encoding="utf-8").replace(
            'android:grantUriPermissions="true"',
            'android:grantUriPermissions="false"',
        ),
        encoding="utf-8",
    )
    with pytest.raises(module.ContractError):
        module.verify_source(source)


def test_cli_writes_closed_receipt_without_source_text(tmp_path: Path, capsys) -> None:
    module = _load()
    source = _source_root(tmp_path)
    assert module.main(["verify-source", "--source", str(source)]) == 0
    receipt = json.loads(capsys.readouterr().out)

    assert set(receipt) == {
        "schemaVersion",
        "clientWitnessSchemaVersion",
        "testClass",
        "testName",
        "expectedPayloadLengths",
        "sourceSha256",
    }
    encoded = json.dumps(receipt)
    assert "password" not in encoded.lower()
    assert "gatewayHost" not in encoded
