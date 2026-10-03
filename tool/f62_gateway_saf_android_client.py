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
TEST_CLASS = "com.ersingundem.larenor.rdp.RdpPackagedGatewaySafAcceptanceTest"
TEST_NAME = "gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain"
TARGET_PATCH_SHA256 = "52b61d9ecfef7c8d047ee558177ab2b0b664294729a2035c5045041a183eafb4"
TARGET_MANIFEST_SHA256 = "5a5ed427179aaad89b111c6b9bae9bc594b8c78abf7efb5e10c24ee09dfbf1f0"
TEST_PATH = (
    "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
    "RdpPackagedGatewaySafAcceptanceTest.kt"
)
PUBLIC_TEST_CLASS = "com.ersingundem.larenor.rdp.RdpPackagedGatewaySafPublicBridgeAcceptanceTest"
PUBLIC_TEST_NAME = "gatewaySafPublicMethodChannelPathProvesTwoPinsNlaRdpdrDrainAndSafReadback"
PUBLIC_TEST_PATH = (
    "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
    "RdpPackagedGatewaySafPublicBridgeAcceptanceTest.kt"
)
_COMMON_SOURCE_PATHS = frozenset({
    "android/app/src/androidTest/AndroidManifest.xml",
    "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/"
    "RdpOwnedSafDocumentsProvider.kt",
})
_PUBLIC_PRODUCT_SOURCE_PATHS = frozenset({
    "android/freerdp-native.lock.json",
    "android/app/src/main/kotlin/com/ersingundem/larenor/MainActivity.kt",
    "android/app/src/main/kotlin/com/ersingundem/larenor/rdp/RdpFreeRdpEngine.kt",
    "android/app/src/main/kotlin/com/ersingundem/larenor/rdp/RdpNativeBridge.kt",
    "android/app/src/main/kotlin/com/ersingundem/larenor/rdp/RdpNativeContract.kt",
    "android/app/src/main/kotlin/com/ersingundem/larenor/rdp/RdpProductFeatureBackend.kt",
    "android/app/src/freerdp/kotlin/com/ersingundem/larenor/rdp/packaged/RdpPackagedRuntime.kt",
})
HEX64 = re.compile(r"[0-9a-f]{64}")
PIN = re.compile(r"SHA256:[A-Za-z0-9+/]{43}")
GENERIC_KEYS = {
    "schemaVersion", "nonce", "testClass", "testName", "gatewayHost",
    "gatewayPort", "gatewayUsername", "gatewayPassword", "gatewayDomain",
    "gatewayPin", "targetHost", "targetPort", "targetUsername", "targetDomain",
    "targetPassword", "targetPin", "expectedUploadSha256",
    "expectedOutboundSha256", "witnessPath",
}
DEVICE_KEYS = {
    "schemaVersion", "nonce", "sourceSha256", "testSha256",
    "fixtureSourceSha256", "targetPatchSha256", "targetSourceManifestSha256",
    "gatewayHost", "gatewayPort", "gatewayUsername", "gatewayPassword",
    "gatewayDomain", "gatewayPin", "targetHost", "targetPort",
    "targetUsername", "targetDomain", "targetPassword", "targetPin",
    "expectedUploadSha256", "expectedOutboundSha256",
}
BUILD_RECEIPT_KEYS = {
    "schemaVersion", "appApkSha256", "testApkSha256",
    "productNativeReceiptSha256", "sourceManifestSha256", "testSourceSha256",
    "productVerifierSha256",
    "applicationId", "testApplicationId", "instrumentationRunner",
}


class AdapterError(RuntimeError):
    pass


def fail(code: str) -> None:
    raise AdapterError(code)


def scenario_spec(scenario: str) -> tuple[str, str, str, frozenset[str]]:
    if scenario == "direct":
        return TEST_CLASS, TEST_NAME, TEST_PATH, _COMMON_SOURCE_PATHS | {
            TEST_PATH, "tool/f62_gateway_saf_acceptance_contract.py",
        }
    if scenario == "public":
        return PUBLIC_TEST_CLASS, PUBLIC_TEST_NAME, PUBLIC_TEST_PATH, (
            _COMMON_SOURCE_PATHS | _PUBLIC_PRODUCT_SOURCE_PATHS | {
            PUBLIC_TEST_PATH, "tool/f62_gateway_saf_public_bridge_contract.py",
            "android/app/src/freerdpTest/kotlin/com/ersingundem/larenor/rdp/"
            "RdpPublicBridgeRuntimeContractTest.kt",
            }
        )
    fail("invalidScenario")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def private_regular(path: Path, *, executable: bool = False) -> None:
    info = path.lstat()
    if (stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid() or info.st_mode & 0o077):
        fail("unsafePrivateInput")
    if executable and not info.st_mode & stat.S_IXUSR:
        fail("unsafePrivateInput")


def trusted_regular(path: Path, *, executable: bool = False) -> None:
    info = path.lstat()
    if (stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode)
            or info.st_uid not in (0, os.getuid()) or info.st_mode & 0o022):
        fail("unsafeTrustedInput")
    if executable and not info.st_mode & stat.S_IXUSR:
        fail("unsafeTrustedInput")


def read_json(path: Path, limit: int, code: str) -> dict:
    private_regular(path)
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


def _closed_text(value: object, *, maximum: int = 256) -> bool:
    return isinstance(value, str) and 0 < len(value) <= maximum and "\x00" not in value


def validate_generic_descriptor(path: Path, *, scenario: str = "direct") -> dict:
    test_class, test_name, _, _ = scenario_spec(scenario)
    value = read_json(path, 4096, "invalidFixtureDescriptor")
    if (set(value) != GENERIC_KEYS or value.get("schemaVersion") != 2
            or value.get("testClass") != test_class or value.get("testName") != test_name
            or type(value.get("gatewayPort")) is not int
            or type(value.get("targetPort")) is not int
            or value["gatewayPort"] not in range(1, 65536)
            or value["targetPort"] not in range(1, 65536)):
        fail("invalidFixtureDescriptor")
    for key in ("nonce", "expectedUploadSha256", "expectedOutboundSha256"):
        if not isinstance(value.get(key), str) or HEX64.fullmatch(value[key]) is None:
            fail("invalidFixtureDescriptor")
    for key in ("gatewayPin", "targetPin"):
        if not isinstance(value.get(key), str) or PIN.fullmatch(value[key]) is None:
            fail("invalidFixtureDescriptor")
    for key in (
        "gatewayHost", "gatewayUsername", "gatewayPassword", "gatewayDomain",
        "targetHost", "targetUsername", "targetDomain", "targetPassword",
    ):
        if not _closed_text(value.get(key)):
            fail("invalidFixtureDescriptor")
    witness = Path(value["witnessPath"])
    if (not witness.is_absolute() or witness.parent != path.parent
            or witness.name != "private-witness.json"
            or witness.exists() or witness.is_symlink()):
        fail("invalidFixtureDescriptor")
    return value


def validate_source_manifest(
    path: Path, source_root: Path, *, scenario: str = "direct",
) -> tuple[str, str]:
    _, _, test_path, required_paths = scenario_spec(scenario)
    manifest = read_json(path, 32768, "invalidSourceManifest")
    if set(manifest) != {
        "schemaVersion", "targetPatchSha256", "targetSourceManifestSha256",
        "compileLogSha256", "files",
    } or manifest.get("schemaVersion") != 1:
        fail("invalidSourceManifest")
    if (manifest.get("targetPatchSha256") != TARGET_PATCH_SHA256
            or manifest.get("targetSourceManifestSha256") != TARGET_MANIFEST_SHA256
            or not isinstance(manifest.get("files"), dict)
            or not required_paths <= manifest["files"].keys()
            or not 1 <= len(manifest["files"]) <= 64
            or not isinstance(manifest.get("compileLogSha256"), str)
            or HEX64.fullmatch(manifest["compileLogSha256"]) is None):
        fail("invalidSourceManifest")
    for relative, expected in manifest["files"].items():
        if (not isinstance(relative, str) or relative.startswith("/") or ".." in Path(relative).parts
                or not isinstance(expected, str) or HEX64.fullmatch(expected) is None):
            fail("invalidSourceManifest")
        candidate = source_root / relative
        trusted_regular(candidate)
        if sha256(candidate) != expected:
            fail("sourceBindingMismatch")
    expected_test = manifest["files"].get(test_path)
    if expected_test is None:
        fail("invalidSourceManifest")
    return sha256(path), expected_test


def validate_build_receipt(
    path: Path,
    *,
    app_apk: Path,
    test_apk: Path,
    product_receipt: Path,
    source_manifest_sha256: str,
    test_source_sha256: str,
    product_verifier: Path,
) -> dict:
    value = read_json(path, 4096, "invalidAndroidBuildReceipt")
    expected = {
        "schemaVersion": 1,
        "appApkSha256": sha256(app_apk),
        "testApkSha256": sha256(test_apk),
        "productNativeReceiptSha256": sha256(product_receipt),
        "sourceManifestSha256": source_manifest_sha256,
        "testSourceSha256": test_source_sha256,
        "productVerifierSha256": sha256(product_verifier),
        "applicationId": APP_ID,
        "testApplicationId": TEST_ID,
        "instrumentationRunner": RUNNER,
    }
    if set(value) != BUILD_RECEIPT_KEYS or value != expected:
        fail("invalidAndroidBuildReceipt")
    return value


def make_device_descriptor(
    fixture: dict,
    *,
    source_sha256: str,
    test_sha256: str,
    fixture_source_sha256: str,
) -> bytes:
    value = {
        "schemaVersion": 1,
        "nonce": fixture["nonce"],
        "sourceSha256": source_sha256,
        "testSha256": test_sha256,
        "fixtureSourceSha256": fixture_source_sha256,
        "targetPatchSha256": TARGET_PATCH_SHA256,
        "targetSourceManifestSha256": TARGET_MANIFEST_SHA256,
        "gatewayHost": fixture["gatewayHost"],
        "gatewayPort": fixture["gatewayPort"],
        "gatewayUsername": fixture["gatewayUsername"],
        "gatewayPassword": fixture["gatewayPassword"],
        "gatewayDomain": fixture["gatewayDomain"],
        "gatewayPin": fixture["gatewayPin"],
        "targetHost": fixture["targetHost"],
        "targetPort": fixture["targetPort"],
        "targetUsername": fixture["targetUsername"],
        "targetDomain": fixture["targetDomain"],
        "targetPassword": fixture["targetPassword"],
        "targetPin": fixture["targetPin"],
        "expectedUploadSha256": fixture["expectedUploadSha256"],
        "expectedOutboundSha256": fixture["expectedOutboundSha256"],
    }
    if set(value) != DEVICE_KEYS:
        fail("invalidDeviceDescriptor")
    raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if not 0 < len(raw) <= 4096:
        fail("invalidDeviceDescriptor")
    return raw


def parse_instrumentation(raw: bytes, *, scenario: str = "direct") -> None:
    test_class, test_name, _, _ = scenario_spec(scenario)
    if not 0 < len(raw) <= 262144:
        fail("invalidInstrumentationResult")
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeError:
        fail("invalidInstrumentationResult")
    codes = re.findall(r"(?m)^INSTRUMENTATION_STATUS_CODE: (-?[0-9]+)$", text)
    classes = re.findall(r"(?m)^INSTRUMENTATION_STATUS: class=([^\r\n]+)$", text)
    tests = re.findall(r"(?m)^INSTRUMENTATION_STATUS: test=([^\r\n]+)$", text)
    totals = re.findall(r"(?m)^INSTRUMENTATION_STATUS: numtests=([^\r\n]+)$", text)
    if (codes != ["1", "0"] or classes != [test_class, test_class]
            or tests != [test_name, test_name] or totals != ["1", "1"]
            or text.count("INSTRUMENTATION_CODE: -1") != 1):
        fail("invalidInstrumentationResult")
    if "FAILURES!!!" in text or "INSTRUMENTATION_FAILED" in text:
        fail("instrumentationFailed")


def _adb_prefix(adb: Path) -> list[str]:
    serial = os.environ.get("ANDROID_SERIAL")
    if serial is None:
        return [str(adb)]
    if re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", serial) is None:
        fail("invalidAndroidSerial")
    return [str(adb), "-s", serial]


def _run(
    argv: Sequence[str], *, timeout: float, input_bytes: bytes | None = None,
    output_limit: int = 262144, merge_stderr: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            list(argv), input=input_bytes, stdin=None if input_bytes is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT if merge_stderr else subprocess.DEVNULL,
            check=False, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        fail("androidCommandUnavailable")
    if len(result.stdout) > output_limit:
        fail("androidCommandOutputTooLarge")
    return result


def _device_name(kind: str, nonce: str) -> str:
    return f"files/f62-owned-gateway-saf-{kind}-{nonce}.json" if kind == "witness" else f"files/f62-owned-gateway-saf-{nonce}.json"


def run_client(args: argparse.Namespace) -> None:
    os.umask(0o077)
    test_class, test_name, _, _ = scenario_spec(args.scenario)
    descriptor_path = Path(os.environ.get("LARENOR_F62_RDGW_DESCRIPTOR", ""))
    if not descriptor_path.is_absolute():
        fail("fixtureDescriptorUnavailable")
    fixture = validate_generic_descriptor(descriptor_path, scenario=args.scenario)
    source_root = Path(args.source_root).resolve(strict=True)
    source_manifest = Path(args.source_manifest).resolve(strict=True)
    source_digest, test_digest = validate_source_manifest(
        source_manifest, source_root, scenario=args.scenario,
    )
    fixture_source = Path(args.fixture_source).resolve(strict=True)
    trusted_regular(fixture_source)
    fixture_digest = sha256(fixture_source)
    app_apk = Path(args.app_apk).resolve(strict=True)
    test_apk = Path(args.test_apk).resolve(strict=True)
    product_receipt = Path(args.product_receipt).resolve(strict=True)
    for item in (app_apk, test_apk, product_receipt):
        trusted_regular(item)
    verifier = Path(args.product_verifier).resolve(strict=True)
    trusted_regular(verifier)
    validate_build_receipt(
        Path(args.android_build_receipt).resolve(strict=True), app_apk=app_apk,
        test_apk=test_apk, product_receipt=product_receipt,
        source_manifest_sha256=source_digest, test_source_sha256=test_digest,
        product_verifier=verifier,
    )
    python = Path(args.python).resolve(strict=True)
    adb = Path(args.adb).resolve(strict=True)
    for executable in (python, adb):
        trusted_regular(executable, executable=True)
    verify = _run(
        [str(python), str(verifier), "verify-apk", str(app_apk),
         "--destination", str(Path(args.product_native_dir).resolve(strict=True))],
        timeout=60,
    )
    if verify.returncode != 0:
        fail("productPackageVerificationFailed")
    prefix = _adb_prefix(adb)
    for apk in (app_apk, test_apk):
        installed = _run([*prefix, "install", "-r", "-t", str(apk)], timeout=120)
        if installed.returncode != 0:
            fail("androidInstallFailed")
    nonce = fixture["nonce"]
    device_descriptor = _device_name("descriptor", nonce)
    device_witness = _device_name("witness", nonce)
    descriptor = bytearray(make_device_descriptor(
        fixture, source_sha256=source_digest, test_sha256=test_digest,
        fixture_source_sha256=fixture_digest,
    ))
    private_log = Path(args.private_log)
    if private_log.exists() or private_log.is_symlink():
        fail("privateLogExists")
    private_log.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    parent_info = private_log.parent.lstat()
    if (stat.S_ISLNK(parent_info.st_mode) or not stat.S_ISDIR(parent_info.st_mode)
            or parent_info.st_uid != os.getuid() or parent_info.st_mode & 0o077):
        fail("unsafePrivateLogDirectory")
    primary: BaseException | None = None
    cleanup_ok = False
    try:
        write = _run(
            [*prefix, "exec-in", "run-as", APP_ID, "sh", "-c",
             f"umask 077; set -C; cat > {device_descriptor} && chmod 600 {device_descriptor}"],
            timeout=10, input_bytes=bytes(descriptor), output_limit=4096,
        )
        if write.returncode != 0:
            fail("deviceDescriptorWriteFailed")
        instrument = _run(
            [*prefix, "shell", "am", "instrument", "-w", "-r",
             "-e", "class", f"{test_class}#{test_name}",
             "-e", "rdpGatewaySafNonce", nonce,
             "-e", "rdpGatewaySafSourceSha256", source_digest,
             "-e", "rdpGatewaySafTestSha256", test_digest,
             f"{TEST_ID}/{RUNNER}"],
            timeout=args.timeout,
        )
        fd = os.open(private_log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(instrument.stdout)
            stream.flush()
            os.fsync(stream.fileno())
        if instrument.returncode != 0:
            fail("instrumentationFailed")
        parse_instrumentation(instrument.stdout, scenario=args.scenario)
        readback = _run(
            [*prefix, "exec-out", "run-as", APP_ID, "dd", f"if={device_witness}",
             "bs=2049", "count=1"], timeout=10, output_limit=2049,
            merge_stderr=False,
        )
        if readback.returncode != 0 or not readback.stdout or len(readback.stdout) > 2048:
            fail("clientWitnessUnavailable")
        host_witness = Path(fixture["witnessPath"])
        fd = os.open(host_witness, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(readback.stdout)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException as error:
        primary = error
    finally:
        descriptor[:] = b"\0" * len(descriptor)
        try:
            cleanup = _run(
                [*prefix, "shell", "run-as", APP_ID, "rm", "-f",
                 device_descriptor, device_witness, device_witness + ".new", device_witness + ".bak"],
                timeout=10, output_limit=4096,
            )
            cleanup_ok = cleanup.returncode == 0
        except BaseException:
            cleanup_ok = False
    if primary is not None:
        raise primary
    if not cleanup_ok:
        fail("deviceCleanupFailed")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", choices=("direct", "public"), default="direct")
    parser.add_argument("--adb", required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--product-verifier", required=True)
    parser.add_argument("--product-native-dir", required=True)
    parser.add_argument("--product-receipt", required=True)
    parser.add_argument("--app-apk", required=True)
    parser.add_argument("--test-apk", required=True)
    parser.add_argument("--android-build-receipt", required=True)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--source-manifest", required=True)
    parser.add_argument("--fixture-source", required=True)
    parser.add_argument("--private-log", required=True)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args(argv)
    try:
        if not 1 <= args.timeout <= 1800:
            fail("invalidTimeout")
        run_client(args)
        return 0
    except (AdapterError, OSError, ValueError):
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
