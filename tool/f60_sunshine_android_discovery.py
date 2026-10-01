#!/usr/bin/env python3
"""Run the named packaged-Android discovery gate against owned Sunshine."""

from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from tool.android_acceptance_gradle import materialized_gradle_command
from tool.f60_sunshine_owned_host import OwnedSunshineHost, _sunshine_mdns_instance_name
from tool.native_acceptance_receipt import source_revision


ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "build/app/outputs/androidTest-results/connected/debug"
TEST_CLASS = (
    "com.ersingundem.larenor.game.moonlight."
    "MoonlightOwnedSunshineDiscoveryTest"
)
TEST_NAME = "discoversTheExactOwnedSunshineServiceAcrossFreshDiscoveryLifetimes"
RECEIPT_NAME = "f60-sunshine-android-discovery-receipt.json"
MOONLIGHT_AAR = ROOT / "android/app/moonlight/moonlight-engine.aar"
MOONLIGHT_RECEIPT = ROOT / "android/app/moonlight/receipt.json"
MOONLIGHT_ENGINE_REVISION = "moonlight-android-12.2-larenor-embed-v2"
MOONLIGHT_SOURCE_COMMIT = "b48494cb96bff23d8886c4775cc4f39a1075495d"
_EMULATOR_VERSION = re.compile(
    r"Android emulator version ([0-9]+)\.([0-9]+)\.([0-9]+)(?:\.[0-9]+)?"
)


class DiscoveryAcceptanceFailure(RuntimeError):
    pass


def _pairs(values: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in values:
        if key in result:
            raise DiscoveryAcceptanceFailure("Moonlight package receipt is invalid")
        result[key] = value
    return result


def package_identity(
    aar: Path = MOONLIGHT_AAR,
    receipt_path: Path = MOONLIGHT_RECEIPT,
) -> dict[str, str]:
    try:
        aar_info = aar.lstat()
        receipt_info = receipt_path.lstat()
        if (
            stat.S_ISLNK(aar_info.st_mode)
            or not stat.S_ISREG(aar_info.st_mode)
            or not 1 <= aar_info.st_size <= 128 * 1024 * 1024
            or stat.S_ISLNK(receipt_info.st_mode)
            or not stat.S_ISREG(receipt_info.st_mode)
            or not 1 <= receipt_info.st_size <= 64 * 1024
        ):
            raise DiscoveryAcceptanceFailure("Moonlight package identity is invalid")
        digest = hashlib.sha256(aar.read_bytes()).hexdigest()
        receipt = json.loads(
            receipt_path.read_text(encoding="utf-8"), object_pairs_hook=_pairs,
        )
    except DiscoveryAcceptanceFailure:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise DiscoveryAcceptanceFailure("Moonlight package identity is invalid") from error
    expected = {
        "aarSha256": digest,
        "engineRevision": MOONLIGHT_ENGINE_REVISION,
        "sourceCommit": MOONLIGHT_SOURCE_COMMIT,
    }
    if not isinstance(receipt, dict) or any(receipt.get(key) != value for key, value in expected.items()):
        raise DiscoveryAcceptanceFailure("Moonlight package receipt is invalid")
    source_tree = receipt.get("sourceTree")
    classes = receipt.get("classesSha256")
    if (
        not isinstance(source_tree, str)
        or re.fullmatch(r"[0-9a-f]{40}", source_tree) is None
        or not isinstance(classes, str)
        or re.fullmatch(r"[0-9a-f]{64}", classes) is None
    ):
        raise DiscoveryAcceptanceFailure("Moonlight package receipt is invalid")
    return {**expected, "sourceTree": source_tree, "classesSha256": classes}


def parse_emulator_version(output: str) -> str:
    match = _EMULATOR_VERSION.search(output)
    if match is None:
        raise DiscoveryAcceptanceFailure("Android emulator 36.5 or newer is required")
    version = tuple(int(value) for value in match.groups())
    if version < (36, 5, 0):
        raise DiscoveryAcceptanceFailure("Android emulator 36.5 or newer is required")
    return match.group(0).removeprefix("Android emulator version ")


def emulator_version() -> str:
    sdk_home = os.environ.get("ANDROID_HOME")
    sdk_root = os.environ.get("ANDROID_SDK_ROOT")
    environment = {"PATH": os.environ.get("PATH", "")}
    try:
        if sdk_home or sdk_root:
            sdk = Path(sdk_home or sdk_root)
            if not sdk.is_absolute() or (
                sdk_home and sdk_root
                and Path(sdk_home).resolve() != Path(sdk_root).resolve()
            ):
                raise DiscoveryAcceptanceFailure("Android emulator SDK identity is invalid")
            executable = sdk / "emulator" / "emulator"
            if not executable.is_file() or not os.access(executable, os.X_OK):
                raise DiscoveryAcceptanceFailure("Android emulator identity is unavailable")
            environment.update(ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
        else:
            discovered = shutil.which("emulator", path=environment["PATH"])
            if discovered is None:
                raise DiscoveryAcceptanceFailure("Android emulator identity is unavailable")
            executable = Path(discovered).resolve()
        result = subprocess.run(
            [str(executable), "-version"], capture_output=True, text=True,
            check=False, timeout=10, env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DiscoveryAcceptanceFailure("Android emulator identity is unavailable") from error
    if result.returncode:
        raise DiscoveryAcceptanceFailure("Android emulator 36.5 or newer is required")
    return parse_emulator_version(result.stdout + result.stderr)


def verify_report(root: Path = REPORTS) -> dict[str, int | str]:
    try:
        root_info = root.lstat()
        if stat.S_ISLNK(root_info.st_mode) or not stat.S_ISDIR(root_info.st_mode):
            raise DiscoveryAcceptanceFailure("Android discovery report identity is invalid")
        reports = list(root.rglob("TEST-*.xml"))
        if len(reports) != 1:
            raise DiscoveryAcceptanceFailure("Android discovery report is missing or ambiguous")
        report = reports[0]
        relative = report.relative_to(root)
        cursor = root
        for part in relative.parts[:-1]:
            cursor /= part
            if cursor.is_symlink():
                raise DiscoveryAcceptanceFailure("Android discovery report identity is invalid")
        info = report.lstat()
        if report.is_symlink() or not report.is_file() or info.st_size not in range(1, 1024 * 1024 + 1):
            raise DiscoveryAcceptanceFailure("Android discovery report identity is invalid")
        suite = ET.parse(report).getroot()
    except (OSError, ET.ParseError) as error:
        raise DiscoveryAcceptanceFailure("Android discovery report is malformed") from error
    if suite.tag != "testsuite" or any(
        suite.attrib.get(key) != value
        for key, value in {
            "tests": "1", "failures": "0", "errors": "0", "skipped": "0",
        }.items()
    ):
        raise DiscoveryAcceptanceFailure("Android discovery report aggregate is invalid")
    if len(list(suite.iter("testsuite"))) != 1:
        raise DiscoveryAcceptanceFailure("Android discovery report is ambiguous")
    cases = list(suite.iter("testcase"))
    if len(cases) != 1:
        raise DiscoveryAcceptanceFailure("Android discovery report is missing or ambiguous")
    case = cases[0]
    if case.attrib.get("classname") != TEST_CLASS or case.attrib.get("name") != TEST_NAME:
        raise DiscoveryAcceptanceFailure("Android discovery report identity is invalid")
    if any(case.find(kind) is not None for kind in ("failure", "error", "skipped")):
        raise DiscoveryAcceptanceFailure("Android discovery test did not pass")
    return {"className": TEST_CLASS, "testName": TEST_NAME, "tests": 1,
            "failures": 0, "errors": 0, "skipped": 0}


def write_receipt(
    destination: Path,
    *,
    version: str,
    report: dict[str, int | str],
    moonlight_package: dict[str, str],
) -> None:
    payload = {
        "schemaVersion": 1,
        "gate": "owned_sunshine_android_discovery",
        "sourceRevision": source_revision(ROOT),
        "provider": "Sunshine",
        "providerTag": "v2026.914.233613",
        "service": "_nvstream._tcp",
        "displayName": "Larenor-F60-Owned",
        "port": 47989,
        "emulatorVersion": version,
        "discoveryLifetimes": 2,
        "moonlightPackage": moonlight_package,
        "streamAccepted": False,
        "test": report,
    }
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode() + b"\n"
    if len(encoded) > 4096:
        raise DiscoveryAcceptanceFailure("Android discovery receipt exceeds its bound")
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, encoded)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def main() -> int:
    version = emulator_version()
    moonlight_package = package_identity()
    for report in REPORTS.rglob("TEST-*.xml"):
        report.unlink()
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    expected_instance = _sunshine_mdns_instance_name()
    with OwnedSunshineHost.start() as owned:
        readiness = owned.public_readiness()
        if readiness.get("state") != "host_ready" or readiness.get("streamAccepted") is not False:
            raise DiscoveryAcceptanceFailure("owned Sunshine host is not ready")
        with tempfile.TemporaryDirectory(prefix="f60-discovery-gradle-", dir=runner_temp) as temporary:
            gradle = materialized_gradle_command(
                Path(temporary) / "launcher", project_android=ROOT / "android",
            )
            result = subprocess.run(
                [
                    *gradle, "--no-daemon", ":app:connectedDebugAndroidTest",
                    f"-Pandroid.testInstrumentationRunnerArguments.class={TEST_CLASS}",
                    "-Pandroid.testInstrumentationRunnerArguments.larenorF60OwnedDiscovery=required",
                    "-Pandroid.testInstrumentationRunnerArguments."
                    f"larenorF60OwnedMdnsInstance={expected_instance}",
                    "-x", ":app:compileFlutterBuildDebug",
                ],
                cwd=ROOT / "android", check=False, timeout=1200,
            )
            if result.returncode:
                raise DiscoveryAcceptanceFailure("owned Sunshine Android discovery failed")
        owned.processes.require_alive()
    report = verify_report()
    write_receipt(
        runner_temp / RECEIPT_NAME,
        version=version,
        report=report,
        moonlight_package=moonlight_package,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DiscoveryAcceptanceFailure as error:
        print(f"F60_DISCOVERY_FAILURE:{error}", file=os.sys.stderr)
        raise SystemExit(1) from None
