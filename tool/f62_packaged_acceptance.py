#!/usr/bin/env python3
"""Run one packaged Android RDP acceptance without per-line shell state."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
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
TEST_NAME = "nlaShadowBaselineProvesPinnedFramesKeyEffectResizeAndCleanClose"
REPORTS = ROOT / "build/app/outputs/androidTest-results/connected/debug"
PACKAGE_RECEIPT = ROOT / "android/app/freerdp/receipt.json"
_DISPLAY = ":99"
_XINPUT_A_KEYCODE = 38
_SOURCE_DIMENSIONS = (1280, 800)
_TARGET_DIMENSIONS = (1024, 768)
_XI2_EVENT = re.compile(rb"^EVENT type \d+ \(([A-Za-z0-9]+)\)$")
_XI2_DETAIL = re.compile(rb"^\s*detail:\s*(\d+)\s*$")
_XDPI_DIMENSIONS = re.compile(r"^\s*dimensions:\s*(\d+)x(\d+) pixels")
_XRANDR_ACTIVE_OUTPUT = re.compile(
    rb"^([A-Za-z0-9][A-Za-z0-9_.:-]{0,63})\s+connected(?:\s+primary)?\s+"
    rb"(\d+)x(\d+)\+\d+\+\d+(?:\s|$)"
)
_OUTPUT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}")
_DIGEST = re.compile(r"[0-9a-f]{64}")
_MAX_REPORT_BYTES = 1024 * 1024
_MAX_FRAMES = 8
_PROBE_OUTCOMES = frozenset({
    "timeout",
    "connectionFailureBeforeCertificate",
    "certificateCallbackMissingPem",
    "certificateParseFailed",
})
_PROBE_OUTCOME = re.compile(
    r"^Caused by: RdpProbeOutcome\("
    r"(timeout|connectionFailureBeforeCertificate|"
    r"certificateCallbackMissingPem|certificateParseFailed)"
    r"\)$",
    re.MULTILINE,
)
_REPORT_SHAPES = frozenset({"aggregate", "unsupported"})
_FAILURE_CODES = frozenset({
    "instrumentation_launch_unavailable",
    "instrumentation_timeout",
    "instrumentation_report_missing",
    "instrumentation_report_ambiguous",
    "instrumentation_report_malformed",
    "instrumentation_report_identity_mismatch",
    "instrumentation_test_failure",
    "instrumentation_test_error",
    "host_keyboard_witness_missing",
    "host_resize_unavailable",
})
_KNOWN_EXCEPTION_TYPES = frozenset({
    "com.ersingundem.larenor.rdp.RdpNativeFailure",
    "java.lang.AssertionError",
    "java.lang.IllegalStateException",
    "java.lang.ClassNotFoundException",
    "java.lang.ExceptionInInitializerError",
    "java.lang.NoClassDefFoundError",
    "java.lang.NullPointerException",
    "java.lang.RuntimeException",
    "java.lang.SecurityException",
    "java.lang.UnsupportedOperationException",
    "java.lang.UnsatisfiedLinkError",
    "java.util.concurrent.TimeoutException",
    "kotlin.KotlinNullPointerException",
    "org.junit.ComparisonFailure",
    "org.junit.runners.model.TestTimedOutException",
})
_OWNED_FRAME = re.compile(
    r"\s*at (com\.ersingundem\.larenor\.rdp\.[A-Za-z0-9_.$]+"
    r"\.(?:[A-Za-z0-9_$]+|<init>|<clinit>))"
    r"\(([A-Za-z][A-Za-z0-9_]{0,127}\.(?:kt|java)):(\d{1,6})\)\s*"
)
_OWNED_SOURCE_FILES = frozenset(
    path.name
    for source_root in (
        ROOT / "android/app/src/main/kotlin/com/ersingundem/larenor/rdp",
        ROOT / "android/app/src/freerdp/kotlin/com/ersingundem/larenor/rdp",
        ROOT / "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp",
    )
    for path in source_root.rglob("*")
    if path.suffix in {".kt", ".java"} and path.is_file()
)


class AcceptanceFailure(RuntimeError):
    pass


class BaselineFailure(AcceptanceFailure):
    def __init__(self, code: str, message: str):
        if code not in {
            "host_keyboard_witness_missing", "host_resize_unavailable",
        }:
            raise ValueError("invalid owned baseline failure code")
        super().__init__(message)
        self.code = code


class Xi2KeyWitness:
    """Recognize one exact software HID A effect without retaining raw XI2."""

    def __init__(self) -> None:
        self._event: str | None = None
        self._pressed = False
        self.complete = False

    def feed_bytes(self, raw_line: bytes) -> None:
        line = raw_line.rstrip(b"\r")
        event = _XI2_EVENT.fullmatch(line)
        if event is not None:
            name = event.group(1)
            self._event = name.decode("ascii") if name in {
                b"RawKeyPress", b"RawKeyRelease",
            } else None
            return
        detail = _XI2_DETAIL.fullmatch(line)
        if detail is None:
            stripped = line.lstrip(b" \t")
            if stripped.startswith(b"EVENT type ") or stripped.startswith(b"detail:"):
                self._event = None
                raise BaselineFailure(
                    "host_keyboard_witness_missing",
                    "owned XI2 key witness was malformed",
                )
            return
        if self._event is None:
            return
        event_name = self._event
        self._event = None
        if int(detail.group(1)) != _XINPUT_A_KEYCODE:
            return
        if event_name == "RawKeyPress":
            if self._pressed or self.complete:
                raise BaselineFailure(
                    "host_keyboard_witness_missing",
                    "owned XI2 key witness was ambiguous",
                )
            self._pressed = True
        elif event_name == "RawKeyRelease":
            if not self._pressed or self.complete:
                raise BaselineFailure(
                    "host_keyboard_witness_missing",
                    "owned XI2 key witness was incomplete",
                )
            self.complete = True


def fixture_package_versions() -> dict[str, str]:
    values = {
        "freerdp3-shadow-x11": os.environ.get(
            "RDP_ACCEPTANCE_SHADOW_PACKAGE_VERSION", ""
        ),
        "winpr3-utils": os.environ.get("RDP_ACCEPTANCE_WINPR_PACKAGE_VERSION", ""),
        "xinput": os.environ.get("RDP_ACCEPTANCE_XINPUT_PACKAGE_VERSION", ""),
        "xserver-xorg-core": os.environ.get(
            "RDP_ACCEPTANCE_XORG_CORE_PACKAGE_VERSION", ""
        ),
        "xserver-xorg-video-dummy": os.environ.get(
            "RDP_ACCEPTANCE_XORG_DUMMY_PACKAGE_VERSION", ""
        ),
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
        "scope": "ownedShadowBaseline",
        "evidence": {
            "tlsNlaSpki": True,
            "initialFramebuffer": {"width": 1280, "height": 800, "nonzero": True},
            "rdpKeyEffect": {
                "usbHidUsage": "KeyA", "xi2PressRelease": True,
            },
            "hostDrivenFramebufferResize": {
                "width": 1024, "height": 768, "nonzero": True,
            },
            "frameAcknowledgementsAtLeast": 2,
            "cleanClose": True,
        },
        "unsupportedOrUnproven": [
            "clientDynamicResolution", "clientToRemoteClipboard", "ime",
        ],
        "result": "passed",
        "tests": 1,
        "skipped": 0,
        "failures": 0,
        "errors": 0,
    }


def _static_diagnostic(code: str) -> dict[str, object]:
    if code not in _FAILURE_CODES:
        raise AcceptanceFailure("packaged RDP failure code is unavailable")
    return {"code": code, "exceptionType": "unclassified", "frames": []}


def _failure_element_diagnostic(
    element: ET.Element,
    *,
    code: str,
    counts: dict[str, int],
) -> dict[str, object]:
    raw_type = element.attrib.get("type", "")
    text = "".join(element.itertext())
    if raw_type not in _KNOWN_EXCEPTION_TYPES:
        first = text.splitlines()[0].strip() if text.splitlines() else ""
        candidate = first.split(":", 1)[0]
        raw_type = candidate if candidate in _KNOWN_EXCEPTION_TYPES else "unclassified"
    frames: list[dict[str, object]] = []
    seen: set[tuple[str, int]] = set()
    for line in text.splitlines():
        match = _OWNED_FRAME.fullmatch(line)
        if match is None:
            continue
        class_name, filename, raw_line = match.groups()
        source_line = int(raw_line)
        simple_class = class_name.rsplit(".", 1)[0].rsplit(".", 1)[-1]
        simple_class = simple_class.split("$", 1)[0]
        source_class = filename.rsplit(".", 1)[0]
        key = (filename, source_line)
        if (filename not in _OWNED_SOURCE_FILES or source_line < 1
                or source_line > 1_000_000 or key in seen
                or simple_class not in {source_class, source_class + "Kt"}):
            continue
        seen.add(key)
        frames.append({"file": filename, "line": source_line})
        if len(frames) == _MAX_FRAMES:
            break
    diagnostic = {
        "code": code,
        "exceptionType": raw_type,
        "frames": frames,
        "counts": counts,
    }
    outcomes = _PROBE_OUTCOME.findall(text)
    if (len(outcomes) == 1
            and any(frame["file"] == "RdpPackagedRuntime.kt" for frame in frames)):
        diagnostic["probeOutcome"] = outcomes[0]
    return diagnostic


class _ReportShapeError(ValueError):
    def __init__(self, shape: str, child_suite_count: int):
        super().__init__()
        self.shape = shape
        self.child_suite_count = min(child_suite_count, 1024)


def _report_suite(root: ET.Element) -> tuple[ET.Element, dict[str, int]]:
    def counts(element: ET.Element) -> dict[str, int]:
        return {
            key: int(element.attrib[key])
            for key in ("tests", "skipped", "failures", "errors")
        }

    if root.tag == "testsuite":
        return root, counts(root)
    if root.tag != "testsuites":
        raise _ReportShapeError("unsupported", 0)
    children = list(root)
    child_suites = [child for child in children if child.tag == "testsuite"]
    if len(children) != 1 or len(child_suites) != 1:
        raise _ReportShapeError("aggregate", len(child_suites))
    aggregate = counts(root)
    suite = child_suites[0]
    if counts(suite) != aggregate:
        raise _ReportShapeError("aggregate", 1)
    return suite, aggregate


def failure_diagnostic(directory: Path | None = None) -> dict[str, object]:
    directory = REPORTS if directory is None else directory
    reports = list(directory.rglob("TEST-*.xml"))
    if not reports:
        return _static_diagnostic("instrumentation_report_missing")
    if len(reports) != 1:
        return _static_diagnostic("instrumentation_report_ambiguous")
    report = reports[0]
    try:
        metadata = report.lstat()
        if (not stat.S_ISREG(metadata.st_mode)
                or not 1 <= metadata.st_size <= _MAX_REPORT_BYTES):
            raise ValueError()
        raw = report.read_bytes()
        if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
            raise ValueError()
        root = ET.fromstring(raw)
        suite, counts = _report_suite(root)
    except _ReportShapeError as error:
        diagnostic = _static_diagnostic("instrumentation_report_malformed")
        diagnostic["reportShape"] = error.shape
        diagnostic["childSuiteCount"] = error.child_suite_count
        return diagnostic
    except (OSError, ET.ParseError, KeyError, ValueError, TypeError):
        return _static_diagnostic("instrumentation_report_malformed")
    if suite.findall(".//testsuite"):
        return _static_diagnostic("instrumentation_report_malformed")
    cases = list(suite.iter("testcase"))
    if any(not 0 <= value <= 1024 for value in counts.values()) or len(cases) > 1024:
        return _static_diagnostic("instrumentation_report_malformed")
    if (counts["tests"] != 1 or counts["skipped"] != 0 or len(cases) != 1
            or cases[0].attrib.get("classname") != TEST_CLASS
            or cases[0].attrib.get("name") != TEST_NAME):
        # Initialization/device failures can have a synthetic testcase identity. Keep
        # the acceptance rejection, but retain only booleans, bounded counts and
        # allowlisted owned frames so a real pre-method failure can be diagnosed.
        diagnostic = _static_diagnostic("instrumentation_report_identity_mismatch")
        if len(cases) == 1:
            elements = list(cases[0].findall("failure")) + list(cases[0].findall("error"))
            if len(elements) == 1:
                diagnostic = _failure_element_diagnostic(
                    elements[0], code="instrumentation_report_identity_mismatch", counts=counts)
        diagnostic["counts"] = counts
        diagnostic["identity"] = {
            "suiteExpected": True,
            "countsExpected": counts["tests"] == 1 and counts["skipped"] == 0,
            "caseCount": len(cases),
            "classExpected": len(cases) == 1 and cases[0].attrib.get("classname") == TEST_CLASS,
            "methodExpected": len(cases) == 1 and cases[0].attrib.get("name") == TEST_NAME,
        }
        return diagnostic
    failures = list(cases[0].findall("failure"))
    errors = list(cases[0].findall("error"))
    if (counts == {"tests": 1, "skipped": 0, "failures": 1, "errors": 0}
            and len(failures) == 1 and not errors):
        return _failure_element_diagnostic(
            failures[0], code="instrumentation_test_failure", counts=counts)
    if (counts == {"tests": 1, "skipped": 0, "failures": 0, "errors": 1}
            and len(errors) == 1 and not failures):
        return _failure_element_diagnostic(
            errors[0], code="instrumentation_test_error", counts=counts)
    return _static_diagnostic("instrumentation_report_malformed")


def failure_receipt(
    package_versions: dict[str, str],
    *,
    revision: str,
    package_digest: str,
    diagnostic: dict[str, object],
) -> dict[str, object]:
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise AcceptanceFailure("packaged RDP source revision is unavailable")
    if _DIGEST.fullmatch(package_digest) is None:
        raise AcceptanceFailure("packaged RDP receipt digest is unavailable")
    if set(diagnostic) not in ({"code", "exceptionType", "frames"}, {
            "code", "exceptionType", "frames", "counts"}, {
            "code", "exceptionType", "frames", "counts", "identity"}, {
            "code", "exceptionType", "frames", "counts", "probeOutcome"}, {
            "code", "exceptionType", "frames", "reportShape", "childSuiteCount"}):
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    code = diagnostic.get("code")
    exception_type = diagnostic.get("exceptionType")
    frames = diagnostic.get("frames")
    if (code not in _FAILURE_CODES
            or exception_type not in {*_KNOWN_EXCEPTION_TYPES, "unclassified"}
            or type(frames) is not list or len(frames) > _MAX_FRAMES):
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    for frame in frames:
        if (type(frame) is not dict or set(frame) != {"file", "line"}
                or frame["file"] not in _OWNED_SOURCE_FILES
                or type(frame["line"]) is not int
                or not 1 <= frame["line"] <= 1_000_000):
            raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    counts = diagnostic.get("counts")
    identity = diagnostic.get("identity")
    probe_outcome = diagnostic.get("probeOutcome")
    if probe_outcome is not None and (
            probe_outcome not in _PROBE_OUTCOMES
            or not any(frame["file"] == "RdpPackagedRuntime.kt" for frame in frames)):
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    report_shape = diagnostic.get("reportShape")
    child_suite_count = diagnostic.get("childSuiteCount")
    if ((report_shape is None) != (child_suite_count is None)
            or report_shape is not None and (
                code != "instrumentation_report_malformed"
                or report_shape not in _REPORT_SHAPES
                or type(child_suite_count) is not int
                or not 0 <= child_suite_count <= 1024)):
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    mismatch = code == "instrumentation_report_identity_mismatch"
    if mismatch:
        if (type(identity) is not dict or set(identity) != {
                "suiteExpected", "countsExpected", "caseCount", "classExpected", "methodExpected"}
                or any(type(identity[key]) is not bool for key in (
                    "suiteExpected", "countsExpected", "classExpected", "methodExpected"))
                or type(identity["caseCount"]) is not int
                or not 0 <= identity["caseCount"] <= 1024
                or counts is None):
            raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    elif identity is not None:
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    if counts is not None and (type(counts) is not dict
            or set(counts) != {"tests", "skipped", "failures", "errors"}
            or any(type(value) is not int or not 0 <= value <= (1024 if mismatch else 1)
                   for value in counts.values())):
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    expected_counts = {
        "instrumentation_test_failure": {
            "tests": 1, "skipped": 0, "failures": 1, "errors": 0,
        },
        "instrumentation_test_error": {
            "tests": 1, "skipped": 0, "failures": 0, "errors": 1,
        },
    }
    if not mismatch and ((code in expected_counts) != (counts is not None)
            or counts is not None and counts != expected_counts[code]):
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    return {
        "schemaVersion": 1,
        "sourceRevision": revision,
        "packageReceiptSha256": package_digest,
        "testClass": TEST_CLASS,
        "testName": TEST_NAME,
        "ownedHostPackages": package_versions,
        "result": "failed",
        "diagnostic": diagnostic,
    }


def verify_reports(directory: Path = REPORTS) -> Path:
    reports = list(directory.rglob("TEST-*.xml"))
    if len(reports) != 1:
        raise AcceptanceFailure("exact packaged RDP test report is unavailable")
    try:
        root = ET.parse(reports[0]).getroot()
        suite, counts = _report_suite(root)
        cases = list(suite.iter("testcase"))
    except (OSError, ET.ParseError, KeyError, ValueError) as error:
        raise AcceptanceFailure("packaged RDP test report is malformed") from error
    if (
        counts != {"tests": 1, "skipped": 0, "failures": 0, "errors": 0}
        or len(cases) != 1
        or cases[0].attrib.get("classname") != TEST_CLASS
        or cases[0].attrib.get("name") != TEST_NAME
        or len(suite.findall(".//skipped")) != 0
        or len(suite.findall(".//failure")) != 0
        or len(suite.findall(".//error")) != 0
        or len(suite.findall(".//testsuite")) != 0
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


def _public_output(runner_temp: Path) -> Path:
    output = runner_temp / "freerdp-public-acceptance"
    try:
        output.mkdir(mode=0o700)
        output.chmod(0o700)
    except OSError as error:
        raise AcceptanceFailure(
            "packaged RDP public receipt directory could not be created"
        ) from error
    return output


def _provenance() -> tuple[str, str]:
    try:
        revision = source_revision(ROOT)
    except NativeAcceptanceReceiptError:
        raise AcceptanceFailure("packaged RDP source revision is unavailable") from None
    return revision, package_receipt_digest()


def publish_public_receipt(
    report: Path,
    runner_temp: Path,
    package_versions: dict[str, str],
) -> Path:
    revision, package_digest = _provenance()
    receipt = acceptance_receipt(
        package_versions,
        revision=revision,
        package_digest=package_digest,
    )
    output = _public_output(runner_temp)
    destination = output / "receipt.json"
    write_public_receipt(destination, receipt)
    try:
        report.unlink()
    except OSError as error:
        raise AcceptanceFailure("packaged RDP raw report could not be removed") from error
    return destination


def publish_public_failure(
    diagnostic: dict[str, object],
    runner_temp: Path,
    package_versions: dict[str, str],
    directory: Path | None = None,
) -> Path:
    directory = REPORTS if directory is None else directory
    revision, package_digest = _provenance()
    receipt = failure_receipt(
        package_versions,
        revision=revision,
        package_digest=package_digest,
        diagnostic=diagnostic,
    )
    output = _public_output(runner_temp)
    destination = output / "failure.json"
    write_public_receipt(destination, receipt)
    try:
        for report in directory.rglob("TEST-*.xml"):
            report.unlink()
    except OSError as error:
        raise AcceptanceFailure(
            "packaged RDP raw failure report could not be removed"
        ) from error
    return destination


def _publish_failed_run(
    runner_temp: Path,
    package_versions: dict[str, str],
    *,
    code: str | None = None,
) -> None:
    diagnostic = (failure_diagnostic() if code is None
                  else _static_diagnostic(code))
    publish_public_failure(diagnostic, runner_temp, package_versions)


def _stop_owned_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


def _display_dimensions() -> tuple[int, int]:
    environment = {**os.environ, "DISPLAY": _DISPLAY}
    try:
        result = subprocess.run(
            ["/usr/bin/xdpyinfo"],
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BaselineFailure(
            "host_resize_unavailable",
            "owned Xorg dimension readback was unavailable",
        ) from error
    if result.returncode != 0 or len(result.stdout) > 128 * 1024:
        raise BaselineFailure(
            "host_resize_unavailable",
            "owned Xorg dimension readback failed",
        )
    dimensions = []
    for raw_line in result.stdout.splitlines():
        try:
            line = raw_line.decode("ascii", errors="strict")
        except UnicodeDecodeError:
            continue
        match = _XDPI_DIMENSIONS.match(line)
        if match is not None:
            dimensions.append((int(match.group(1)), int(match.group(2))))
    if len(dimensions) != 1:
        raise BaselineFailure(
            "host_resize_unavailable",
            "owned Xorg dimension readback was ambiguous",
        )
    return dimensions[0]


def _active_owned_output(dimensions: tuple[int, int]) -> str:
    expected = os.environ.get("RDP_ACCEPTANCE_XORG_OUTPUT", "")
    if _OUTPUT_NAME.fullmatch(expected) is None:
        raise BaselineFailure(
            "host_resize_unavailable",
            "owned Xorg output identity was unavailable",
        )
    environment = {**os.environ, "DISPLAY": _DISPLAY}
    try:
        result = subprocess.run(
            ["/usr/bin/xrandr", "--query"],
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BaselineFailure(
            "host_resize_unavailable",
            "owned Xorg output readback was unavailable",
        ) from error
    if result.returncode != 0 or len(result.stdout) > 128 * 1024:
        raise BaselineFailure(
            "host_resize_unavailable",
            "owned Xorg output readback failed",
        )
    active: list[tuple[str, int, int]] = []
    for line in result.stdout.splitlines():
        match = _XRANDR_ACTIVE_OUTPUT.match(line)
        if match is not None:
            active.append((
                match.group(1).decode("ascii", errors="strict"),
                int(match.group(2)),
                int(match.group(3)),
            ))
    if active != [(expected, *dimensions)]:
        raise BaselineFailure(
            "host_resize_unavailable",
            "owned Xorg active output was ambiguous",
        )
    return expected


def _resize_owned_display() -> None:
    environment = {**os.environ, "DISPLAY": _DISPLAY}
    output = _active_owned_output(_SOURCE_DIMENSIONS)
    try:
        result = subprocess.run(
            [
                "/usr/bin/xrandr",
                "--output",
                output,
                "--mode",
                "1024x768",
                "--fb",
                "1024x768",
            ],
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BaselineFailure(
            "host_resize_unavailable",
            "owned Xorg resize was unavailable",
        ) from error
    if result.returncode != 0:
        raise BaselineFailure(
            "host_resize_unavailable",
            "owned Xorg resize was not observed",
        )
    _active_owned_output(_TARGET_DIMENSIONS)
    if _display_dimensions() != _TARGET_DIMENSIONS:
        raise BaselineFailure(
            "host_resize_unavailable",
            "owned Xorg resize was not observed",
        )


def _run_owned_shadow_baseline(command: list[str], *, timeout: float = 1200) -> int:
    """Run instrumentation while witnessing XI2 and controlling owned Xorg."""
    environment = {**os.environ, "DISPLAY": _DISPLAY}
    xinput: subprocess.Popen[bytes] | None = None
    gradle: subprocess.Popen[bytes] | None = None
    selector = selectors.DefaultSelector()
    deadline = time.monotonic() + timeout
    try:
        xinput = subprocess.Popen(
            ["/usr/bin/stdbuf", "-oL", "/usr/bin/xinput", "test-xi2", "--root"],
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            bufsize=0,
        )
        if xinput.stdout is None or xinput.poll() is not None:
            raise BaselineFailure(
                "host_keyboard_witness_missing",
                "owned XI2 key witness could not start",
            )
        selector.register(xinput.stdout, selectors.EVENT_READ)
        gradle = subprocess.Popen(
            command,
            cwd=ROOT / "android",
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        witness = Xi2KeyWitness()
        buffered = b""
        observed_bytes = 0
        while not witness.complete:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout)
            gradle_status = gradle.poll()
            if gradle_status is not None:
                if gradle_status != 0:
                    return gradle_status
                raise BaselineFailure(
                    "host_keyboard_witness_missing",
                    "owned XI2 key witness was not observed",
                )
            if xinput.poll() is not None:
                raise BaselineFailure(
                    "host_keyboard_witness_missing",
                    "owned XI2 key witness stopped early",
                )
            for key, _ in selector.select(timeout=min(0.25, remaining)):
                chunk = os.read(key.fd, 4096)
                if not chunk:
                    raise BaselineFailure(
                        "host_keyboard_witness_missing",
                        "owned XI2 key witness closed early",
                    )
                observed_bytes += len(chunk)
                if observed_bytes > 1024 * 1024:
                    raise BaselineFailure(
                        "host_keyboard_witness_missing",
                        "owned XI2 key witness exceeded its bound",
                    )
                buffered += chunk
                while b"\n" in buffered:
                    raw_line, buffered = buffered.split(b"\n", 1)
                    witness.feed_bytes(raw_line)
        _resize_owned_display()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, timeout)
        try:
            return gradle.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            raise subprocess.TimeoutExpired(command, timeout) from None
    finally:
        selector.close()
        if gradle is not None and gradle.poll() is None:
            _stop_owned_process(gradle)
        if xinput is not None:
            _stop_owned_process(xinput)


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
            returncode = _run_owned_shadow_baseline(
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
                timeout=1200,
            )
    except BaselineFailure as error:
        _publish_failed_run(runner_temp, package_versions, code=error.code)
        raise AcceptanceFailure(str(error)) from None
    except subprocess.TimeoutExpired:
        # TimeoutExpired includes argv, including the disposable credential.
        _publish_failed_run(
            runner_temp, package_versions, code="instrumentation_timeout")
        raise AcceptanceFailure("packaged RDP instrumentation timed out") from None
    except (AndroidAcceptanceGradleError, OSError):
        _publish_failed_run(
            runner_temp, package_versions,
            code="instrumentation_launch_unavailable",
        )
        raise AcceptanceFailure(
            "packaged RDP instrumentation could not start") from None
    if returncode:
        _publish_failed_run(runner_temp, package_versions)
        raise AcceptanceFailure(
            "packaged RDP instrumentation failed; public diagnostics written")
    try:
        report = verify_reports()
    except AcceptanceFailure:
        _publish_failed_run(runner_temp, package_versions)
        raise AcceptanceFailure(
            "packaged RDP report failed; public diagnostics written") from None
    publish_public_receipt(report, runner_temp, package_versions)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AcceptanceFailure as error:
        print(f"F62_ACCEPTANCE_FAILURE:{error}", file=sys.stderr)
        raise SystemExit(1) from None
