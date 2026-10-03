#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
from typing import Sequence


APP_ID = "com.ersingundem.larenor"
TEST_ID = "com.ersingundem.larenor.test"
RUNNER = "androidx.test.runner.AndroidJUnitRunner"
TARGET_PATCH_SHA256 = "52b61d9ecfef7c8d047ee558177ab2b0b664294729a2035c5045041a183eafb4"
TARGET_SOURCE_MANIFEST_SHA256 = (
    "5a5ed427179aaad89b111c6b9bae9bc594b8c78abf7efb5e10c24ee09dfbf1f0"
)
SCENARIOS = {
    "direct": {
        "contract": "tool/f62_gateway_saf_acceptance_contract.py",
        "test": (
            "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
            "RdpPackagedGatewaySafAcceptanceTest.kt"
        ),
        "testClass": "com.ersingundem.larenor.rdp.RdpPackagedGatewaySafAcceptanceTest",
        "testName": "gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain",
    },
    "public": {
        "contract": "tool/f62_gateway_saf_public_bridge_contract.py",
        "test": (
            "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
            "RdpPackagedGatewaySafPublicBridgeAcceptanceTest.kt"
        ),
        "testClass": "com.ersingundem.larenor.rdp.RdpPackagedGatewaySafPublicBridgeAcceptanceTest",
        "testName": (
            "gatewaySafPublicMethodChannelPathProvesTwoPinsNlaRdpdrDrainAndSafReadback"
        ),
    },
}
BUILD_RECEIPT_KEYS = {
    "schemaVersion", "appApkSha256", "testApkSha256",
    "productNativeReceiptSha256", "sourceManifestSha256", "testSourceSha256",
    "productVerifierSha256", "applicationId", "testApplicationId",
    "instrumentationRunner",
}
PUBLIC_FACTS = {
    "gatewayPinMatched", "targetPinMatched", "gatewayAuthObserved",
    "configuredTargetExact", "directTargetBlocked", "targetConnectedThroughGateway",
    "frameAcknowledged", "safUploadMatched", "safDownloadCommitted",
    "sessionDrained", "ownersRetired",
}
PUBLIC_KEYS = {
    "schemaVersion", "sourceRevision", "archiveSha256", "goVersion",
    "goSumSha256", "gatewayBinarySha256", "authBinarySha256", "testClass",
    "testName", "tests", "failures", "errors", "skipped", *PUBLIC_FACTS,
    "featureAccepted", "scope",
}
CHECKOUT = re.compile(r"[0-9a-f]{40}")
PUBLIC_PRODUCT_SOURCE_PATHS = frozenset({
    "android/freerdp-native.lock.json",
    "android/app/src/main/kotlin/com/ersingundem/larenor/MainActivity.kt",
    "android/app/src/main/kotlin/com/ersingundem/larenor/rdp/RdpFreeRdpEngine.kt",
    "android/app/src/main/kotlin/com/ersingundem/larenor/rdp/RdpNativeBridge.kt",
    "android/app/src/main/kotlin/com/ersingundem/larenor/rdp/RdpNativeContract.kt",
    "android/app/src/main/kotlin/com/ersingundem/larenor/rdp/RdpProductFeatureBackend.kt",
    "android/app/src/freerdp/kotlin/com/ersingundem/larenor/rdp/packaged/RdpPackagedRuntime.kt",
})
JOINED_BINDING_KEYS = {
    "checkoutRevision", "checkoutTree", "effectReceiptSha256",
    "launcherReceiptSha256", "androidBuildReceiptSha256",
    "appApkSha256", "testApkSha256", "productNativeReceiptSha256",
    "sourceManifestSha256", "productVerifierSha256", "testSourceSha256",
    "targetPatchSha256", "targetSourceManifestSha256",
}
JOINED_KEYS = (PUBLIC_KEYS - {"schemaVersion"}) | {"schemaVersion"} | JOINED_BINDING_KEYS
HEX64 = re.compile(r"[0-9a-f]{64}")
HEX40 = re.compile(r"[0-9a-f]{40}")
RDGW_REVISION = "16cdaaf4dce6a6567ce9b612f14e71d0ca704148"
RDGW_ARCHIVE_SHA256 = "b96e24cddfdf4b6eee939dc1558734f29534c7e0ebae650858c8ba715a166907"


class HostedError(RuntimeError):
    pass


def fail(code: str) -> None:
    raise HostedError(code)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def regular(path: Path, *, private: bool = False, executable: bool = False) -> None:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail("unsafeInput")
    if private and (info.st_uid != os.getuid() or info.st_mode & 0o077):
        fail("unsafePrivateInput")
    if not private and info.st_mode & 0o022:
        fail("unsafeInput")
    if executable and not info.st_mode & stat.S_IXUSR:
        fail("unsafeExecutable")


def private_directory(path: Path) -> None:
    info = path.lstat()
    if (stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.getuid() or info.st_mode & 0o077):
        fail("unsafePrivateDirectory")


def write_json(path: Path, value: dict) -> None:
    if path.exists() or path.is_symlink():
        fail("outputExists")
    raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
    descriptor = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600
    )
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


def read_json(path: Path, limit: int, code: str) -> dict:
    regular(path, private=True)
    raw = path.read_bytes()
    if not 0 < len(raw) <= limit:
        fail(code)
    try:
        value = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError):
        fail(code)
    if not isinstance(value, dict):
        fail(code)
    return value


def under(root: Path, relative: str) -> Path:
    if relative.startswith("/") or ".." in Path(relative).parts:
        fail("invalidSourcePath")
    candidate = root / relative
    resolved = candidate.resolve(strict=True)
    try:
        resolved.relative_to(root)
    except ValueError:
        fail("invalidSourcePath")
    regular(resolved)
    return resolved


def source_hashes(root: Path, claimed: object, additions: set[str]) -> dict[str, str]:
    if not isinstance(claimed, dict) or not 1 <= len(claimed) <= 32:
        fail("sourceContractFailed")
    validated: dict[str, str] = {}
    for relative, expected in claimed.items():
        if (not isinstance(relative, str) or not 1 <= len(relative) <= 240
                or not isinstance(expected, str) or HEX64.fullmatch(expected) is None):
            fail("sourceContractFailed")
        actual = sha256(under(root, relative))
        if actual != expected:
            fail("sourceContractFailed")
        validated[relative] = actual
    for relative in additions:
        if not isinstance(relative, str) or not 1 <= len(relative) <= 240:
            fail("invalidSourcePath")
        validated[relative] = sha256(under(root, relative))
    if not 1 <= len(validated) <= 40:
        fail("sourceContractFailed")
    return dict(sorted(validated.items()))


def run_contract(python: Path, contract: Path, source: Path) -> dict:
    result = subprocess.run(
        [str(python), "-B", str(contract), "verify-source", "--source", str(source)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=20,
    )
    if result.returncode != 0 or not 0 < len(result.stdout) <= 32768:
        fail("sourceContractFailed")
    try:
        value = json.loads(result.stdout)
    except (UnicodeError, json.JSONDecodeError):
        fail("sourceContractFailed")
    if not isinstance(value, dict):
        fail("sourceContractFailed")
    return value


def git_object(git: Path, source: Path, revision: str) -> str:
    try:
        result = subprocess.run(
            [str(git), "-C", str(source), "rev-parse", "--verify", revision],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            check=False, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        fail("checkoutIdentityUnavailable")
    try:
        value = result.stdout.decode("ascii", "strict").strip()
    except UnicodeError:
        fail("checkoutIdentityUnavailable")
    if result.returncode != 0 or len(result.stdout) > 128 or CHECKOUT.fullmatch(value) is None:
        fail("checkoutIdentityUnavailable")
    return value


def prepare(args: argparse.Namespace) -> None:
    scenario = SCENARIOS[args.scenario]
    source = args.source.resolve(strict=True)
    output = args.output.resolve(strict=True)
    private_directory(output)
    python = args.python.resolve(strict=True)
    adb = args.adb.resolve(strict=True)
    git = args.git.resolve(strict=True)
    regular(python, executable=True)
    regular(adb, executable=True)
    regular(git, executable=True)
    checkout_revision = git_object(git, source, "HEAD")
    checkout_tree = git_object(git, source, "HEAD^{tree}")
    contract_path = under(source, scenario["contract"])
    contract = run_contract(python, contract_path, source)
    if (contract.get("testClass") != scenario["testClass"]
            or contract.get("testName") != scenario["testName"]
            or not isinstance(contract.get("sourceSha256"), dict)):
        fail("sourceContractFailed")
    additions = {
        scenario["contract"],
        "tool/f62_gateway_saf_android_client.py",
        "tool/f62_rdpgw_owned_fixture.py",
        "tool/f62_gateway_android_hosted.py",
    }
    if args.scenario == "public":
        additions.update(PUBLIC_PRODUCT_SOURCE_PATHS)
    if scenario["test"] not in contract["sourceSha256"]:
        fail("sourceContractFailed")
    files = source_hashes(source, contract["sourceSha256"], additions)
    compile_log = args.compile_log.resolve(strict=True)
    regular(compile_log, private=True)
    if not 0 < compile_log.stat().st_size <= 16 * 1024 * 1024:
        fail("invalidCompileLog")
    source_manifest = {
        "schemaVersion": 1,
        "targetPatchSha256": TARGET_PATCH_SHA256,
        "targetSourceManifestSha256": TARGET_SOURCE_MANIFEST_SHA256,
        "compileLogSha256": sha256(compile_log),
        "files": files,
    }
    source_manifest_path = output / "source-manifest.json"
    write_json(source_manifest_path, source_manifest)

    inputs = (
        args.app_apk.resolve(strict=True), args.test_apk.resolve(strict=True),
        args.product_receipt.resolve(strict=True), args.product_verifier.resolve(strict=True),
        args.fixture_source.resolve(strict=True),
    )
    for path in inputs:
        regular(path)
    app_apk, test_apk, product_receipt, product_verifier, fixture_source = inputs
    test_digest = files[scenario["test"]]
    build_receipt = {
        "schemaVersion": 1,
        "appApkSha256": sha256(app_apk),
        "testApkSha256": sha256(test_apk),
        "productNativeReceiptSha256": sha256(product_receipt),
        "sourceManifestSha256": sha256(source_manifest_path),
        "testSourceSha256": test_digest,
        "productVerifierSha256": sha256(product_verifier),
        "applicationId": APP_ID,
        "testApplicationId": TEST_ID,
        "instrumentationRunner": RUNNER,
    }
    if set(build_receipt) != BUILD_RECEIPT_KEYS:
        fail("invalidBuildReceipt")
    build_receipt_path = output / "android-build-receipt.json"
    write_json(build_receipt_path, build_receipt)

    product_dir = args.product_native_dir.resolve(strict=True)
    private_directory(product_dir)
    private_log = args.private_log.resolve()
    if private_log.exists() or private_log.is_symlink() or private_log.parent != output:
        fail("invalidPrivateLog")
    client = under(source, "tool/f62_gateway_saf_android_client.py")
    argv = [
        str(python), "-B", str(client), "--scenario", args.scenario,
        "--adb", str(adb), "--python", str(python),
        "--product-verifier", str(product_verifier),
        "--product-native-dir", str(product_dir),
        "--product-receipt", str(product_receipt),
        "--app-apk", str(app_apk), "--test-apk", str(test_apk),
        "--android-build-receipt", str(build_receipt_path),
        "--source-root", str(source), "--source-manifest", str(source_manifest_path),
        "--fixture-source", str(fixture_source),
        "--private-log", str(private_log), "--timeout", "900",
    ]
    if len(argv) > 64 or any(not item or len(item) > 4096 or "\x00" in item for item in argv):
        fail("invalidClientCommand")
    client_command_path = output / "client-command.json"
    write_json(client_command_path, {"argv": argv})
    write_json(
        output / "launcher-receipt.json",
        {
            "schemaVersion": 1,
            "scenario": args.scenario,
            "testClass": scenario["testClass"],
            "testName": scenario["testName"],
            "sourceManifestSha256": sha256(source_manifest_path),
            "androidBuildReceiptSha256": sha256(build_receipt_path),
            "clientCommandSha256": sha256(client_command_path),
            "checkoutRevision": checkout_revision,
            "checkoutTree": checkout_tree,
            "featureAccepted": False,
        },
    )


def validate_receipt_value(value: dict, scenario_name: str) -> None:
    scenario = SCENARIOS[scenario_name]
    if (set(value) != PUBLIC_KEYS or type(value.get("schemaVersion")) is not int
            or value.get("schemaVersion") != 2
            or value.get("testClass") != scenario["testClass"]
            or value.get("testName") != scenario["testName"]
            or (value.get("tests"), value.get("failures"), value.get("errors"),
                value.get("skipped")) != (1, 0, 0, 0)
            or any(type(value.get(key)) is not int for key in (
                "tests", "failures", "errors", "skipped",
            ))
            or any(value.get(key) is not True for key in PUBLIC_FACTS)
            or value.get("featureAccepted") is not False
            or value.get("scope") != "ownedRdGatewaySafPrepared"):
        fail("invalidPublicReceipt")
    if (not isinstance(value.get("sourceRevision"), str)
            or HEX40.fullmatch(value["sourceRevision"]) is None
            or value["sourceRevision"] != RDGW_REVISION
            or value.get("archiveSha256") != RDGW_ARCHIVE_SHA256):
        fail("invalidPublicReceipt")
    for key in ("archiveSha256", "goSumSha256",
                "gatewayBinarySha256", "authBinarySha256"):
        if not isinstance(value.get(key), str) or HEX64.fullmatch(value[key]) is None:
            fail("invalidPublicReceipt")
    if value.get("goVersion") != "go1.25.0":
        fail("invalidPublicReceipt")


def validate_receipt(args: argparse.Namespace) -> None:
    value = read_json(args.receipt.resolve(strict=True), 8192, "invalidPublicReceipt")
    validate_receipt_value(value, args.scenario)


def _validated_join_inputs(args: argparse.Namespace) -> tuple[dict, dict, dict, dict]:
    effect_path = args.effect_receipt.resolve(strict=True)
    launcher_path = args.launcher_receipt.resolve(strict=True)
    build_path = args.android_build_receipt.resolve(strict=True)
    manifest_path = args.source_manifest.resolve(strict=True)
    effect = read_json(effect_path, 8192, "invalidPublicReceipt")
    validate_receipt_value(effect, args.scenario)
    launcher = read_json(launcher_path, 4096, "invalidLauncherReceipt")
    build = read_json(build_path, 4096, "invalidAndroidBuildReceipt")
    manifest = read_json(manifest_path, 32768, "invalidSourceManifest")
    scenario = SCENARIOS[args.scenario]
    if (set(launcher) != {
            "schemaVersion", "scenario", "testClass", "testName",
            "sourceManifestSha256", "androidBuildReceiptSha256",
            "clientCommandSha256", "checkoutRevision", "checkoutTree",
            "featureAccepted",
        }
            or type(launcher.get("schemaVersion")) is not int
            or launcher.get("schemaVersion") != 1
            or launcher.get("scenario") != args.scenario
            or launcher.get("testClass") != scenario["testClass"]
            or launcher.get("testName") != scenario["testName"]
            or launcher.get("featureAccepted") is not False
            or CHECKOUT.fullmatch(str(launcher.get("checkoutRevision"))) is None
            or CHECKOUT.fullmatch(str(launcher.get("checkoutTree"))) is None
            or HEX64.fullmatch(str(launcher.get("clientCommandSha256"))) is None
            or launcher.get("sourceManifestSha256") != sha256(manifest_path)
            or launcher.get("androidBuildReceiptSha256") != sha256(build_path)):
        fail("invalidLauncherReceipt")
    if (set(build) != BUILD_RECEIPT_KEYS
            or type(build.get("schemaVersion")) is not int
            or build.get("schemaVersion") != 1
            or any(HEX64.fullmatch(str(build.get(key))) is None for key in (
                "appApkSha256", "testApkSha256", "productNativeReceiptSha256",
                "sourceManifestSha256", "testSourceSha256", "productVerifierSha256",
            ))
            or build.get("sourceManifestSha256") != sha256(manifest_path)
            or build.get("applicationId") != APP_ID
            or build.get("testApplicationId") != TEST_ID
            or build.get("instrumentationRunner") != RUNNER):
        fail("invalidAndroidBuildReceipt")
    if (set(manifest) != {
            "schemaVersion", "targetPatchSha256", "targetSourceManifestSha256",
            "compileLogSha256", "files",
        }
            or type(manifest.get("schemaVersion")) is not int
            or manifest.get("schemaVersion") != 1
            or manifest.get("targetPatchSha256") != TARGET_PATCH_SHA256
            or manifest.get("targetSourceManifestSha256") != TARGET_SOURCE_MANIFEST_SHA256
            or HEX64.fullmatch(str(manifest.get("compileLogSha256"))) is None
            or not isinstance(manifest.get("files"), dict)
            or manifest["files"].get(scenario["test"]) != build["testSourceSha256"]
            or (args.scenario == "public"
                and not PUBLIC_PRODUCT_SOURCE_PATHS <= manifest["files"].keys())):
        fail("invalidSourceManifest")
    for relative, digest in manifest["files"].items():
        if (not isinstance(relative, str) or relative.startswith("/")
                or ".." in Path(relative).parts
                or not isinstance(digest, str) or HEX64.fullmatch(digest) is None):
            fail("invalidSourceManifest")
    return effect, launcher, build, manifest


def join_receipt(args: argparse.Namespace) -> None:
    effect, launcher, build, manifest = _validated_join_inputs(args)
    joined = dict(effect)
    joined.update({
        "schemaVersion": 3,
        "checkoutRevision": launcher["checkoutRevision"],
        "checkoutTree": launcher["checkoutTree"],
        "effectReceiptSha256": sha256(args.effect_receipt.resolve(strict=True)),
        "launcherReceiptSha256": sha256(args.launcher_receipt.resolve(strict=True)),
        "androidBuildReceiptSha256": sha256(args.android_build_receipt.resolve(strict=True)),
        "appApkSha256": build["appApkSha256"],
        "testApkSha256": build["testApkSha256"],
        "productNativeReceiptSha256": build["productNativeReceiptSha256"],
        "sourceManifestSha256": build["sourceManifestSha256"],
        "productVerifierSha256": build["productVerifierSha256"],
        "testSourceSha256": build["testSourceSha256"],
        "targetPatchSha256": manifest["targetPatchSha256"],
        "targetSourceManifestSha256": manifest["targetSourceManifestSha256"],
    })
    validate_joined_receipt_value(joined, args.scenario)
    output = args.output.resolve()
    private_directory(output.parent)
    write_json(output, joined)


def validate_joined_receipt_value(value: dict, scenario_name: str) -> None:
    if (set(value) != JOINED_KEYS or type(value.get("schemaVersion")) is not int
            or value.get("schemaVersion") != 3):
        fail("invalidJoinedReceipt")
    effect = {key: value[key] for key in PUBLIC_KEYS}
    effect["schemaVersion"] = 2
    validate_receipt_value(effect, scenario_name)
    if (CHECKOUT.fullmatch(str(value.get("checkoutRevision"))) is None
            or CHECKOUT.fullmatch(str(value.get("checkoutTree"))) is None
            or any(HEX64.fullmatch(str(value.get(key))) is None
                   for key in JOINED_BINDING_KEYS - {"checkoutRevision", "checkoutTree"})
            or value.get("targetPatchSha256") != TARGET_PATCH_SHA256
            or value.get("targetSourceManifestSha256") != TARGET_SOURCE_MANIFEST_SHA256):
        fail("invalidJoinedReceipt")


def validate_joined_receipt(args: argparse.Namespace) -> None:
    value = read_json(args.receipt.resolve(strict=True), 16384, "invalidJoinedReceipt")
    validate_joined_receipt_value(value, args.scenario)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    make = commands.add_parser("prepare")
    make.add_argument("--scenario", choices=tuple(SCENARIOS), default="direct")
    make.add_argument("--source", type=Path, required=True)
    make.add_argument("--output", type=Path, required=True)
    make.add_argument("--python", type=Path, required=True)
    make.add_argument("--adb", type=Path, required=True)
    make.add_argument("--git", type=Path, required=True)
    make.add_argument("--compile-log", type=Path, required=True)
    make.add_argument("--app-apk", type=Path, required=True)
    make.add_argument("--test-apk", type=Path, required=True)
    make.add_argument("--product-native-dir", type=Path, required=True)
    make.add_argument("--product-receipt", type=Path, required=True)
    make.add_argument("--product-verifier", type=Path, required=True)
    make.add_argument("--fixture-source", type=Path, required=True)
    make.add_argument("--private-log", type=Path, required=True)
    check = commands.add_parser("validate-receipt")
    check.add_argument("--scenario", choices=tuple(SCENARIOS), default="direct")
    check.add_argument("--receipt", type=Path, required=True)
    join = commands.add_parser("join-receipt")
    join.add_argument("--scenario", choices=tuple(SCENARIOS), required=True)
    join.add_argument("--effect-receipt", type=Path, required=True)
    join.add_argument("--launcher-receipt", type=Path, required=True)
    join.add_argument("--android-build-receipt", type=Path, required=True)
    join.add_argument("--source-manifest", type=Path, required=True)
    join.add_argument("--output", type=Path, required=True)
    joined = commands.add_parser("validate-joined-receipt")
    joined.add_argument("--scenario", choices=tuple(SCENARIOS), required=True)
    joined.add_argument("--receipt", type=Path, required=True)
    return root


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "prepare":
            prepare(args)
        elif args.command == "validate-receipt":
            validate_receipt(args)
        elif args.command == "join-receipt":
            join_receipt(args)
        else:
            validate_joined_receipt(args)
        return 0
    except (HostedError, OSError, ValueError, subprocess.SubprocessError):
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
