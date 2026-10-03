from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tool" / "f62_gateway_saf_public_bridge_contract.py"


def _load():
    spec = importlib.util.spec_from_file_location("f62_gateway_saf_public", MODULE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _source_root(tmp_path: Path) -> Path:
    module = _load()
    source = tmp_path / "source"
    test = source / module.TEST_PATH
    test.parent.mkdir(parents=True, exist_ok=True)
    test.write_bytes((ROOT / module.TEST_PATH).read_bytes())
    runtime_test = source / module.RUNTIME_TEST_PATH
    runtime_test.parent.mkdir(parents=True, exist_ok=True)
    runtime_test.write_bytes((ROOT / module.RUNTIME_TEST_PATH).read_bytes())
    provider = source / module.PROVIDER_PATH
    provider.parent.mkdir(parents=True, exist_ok=True)
    provider.write_text(
        "class RdpOwnedSafDocumentsProvider : DocumentsProvider() {\n"
        "override fun queryRoots() = Unit\n"
        "override fun queryDocument() = Unit\n"
        "override fun queryChildDocuments() = Unit\n"
        "override fun openDocument() = ParcelFileDescriptor.MODE_READ_WRITE\n"
        "override fun createDocument() = Unit\n"
        "fun assertProviderReadback() = Unit\n"
        "}\n",
        encoding="utf-8",
    )
    manifest = source / module.MANIFEST_PATH
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(
        '<provider android:name="RdpOwnedSafDocumentsProvider" '
        'android:exported="true" android:grantUriPermissions="true" '
        'android:permission="android.permission.MANAGE_DOCUMENTS">'
        '<intent-filter><action android:name="android.content.action.DOCUMENTS_PROVIDER"/>'
        '</intent-filter></provider>',
        encoding="utf-8",
    )
    return source


def test_current_owned_sources_pass_closed_contract(tmp_path: Path) -> None:
    module = _load()
    source = _source_root(tmp_path)
    receipt = module.verify_source(source)
    assert receipt["schemaVersion"] == 1
    assert receipt["clientWitnessSchemaVersion"] == 2
    assert receipt["testClass"] == module.TEST_CLASS
    assert receipt["testName"] == module.TEST_NAME
    assert receipt["targetPatchSha256"] == module.TARGET_PATCH_SHA256
    assert receipt["targetSourceManifestSha256"] == module.TARGET_SOURCE_MANIFEST_SHA256
    assert receipt["directTargetBlockedRequiresHostJoin"] is True
    assert receipt["expectedPayloadLengths"] == {"upload": 91, "outbound": 93}
    assert receipt["sourceSha256"] == {
        path: hashlib.sha256((source / path).read_bytes()).hexdigest()
        for path in sorted(module.SOURCE_PATHS)
    }


@pytest.mark.parametrize(
    ("needle", "replacement"),
    (
        ("OwnedRegisteredChannelClient(ownedActivity)", "FakeClient(ownedActivity)"),
        ("awaitWindowFocus(ownedActivity)", "ownedActivity.onWindowFocusChanged(true)"),
        ('MainActivity::class.java.getDeclaredField("rdpNative")', 'getDeclaredField("fake")'),
        ('getDeclaredField("handlersLock")', 'getDeclaredField("fakeLock")'),
        ("StandardMethodCodec.INSTANCE", "FakeCodec.INSTANCE"),
        ('assertEquals(true, security["rdGateway"])', 'assertEquals(false, security["rdGateway"])'),
        ('assertEquals(true, channels["files"])', 'assertEquals(false, channels["files"])'),
        ('assertEquals("connectionFailed", direct.awaitError(20))', "direct.awaitMap()"),
        ("Instrumentation.ActivityMonitor(", "FakeMonitor("),
        ('"drainFileTransfer"', '"cancel"'),
        ('assertState(drained, "sealed")', 'assertState(drained, "unknown")'),
        ('"saveReceivedFiles"', '"fileTransferObservation"'),
        ("RdpOwnedSafDocumentsProvider.assertProviderReadback", "assertMirrorOnly"),
        (
            "client.disposeProductionBridgeAndProveOwnersReleased()",
            "runCatching { client.disposeProductionBridgeAndProveOwnersReleased() }",
        ),
        ('put("schemaVersion", 2)', 'put("schemaVersion", 1)'),
    ),
)
def test_rejects_public_path_shortcuts(
    tmp_path: Path, needle: str, replacement: str,
) -> None:
    module = _load()
    source = _source_root(tmp_path)
    test = source / module.TEST_PATH
    text = test.read_text(encoding="utf-8")
    assert needle in text
    test.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
    with pytest.raises(module.ContractError):
        module.verify_source(source)


def test_rejects_admission_after_secret_or_picker(tmp_path: Path) -> None:
    module = _load()
    source = _source_root(tmp_path)
    test = source / module.TEST_PATH
    text = test.read_text(encoding="utf-8")
    admission = 'assertEquals(true, security["rdGateway"])'
    text = text.replace(admission, "", 1).replace(
        "val descriptor = OwnedDescriptor.load(appContext)",
        "val descriptor = OwnedDescriptor.load(appContext)\n            " + admission,
        1,
    )
    test.write_text(text, encoding="utf-8")
    with pytest.raises(module.ContractError, match="admission_order"):
        module.verify_source(source)


@pytest.mark.parametrize(
    ("needle", "replacement"),
    (
        ("pinnedFlutterMessengerWrapperResolvesRegisteredHandlerUnderItsActualLock", "staticShapeOnly"),
        ('Class.forName(DEFAULT_BINARY_MESSENGER)', 'Class.forName("fake")'),
        ('getDeclaredField("handlersLock")', 'getDeclaredField("fakeLock")'),
        ("encodedCall.flip()", "encodedCall.clear()"),
        ("encodedReply.flip()", "encodedReply.clear()"),
    ),
)
def test_rejects_missing_pinned_flutter_runtime_contract(
    tmp_path: Path, needle: str, replacement: str,
) -> None:
    module = _load()
    source = _source_root(tmp_path)
    runtime_test = source / module.RUNTIME_TEST_PATH
    text = runtime_test.read_text(encoding="utf-8")
    assert needle in text
    runtime_test.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
    with pytest.raises(module.ContractError):
        module.verify_source(source)


def test_rejects_save_before_confirmed_seal(tmp_path: Path) -> None:
    module = _load()
    source = _source_root(tmp_path)
    test = source / module.TEST_PATH
    text = test.read_text(encoding="utf-8")
    text = text.replace('assertState(drained, "sealed")', "", 1).replace(
        'assertState(saved, "saved")',
        'assertState(saved, "saved")\n                assertState(drained, "sealed")',
        1,
    )
    test.write_text(text, encoding="utf-8")
    with pytest.raises(module.ContractError, match="effect_order"):
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

    source = _source_root(tmp_path / "manifest")
    manifest = source / module.MANIFEST_PATH
    manifest.write_text(
        manifest.read_text(encoding="utf-8").replace(
            'android:grantUriPermissions="true"', 'android:grantUriPermissions="false"', 1,
        ),
        encoding="utf-8",
    )
    with pytest.raises(module.ContractError):
        module.verify_source(source)


def test_cli_receipt_is_closed_and_contains_no_private_values(tmp_path: Path, capsys) -> None:
    module = _load()
    source = _source_root(tmp_path)
    assert module.main(["verify-source", "--source", str(source)]) == 0
    receipt = json.loads(capsys.readouterr().out)
    assert set(receipt) == {
        "schemaVersion", "clientWitnessSchemaVersion", "testClass", "testName",
        "targetPatchSha256", "targetSourceManifestSha256", "expectedPayloadLengths",
        "sourceSha256", "directTargetBlockedRequiresHostJoin",
    }
    encoded = json.dumps(receipt)
    assert "password" not in encoded.lower()
    assert "gatewayHost" not in encoded
