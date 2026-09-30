#!/usr/bin/env python3
"""Run one packaged Android RDP acceptance without per-line shell state."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET

if __package__:
    from .android_acceptance_gradle import (
        AndroidAcceptanceGradleError,
        materialized_gradle_command,
    )
    from .native_acceptance_receipt import (
        NativeAcceptanceReceiptError,
        source_revision,
    )
else:
    from android_acceptance_gradle import (
        AndroidAcceptanceGradleError,
        materialized_gradle_command,
    )
    from native_acceptance_receipt import (
        NativeAcceptanceReceiptError,
        source_revision,
    )


ROOT = Path(__file__).resolve().parents[1]
TEST_CLASS = "com.ersingundem.larenor.rdp.RdpPackagedHostAcceptanceTest"
TEST_NAME = "nlaHostDeliversPinnedFrameInputResizeClipboardAndCleanClose"
REPORTS = ROOT / "build/app/outputs/androidTest-results/connected/debug"
PACKAGE_RECEIPT = ROOT / "android/app/freerdp/receipt.json"
_DIGEST = re.compile(r"[0-9a-f]{64}")


class AcceptanceFailure(RuntimeError):
    pass


def fixture_package_versions() -> dict[str, str]:
    values = {
        "freerdp3-shadow-x11": os.environ.get(
            "RDP_ACCEPTANCE_SHADOW_PACKAGE_VERSION", ""
        ),
        "winpr3-utils": os.environ.get("RDP_ACCEPTANCE_WINPR_PACKAGE_VERSION", ""),
    }
    if any(
        re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,127}", value) is None
        for value in values.values()
    ):
        raise AcceptanceFailure("owned RDP fixture package version is unavailable")
    return values


def package_receipt_digest(path: Path = PACKAGE_RECEIPT) -> str:
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or not 1 <= metadata.st_size <= 1024 * 1024
        ):
            raise AcceptanceFailure("packaged RDP receipt is unavailable")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise AcceptanceFailure("packaged RDP receipt is unavailable") from error
    return digest.hexdigest()


def acceptance_receipt(
    package_versions: dict[str, str],
    *,
    revision: str,
    package_digest: str,
) -> dict[str, object]:
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise AcceptanceFailure("packaged RDP source revision is unavailable")
    if _DIGEST.fullmatch(package_digest) is None:
        raise AcceptanceFailure("packaged RDP receipt digest is unavailable")
    return {
        "schemaVersion": 1,
        "sourceRevision": revision,
        "packageReceiptSha256": package_digest,
        "testClass": TEST_CLASS,
        "testName": TEST_NAME,
        "ownedHostPackages": package_versions,
        "result": "passed",
        "tests": 1,
        "skipped": 0,
        "failures": 0,
        "errors": 0,
    }


def verify_reports(directory: Path = REPORTS) -> Path:
    reports = list(directory.rglob("TEST-*.xml"))
    if len(reports) != 1:
        raise AcceptanceFailure("exact packaged RDP test report is unavailable")
    try:
        suite = ET.parse(reports[0]).getroot()
        counts = {key: int(suite.attrib[key]) for key in
                  ("tests", "skipped", "failures", "errors")}
        cases = list(suite.iter("testcase"))
    except (OSError, ET.ParseError, KeyError, ValueError) as error:
        raise AcceptanceFailure("packaged RDP test report is malformed") from error
    if (
        suite.tag != "testsuite"
        or counts != {"tests": 1, "skipped": 0, "failures": 0, "errors": 0}
        or len(cases) != 1
        or cases[0].attrib.get("classname") != TEST_CLASS
        or cases[0].attrib.get("name") != TEST_NAME
        or len(suite.findall(".//skipped")) != 0
        or len(suite.findall(".//failure")) != 0
        or len(suite.findall(".//error")) != 0
    ):
        raise AcceptanceFailure("packaged RDP acceptance did not execute exactly once")
    return reports[0]


def write_public_receipt(path: Path, receipt: dict[str, object]) -> None:
    payload = json.dumps(
        receipt,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ) + "\n"
    try:
        with path.open("x", encoding="utf-8") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        path.chmod(0o600)
    except OSError as error:
        raise AcceptanceFailure("packaged RDP public receipt could not be written") from error


def publish_public_receipt(
    report: Path,
    runner_temp: Path,
    package_versions: dict[str, str],
) -> Path:
    try:
        revision = source_revision(ROOT)
    except NativeAcceptanceReceiptError:
        raise AcceptanceFailure("packaged RDP source revision is unavailable") from None
    receipt = acceptance_receipt(
        package_versions,
        revision=revision,
        package_digest=package_receipt_digest(),
    )
    output = runner_temp / "freerdp-public-acceptance"
    try:
        output.mkdir(mode=0o700)
        output.chmod(0o700)
    except OSError as error:
        raise AcceptanceFailure(
            "packaged RDP public receipt directory could not be created"
        ) from error
    destination = output / "receipt.json"
    write_public_receipt(destination, receipt)
    try:
        report.unlink()
    except OSError as error:
        raise AcceptanceFailure("packaged RDP raw report could not be removed") from error
    return destination


def main() -> int:
    password = os.environ.get("RDP_ACCEPTANCE_PASSWORD", "")
    if not password or len(password) > 128 or "\x00" in password:
        raise AcceptanceFailure("owned RDP fixture credential is unavailable")
    package_versions = fixture_package_versions()
    # A cached or skipped invocation must not inherit a previous passing report.
    for report in REPORTS.rglob("TEST-*.xml"):
        report.unlink()
    runner_temp = Path(os.environ["RUNNER_TEMP"])
    try:
        with tempfile.TemporaryDirectory(
            prefix="larenor-f62-gradle-", dir=runner_temp
        ) as temporary:
            gradle = materialized_gradle_command(
                Path(temporary) / "launcher",
                project_android=ROOT / "android",
            )
            result = subprocess.run(
                [
                    *gradle, "--no-daemon",
                    ":app:connectedDebugAndroidTest",
                    f"-Pandroid.testInstrumentationRunnerArguments.class={TEST_CLASS}",
                    "-Pandroid.testInstrumentationRunnerArguments.rdpHost=10.0.2.2",
                    "-Pandroid.testInstrumentationRunnerArguments.rdpPort=3390",
                    "-Pandroid.testInstrumentationRunnerArguments.rdpUsername=larenor",
                    "-Pandroid.testInstrumentationRunnerArguments.rdpDomain=LARENOR",
                    f"-Pandroid.testInstrumentationRunnerArguments.rdpPassword={password}",
                ],
                cwd=ROOT / "android", check=False, timeout=1200,
            )
    except (AndroidAcceptanceGradleError, OSError, subprocess.TimeoutExpired):
        # TimeoutExpired includes argv, including the disposable credential.
        raise AcceptanceFailure("packaged RDP instrumentation could not complete") from None
    if result.returncode:
        raise AcceptanceFailure("packaged RDP instrumentation failed")
    report = verify_reports()
    publish_public_receipt(report, runner_temp, package_versions)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
