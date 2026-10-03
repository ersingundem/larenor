#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Sequence


TEST_PATH = (
    "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
    "RdpPackagedGatewaySafAcceptanceTest.kt"
)
PROVIDER_PATH = (
    "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
    "RdpOwnedSafDocumentsProvider.kt"
)
MANIFEST_PATH = "android/app/src/androidTest/AndroidManifest.xml"
SOURCE_PATHS = (TEST_PATH, PROVIDER_PATH, MANIFEST_PATH)

TEST_CLASS = "com.ersingundem.larenor.rdp.RdpPackagedGatewaySafAcceptanceTest"
TEST_NAME = "gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain"


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
    paths = {relative: (root / relative) for relative in SOURCE_PATHS}
    if any(not path.is_file() or path.is_symlink() for path in paths.values()):
        raise ContractError("source_contract_failed:paths")
    source = {relative: path.read_text(encoding="utf-8") for relative, path in paths.items()}
    test = source[TEST_PATH]
    provider = source[PROVIDER_PATH]
    manifest = source[MANIFEST_PATH]

    _require(test, (
        "class RdpPackagedGatewaySafAcceptanceTest",
        f"fun {TEST_NAME}()",
        "RdpPackagedRuntime(ownedActivity)",
        "RdpFreeRdpBackend(runtime)",
        "RdpSafGrantBroker(",
        "RdpSafTransferCoordinator(",
        "inspectGateway",
        "inspectTargetThroughGateway",
        "assertDirectTargetBlocked",
        "assertWrongPinRejected",
        "transfers.drain(",
        'assertState(drain.awaitMap(40), "sealed")',
        'assertState(saved, "saved")',
        "assertProviderReadback",
        '"Larenor-F62-Gateway-upload:"',
        '"Larenor-F62-Gateway-outbound:"',
        '"upload-" + descriptor.nonce.take(16) + ".bin"',
        '"outbound-" + descriptor.nonce.take(16) + ".bin"',
        "assertEquals(91, upload.size)",
        "assertEquals(93, outbound.size)",
        "assertPersistedReadWriteGrant",
        "assertGrantRetired",
        "writeOwnedWitness",
        'put("schemaVersion", 2)',
        "nativeDrainConfirmed = true",
        "ownersRetired = true",
        'File(canonicalRoot, "FromRemote/$name")',
        'requireNotNull(host.requestCode),',
    ), TEST_PATH)
    _require_count(test, "inspectTargetThroughGateway", 2, TEST_PATH)
    _require_count(test, '"Larenor-F62-Gateway-upload:"', 2, TEST_PATH)
    _require_count(test, "assertWrongPinRejected", 2, TEST_PATH)
    forbidden_test = (
        "FakeRuntime", "FakeTransferCoordinator", "RdpProductFeatureBackend(",
        "setCompiledCapabilities", "acceptanceOverride", "Thread.sleep(3000)",
        "println(", "Log.", "gatewayPassword=", "targetPassword=",
    )
    if any(value in test for value in forbidden_test):
        raise ContractError("source_contract_failed:test_forbidden")

    _require(provider, (
        "class RdpOwnedSafDocumentsProvider : DocumentsProvider()",
        "override fun queryRoots",
        "override fun queryDocument",
        "override fun queryChildDocuments",
        "override fun openDocument",
        "override fun createDocument",
        "ParcelFileDescriptor.MODE_READ_WRITE",
        "DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE",
        "DocumentsContract.Document.FLAG_SUPPORTS_WRITE",
        "Os.chmod",
        "assertProviderReadback",
        "File(toRemote, uploadName)",
    ), PROVIDER_PATH)
    if any(value in provider for value in ("../", "Log.", "println(")):
        raise ContractError("source_contract_failed:provider_forbidden")

    _require(manifest, (
        "RdpOwnedSafDocumentsProvider",
        'android:exported="true"',
        'android:grantUriPermissions="true"',
        'android:permission="android.permission.MANAGE_DOCUMENTS"',
        "android.content.action.DOCUMENTS_PROVIDER",
    ), MANIFEST_PATH)

    return {
        "schemaVersion": 1,
        "clientWitnessSchemaVersion": 2,
        "testClass": TEST_CLASS,
        "testName": TEST_NAME,
        "expectedPayloadLengths": {"upload": 91, "outbound": 93},
        "sourceSha256": {
            relative: hashlib.sha256(paths[relative].read_bytes()).hexdigest()
            for relative in sorted(paths)
        },
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    verify = subparsers.add_parser("verify-source")
    verify.add_argument("--source", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        receipt = verify_source(args.source)
    except (ContractError, OSError, UnicodeError):
        return 2
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
