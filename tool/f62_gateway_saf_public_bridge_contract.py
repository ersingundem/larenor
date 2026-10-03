#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Sequence

TEST_PATH = (
    "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
    "RdpPackagedGatewaySafPublicBridgeAcceptanceTest.kt"
)
RUNTIME_TEST_PATH = (
    "android/app/src/freerdpTest/kotlin/com/ersingundem/larenor/rdp/"
    "RdpPublicBridgeRuntimeContractTest.kt"
)
PROVIDER_PATH = (
    "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
    "RdpOwnedSafDocumentsProvider.kt"
)
MANIFEST_PATH = "android/app/src/androidTest/AndroidManifest.xml"
SOURCE_PATHS = (TEST_PATH, RUNTIME_TEST_PATH, PROVIDER_PATH, MANIFEST_PATH)
TEST_CLASS = "com.ersingundem.larenor.rdp.RdpPackagedGatewaySafPublicBridgeAcceptanceTest"
TEST_NAME = "gatewaySafPublicMethodChannelPathProvesTwoPinsNlaRdpdrDrainAndSafReadback"
TARGET_PATCH_SHA256 = "52b61d9ecfef7c8d047ee558177ab2b0b664294729a2035c5045041a183eafb4"
TARGET_SOURCE_MANIFEST_SHA256 = "5a5ed427179aaad89b111c6b9bae9bc594b8c78abf7efb5e10c24ee09dfbf1f0"


class ContractError(RuntimeError):
    pass


def _require(text: str, values: Sequence[str], path: str) -> None:
    missing = [value for value in values if value not in text]
    if missing:
        raise ContractError(f"source_contract_failed:{path}:{len(missing)}")


def _require_count(text: str, value: str, count: int, path: str) -> None:
    if text.count(value) < count:
        raise ContractError(f"source_contract_failed:{path}:count")


def verify_source(root: Path) -> dict[str, object]:
    root = root.resolve(strict=True)
    paths = {relative: root / relative for relative in SOURCE_PATHS}
    if any(not path.is_file() or path.is_symlink() for path in paths.values()):
        raise ContractError("source_contract_failed:paths")
    source = {relative: path.read_text(encoding="utf-8") for relative, path in paths.items()}
    test = source[TEST_PATH]
    runtime_test = source[RUNTIME_TEST_PATH]
    provider = source[PROVIDER_PATH]
    manifest = source[MANIFEST_PATH]

    _require(test, (
        "class RdpPackagedGatewaySafPublicBridgeAcceptanceTest",
        f"fun {TEST_NAME}()",
        "OwnedRegisteredChannelClient(ownedActivity)",
        "awaitWindowFocus(ownedActivity)",
        'MainActivity::class.java.getDeclaredField("rdpNative")',
        'getDeclaredMethod("getFlutterEngine")',
        'getDeclaredField("messenger")', 'getDeclaredField("messageHandlers")',
        'getDeclaredField("handlersLock")', "synchronized(lock)",
        "RdpNativeBridge.METHODS", "RdpNativeBridge.EVENTS",
        "StandardMethodCodec.INSTANCE", ".encodeMethodCall(MethodCall(",
        ".also { it.flip() }",
        "val readable = reply.duplicate()", "readable.flip()",
        'client.call("capabilities", null)',
        'assertEquals(true, security["rdGateway"])',
        'assertEquals(true, channels["files"])',
        "OwnedDescriptor.load(appContext)",
        "RdpOwnedSafDocumentsProvider.reset(",
        '"inspect"',
        'assertEquals("connectionFailed", direct.awaitError(20))',
        'client.call("inspectGateway", gatewayRequest)',
        '"inspectTargetThroughGateway"',
        "Instrumentation.ActivityMonitor(",
        "IntentFilter(Intent.ACTION_OPEN_DOCUMENT_TREE)",
        '"selectFileTransferTree"',
        "assertEquals(1, picker.hits)",
        '"activateFileTransferGrant"', '"prepareFileTransfer"',
        '"open"', '"ackFrame"',
        '"drainFileTransfer"', 'assertState(drained, "sealed")',
        '"saveReceivedFiles"', 'assertState(saved, "saved")',
        "RdpOwnedSafDocumentsProvider.assertProviderReadback",
        '"retireFileTransferGrant"', 'assertState(retired, "retired")',
        "client.cancelEvents(SESSION_REQUEST_ID)",
        "client.disposeProductionBridgeAndProveOwnersReleased()",
        'getDeclaredField("safTransfers")', 'getDeclaredField("processOwner")',
        'getDeclaredMethod("tryAcquire", Any::class.java)',
        'getDeclaredMethod("release", Any::class.java)',
        "onMain { bridge.dispose() }", 'getDeclaredField("disposed")',
        '"Larenor-F62-Gateway-upload:"', '"Larenor-F62-Gateway-outbound:"',
        "assertEquals(91, upload.size)", "assertEquals(93, outbound.size)",
        '"rdp-saf-mirrors-v1/$transferId/root/FromRemote/$outboundName"',
        'put("schemaVersion", 2)', "nativeDrainConfirmed = true", "ownersRetired = true",
    ), TEST_PATH)
    forbidden = (
        "RdpPackagedRuntime(", "RdpNativeAdapter(", "RdpFreeRdpBackend(",
        "RdpProductFeatureBackend(", "OwnedLoopbackBinaryMessenger", "FakeRuntime",
        "acceptanceOverride", "setCompiledCapabilities", "bridge.onActivityResult(",
        "onWindowFocusChanged(true)", "bridge.setResumed(", "bridge.setWindowFocused(",
        "runCatching { client.disposeProductionBridgeAndProveOwnersReleased() }",
        "Thread.sleep(3000)", "println(", "Log.",
    )
    if any(value in test for value in forbidden):
        raise ContractError("source_contract_failed:test_forbidden")
    _require_count(test, ".encodeMethodCall(MethodCall(", 2, TEST_PATH)
    _require_count(test, "StandardMethodCodec.INSTANCE", 3, TEST_PATH)
    _require_count(test, ".also { it.flip() }", 2, TEST_PATH)
    _require(runtime_test, (
        "class RdpPublicBridgeRuntimeContractTest",
        "pinnedFlutterMessengerWrapperResolvesRegisteredHandlerUnderItsActualLock",
        "pinnedStandardMethodCodecRequiresReadableRequestAndReplyBuffers",
        'Class.forName(DART_MESSENGER)', 'Class.forName(DEFAULT_BINARY_MESSENGER)',
        'getDeclaredField("messenger")', 'getDeclaredField("messageHandlers")',
        'getDeclaredField("handlersLock")', "synchronized(lock)",
        "encodedCall.flip()", "codec.decodeMethodCall(encodedCall)",
        "encodedReply.flip()", "codec.decodeEnvelope(encodedReply)",
    ), RUNTIME_TEST_PATH)
    caps = test.index('client.call("capabilities", null)')
    admitted_gateway = test.index('assertEquals(true, security["rdGateway"])')
    admitted_files = test.index('assertEquals(true, channels["files"])')
    descriptor = test.index("OwnedDescriptor.load(appContext)")
    provider_reset = test.index("RdpOwnedSafDocumentsProvider.reset(")
    first_secret = test.index("descriptor.gatewayPassword.utf8()")
    first_picker = test.index('"selectFileTransferTree"')
    if not caps < admitted_gateway < admitted_files < descriptor < provider_reset < first_secret < first_picker:
        raise ContractError("source_contract_failed:admission_order")
    drain = test.index('"drainFileTransfer"')
    sealed = test.index('assertState(drained, "sealed")')
    save = test.index('"saveReceivedFiles"')
    saved = test.index('assertState(saved, "saved")')
    readback = test.index("RdpOwnedSafDocumentsProvider.assertProviderReadback")
    retired = test.index('assertState(retired, "retired")')
    dispose = test.index("client.disposeProductionBridgeAndProveOwnersReleased()")
    witness = test.index("writeOwnedWitness(")
    if not drain < sealed < save < saved < readback < retired < dispose < witness:
        raise ContractError("source_contract_failed:effect_order")

    _require(provider, (
        "class RdpOwnedSafDocumentsProvider : DocumentsProvider()",
        "override fun queryRoots", "override fun openDocument", "override fun createDocument",
        "ParcelFileDescriptor.MODE_READ_WRITE", "assertProviderReadback",
    ), PROVIDER_PATH)
    _require(manifest, (
        "RdpOwnedSafDocumentsProvider", 'android:exported="true"',
        'android:grantUriPermissions="true"',
        'android:permission="android.permission.MANAGE_DOCUMENTS"',
        "android.content.action.DOCUMENTS_PROVIDER",
    ), MANIFEST_PATH)

    return {
        "schemaVersion": 1,
        "clientWitnessSchemaVersion": 2,
        "testClass": TEST_CLASS,
        "testName": TEST_NAME,
        "targetPatchSha256": TARGET_PATCH_SHA256,
        "targetSourceManifestSha256": TARGET_SOURCE_MANIFEST_SHA256,
        "directTargetBlockedRequiresHostJoin": True,
        "expectedPayloadLengths": {"upload": 91, "outbound": 93},
        "sourceSha256": {
            relative: hashlib.sha256(paths[relative].read_bytes()).hexdigest()
            for relative in sorted(paths)
        },
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    command = parser.add_subparsers(dest="command", required=True).add_parser("verify-source")
    command.add_argument("--source", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        receipt = verify_source(args.source)
    except (ContractError, OSError, UnicodeError, ValueError):
        return 2
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
