#!/usr/bin/env python3
"""Run one packaged Android RDP acceptance without per-line shell state."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
TEST_CLASS = "com.ersingundem.larenor.rdp.RdpPackagedHostAcceptanceTest"
TEST_NAME = "nlaHostDeliversPinnedFrameInputResizeClipboardAndCleanClose"
REPORTS = ROOT / "build/app/outputs/androidTest-results/connected/debug"


class AcceptanceFailure(RuntimeError):
    pass


def verify_reports(directory: Path = REPORTS) -> None:
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


def main() -> int:
    password = os.environ.get("RDP_ACCEPTANCE_PASSWORD", "")
    if not password or len(password) > 128 or "\x00" in password:
        raise AcceptanceFailure("owned RDP fixture credential is unavailable")
    # A cached or skipped invocation must not inherit a previous passing report.
    for report in REPORTS.rglob("TEST-*.xml"):
        report.unlink()
    try:
        result = subprocess.run(
            [
                "./gradlew", "--no-daemon",
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
    except (OSError, subprocess.TimeoutExpired):
        # TimeoutExpired includes argv, including the disposable credential.
        raise AcceptanceFailure("packaged RDP instrumentation could not complete") from None
    if result.returncode:
        raise AcceptanceFailure("packaged RDP instrumentation failed")
    verify_reports()
    output = Path(os.environ["RUNNER_TEMP"]) / "freerdp-package/acceptance"
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(next(REPORTS.rglob("TEST-*.xml")), output / "client-report.xml")
    (output / "client-receipt.json").write_text(json.dumps({
        "schemaVersion": 1,
        "testClass": TEST_CLASS,
        "testName": TEST_NAME,
        "result": "passed",
        "tests": 1, "skipped": 0, "failures": 0, "errors": 0,
    }, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
