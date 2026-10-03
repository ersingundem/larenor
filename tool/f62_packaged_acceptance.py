#!/usr/bin/env python3
"""Run one packaged Android RDP acceptance without per-line shell state."""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
import re
import secrets
import selectors
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

if __package__:
    from .f62_owned_microphone import MicrophoneFixtureError, start_tone, verified_pulse
    from .android_acceptance_gradle import (
        AndroidAcceptanceGradleError,
        materialized_gradle_command,
    )
    from .native_acceptance_receipt import (
        NativeAcceptanceReceiptError,
        source_revision,
    )
    from .f62_owned_shadow_channels import (
        FixtureError,
        AUDIO_PATCH_SHA256 as SHADOW_AUDIO_PATCH_SHA256,
        MICROPHONE_PATCH_SHA256 as SHADOW_MICROPHONE_PATCH_SHA256,
        PATCH_SHA256 as SHADOW_PATCH_SHA256,
        SHADOW_CLI_RELATIVE,
        SOURCE_COMMIT as SHADOW_SOURCE_COMMIT,
        SOURCE_SHA256 as SHADOW_SOURCE_SHA256,
        SOURCE_VERSION as SHADOW_SOURCE_VERSION,
        read_lifetimes,
        read_audio_lifetimes,
        read_microphone_lifetimes,
        verify_patched_source,
    )
else:
    from f62_owned_microphone import MicrophoneFixtureError, start_tone, verified_pulse
    from android_acceptance_gradle import (
        AndroidAcceptanceGradleError,
        materialized_gradle_command,
    )
    from native_acceptance_receipt import (
        NativeAcceptanceReceiptError,
        source_revision,
    )
    from f62_owned_shadow_channels import (
        FixtureError,
        AUDIO_PATCH_SHA256 as SHADOW_AUDIO_PATCH_SHA256,
        MICROPHONE_PATCH_SHA256 as SHADOW_MICROPHONE_PATCH_SHA256,
        PATCH_SHA256 as SHADOW_PATCH_SHA256,
        SHADOW_CLI_RELATIVE,
        SOURCE_COMMIT as SHADOW_SOURCE_COMMIT,
        SOURCE_SHA256 as SHADOW_SOURCE_SHA256,
        SOURCE_VERSION as SHADOW_SOURCE_VERSION,
        read_lifetimes,
        read_audio_lifetimes,
        read_microphone_lifetimes,
        verify_patched_source,
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
_CHANNEL_PHASE_DISP = b"LRNDISP1"
_CHANNEL_PHASE_CLIP = b"LRNCLIP1"
_CHANNEL_PHASE_MICROPHONE = b"LRNMIC01"
_CHANNEL_PHASES = [_CHANNEL_PHASE_MICROPHONE, _CHANNEL_PHASE_DISP, _CHANNEL_PHASE_CLIP]
_CHANNEL_PHASE_BYTES = 24
_AUDIO_ARM_MAGIC = b"LRNAUD01"
_AUDIO_ARM_BYTES = 72
_EFFECT_CONTROL_MAGIC = b"LRNCTL01"
_EFFECT_CONTROL_PHASE_CODES = {
    "audio": b"AUDARM01",
    "microphone": b"MICARM01",
}
_OWNED_TEST_DIGEST = (
    "784cd21e527c4b3bac1eef254097cdaf5cc3ef8d4f41d4b4473c61724bb69fbb"
)
_EFFECT_CONTROL_BYTES = 208
_CLIPBOARD_MARKER_COLOR = "#8f3c72"
_SHADOW_PORT = 3390
_MAX_SHADOW_LOG_BYTES = 1024 * 1024
_SERVER_RESIZE_REQUESTED = re.compile(
    rb"resize requested \(1024x768@[0-9]{1,4}\)"
)
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
_TEST_PACKAGE = "com.ersingundem.larenor"
_TEST_LIFECYCLE_STAGES = (
    "testInitialization",
    "connectionValidation",
    "runtimeValidation",
    "providerInspection",
    "firstSessionOpen",
    "firstSecurityWait",
    "initialFrameWait",
    "audioEffectWait",
    "microphoneOpenWait",
    "microphoneEffectWait",
    "keySubmission",
    "resizeSubmission",
    "resizedFrameWait",
    "clipboardSubmission",
    "clipboardEffectWait",
    "firstClose",
    "firstClosedValidation",
    "secondSessionOpen",
    "secondSecurityWait",
    "secondFrameWait",
    "disabledClipboardCheck",
    "secondClose",
    "credentialValidation",
    "complete",
)
_TEST_LIFECYCLE_STAGE_SET = frozenset(_TEST_LIFECYCLE_STAGES)
_DIAGNOSTIC_NONCE = re.compile(r"[0-9a-f]{64}")
_ADB_SERIAL = re.compile(r"[A-Za-z0-9._:-]{1,128}")
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
    "host_channel_fixture_unavailable",
    "host_channel_witness_invalid",
})
_INITIAL_FRAME_TERMINAL_EXCEPTIONS = {
    "com.ersingundem.larenor.rdp.RdpOwnedInitialFrameConnectionFailed": {
        "sessionPhase": "failed", "failureCode": "connectionFailed",
    },
    "com.ersingundem.larenor.rdp.RdpOwnedInitialFrameBackpressureFailure": {
        "sessionPhase": "failed", "failureCode": "frameBackpressure",
    },
    "com.ersingundem.larenor.rdp.RdpOwnedInitialFramebufferUnavailable": {
        "sessionPhase": "failed", "failureCode": "framebufferUnavailable",
    },
    "com.ersingundem.larenor.rdp.RdpOwnedInitialFrameStaleSession": {
        "sessionPhase": "failed", "failureCode": "staleSession",
    },
    "com.ersingundem.larenor.rdp.RdpOwnedInitialFrameCancelled": {
        "sessionPhase": "cancelled", "failureCode": None,
    },
}
_INITIAL_FRAME_FAILURE_KINDS = {
    "com.ersingundem.larenor.rdp.RdpOwnedInitialFrameTerminalFailure":
        "terminal",
    **{exception_type: "terminal"
       for exception_type in _INITIAL_FRAME_TERMINAL_EXCEPTIONS},
    "com.ersingundem.larenor.rdp.RdpOwnedInitialFrameNoCallbackFailure":
        "noCallback",
    "com.ersingundem.larenor.rdp.RdpOwnedInitialFrameSizeMismatchFailure":
        "sizeMismatch",
    "com.ersingundem.larenor.rdp.RdpOwnedInitialFrameStalledAfterCallbackFailure":
        "stalledAfterCallback",
}
_TEST_BODY_FAILURE_TYPE = (
    "com.ersingundem.larenor.rdp.RdpOwnedTestBodyFailure"
)
_TEST_BODY_THROWABLE_TYPES = frozenset({
    "com.ersingundem.larenor.rdp.RdpNativeFailure",
    "java.lang.AssertionError",
    "java.lang.ClassNotFoundException",
    "java.lang.ExceptionInInitializerError",
    "java.lang.IllegalStateException",
    "java.lang.InterruptedException",
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
    "unclassified",
})
_TEST_BODY_MARKER = re.compile(
    r"^" + re.escape(_TEST_BODY_FAILURE_TYPE)
    + r": stage=(" + "|".join(map(re.escape, _TEST_LIFECYCLE_STAGES)) + r")"
    + r";throwable=(" + "|".join(map(re.escape, sorted(_TEST_BODY_THROWABLE_TYPES)))
    + r")$"
)
_OPEN_BOOLEAN_KEYS = (
    "connectionInfoParsed", "connectAccepted", "certificateAccepted",
    "authenticatedConnectionSucceeded", "displayCapsObserved",
    "initialLayoutAccepted", "securityPublished",
)
_OPEN_TERMINALS = frozenset({
    "candidateCreateFailure", "localSetupRejected", "connectionFailureCallback",
    "disconnectedCallback", "retired", "timeout",
})
_OPEN_STAGES = frozenset({"firstSessionOpen", "secondSessionOpen"})
_NATIVE_FAILURE_TYPE = "com.ersingundem.larenor.rdp.RdpNativeFailure"


def _valid_open_boundaries(value: object) -> bool:
    return (
        type(value) is dict
        and set(value) == {*_OPEN_BOOLEAN_KEYS, "terminal", "timeout", "safeCode"}
        and all(type(value[key]) is bool for key in _OPEN_BOOLEAN_KEYS)
        and type(value["timeout"]) is bool
        and type(value["terminal"]) is str
        and value["terminal"] in _OPEN_TERMINALS
        and value["timeout"] == (value["terminal"] == "timeout")
        and type(value["safeCode"]) is str
        and value["safeCode"] in {"connectionFailed", "engineUnavailable"}
    )


_CLASSIFICATION_SOURCE_SHA256 = (
    "6fa2825ecb455cf30dc1d4412bc75cc30a1417df0a3029862dbc66e193daeaa0"
)
_ACCEPTANCE_STAGES = {
    **{exception_type: "initialFrameWait"
       for exception_type in _INITIAL_FRAME_FAILURE_KINDS},
    _TEST_BODY_FAILURE_TYPE: "testBody",
    "com.ersingundem.larenor.rdp.RdpOwnedResizedFrameWaitFailure":
        "resizedFrameWait",
    "com.ersingundem.larenor.rdp.RdpOwnedResizedFramePixelsFailure":
        "resizedFramePixels",
    "com.ersingundem.larenor.rdp.RdpOwnedResizedFrameAckFailure":
        "resizedFrameAck",
    "com.ersingundem.larenor.rdp.RdpOwnedCleanCloseFailure":
        "cleanClose",
    "com.ersingundem.larenor.rdp.RdpOwnedCredentialClearFailure":
        "credentialClear",
    "com.ersingundem.larenor.rdp.RdpOwnedClientDispSubmissionFailure":
        "clientDispSubmission",
    "com.ersingundem.larenor.rdp.RdpOwnedClipboardSubmissionFailure":
        "clipboardSubmission",
    "com.ersingundem.larenor.rdp.RdpOwnedClipboardEffectWaitFailure":
        "clipboardEffectWait",
    "com.ersingundem.larenor.rdp.RdpOwnedDisabledClipboardFailure":
        "disabledClipboard",
}
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
}) | frozenset(_ACCEPTANCE_STAGES)
_OWNED_FRAME = re.compile(
    r"\s*at (com\.ersingundem\.larenor\.rdp\.[A-Za-z0-9_.$]+"
    r"\.(?:[A-Za-z0-9_$]+|<init>|<clinit>))"
    r"\(([A-Za-z][A-Za-z0-9_]{0,127}\.(?:kt|java)):(\d{1,6})\)\s*"
)
_ACCEPTANCE_STAGE_FRAME = re.compile(
    r"\s*at com\.ersingundem\.larenor\.rdp\.RdpPackagedHostAcceptanceTest\."
    + re.escape(TEST_NAME)
    + r"\(RdpPackagedHostAcceptanceTest\.kt:\d{1,6}\)\s*"
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
_CLASSIFICATION_SOURCE = (
    ROOT
    / "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp"
    / "RdpPackagedHostAcceptanceTest.kt"
)


def _classification_source_matches() -> bool:
    try:
        metadata = _CLASSIFICATION_SOURCE.lstat()
        if not stat.S_ISREG(metadata.st_mode) or not 1 <= metadata.st_size <= 256 * 1024:
            return False
        digest = hashlib.sha256(
            _CLASSIFICATION_SOURCE.read_bytes(),
        ).hexdigest()
    except OSError:
        return False
    return digest == _CLASSIFICATION_SOURCE_SHA256


def _terminal_classification_source_matches() -> bool:
    return _classification_source_matches()


class AcceptanceFailure(RuntimeError):
    pass


class BaselineFailure(AcceptanceFailure):
    def __init__(self, code: str, message: str):
        if code not in {
            "host_keyboard_witness_missing", "host_resize_unavailable",
            "host_channel_fixture_unavailable", "host_channel_witness_invalid",
        }:
            raise ValueError("invalid owned baseline failure code")
        super().__init__(message)
        self.code = code
        self.server_resize_requested: bool | None = None


def _owned_shadow_process_status(
    process: subprocess.Popen[bytes] | None,
    *,
    timed_out: bool = False,
) -> dict[str, object]:
    """Return one closed, non-payload process observation.

    This deliberately does not inspect stdout/stderr or infer why the process
    stopped. Negative return codes prove only signal termination; the sender
    and cause remain unknown. Missing and out-of-range observations stay
    unknown.
    """
    if process is None:
        return {"state": "unknown", "exitCode": None}
    try:
        status = process.poll()
    except (OSError, RuntimeError):
        return {"state": "unknown", "exitCode": None}
    if status is None:
        return {
            "state": "timedOut" if timed_out else "live",
            "exitCode": None,
        }
    if type(status) is not int or not -255 <= status <= 255:
        return {"state": "unknown", "exitCode": None}
    if status < 0:
        return {"state": "signalled", "exitCode": status}
    return {"state": "exited", "exitCode": status}


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
    channel_evidence: dict[str, object],
) -> dict[str, object]:
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise AcceptanceFailure("packaged RDP source revision is unavailable")
    if _DIGEST.fullmatch(package_digest) is None:
        raise AcceptanceFailure("packaged RDP receipt digest is unavailable")
    if (
        type(channel_evidence) is not dict
        or set(channel_evidence) != {
            "enabledClientToRemoteClipboard",
            "enabledDisplayControl",
            "disabledClipboardTransfers",
            "enabledRemoteAudioPackets",
            "disabledRemoteAudioPackets",
            "audioWaveConfirmations",
            "authenticatedLifetimes",
            "enabledMicrophoneTonePackets",
            "disabledMicrophonePackets",
            "shadowBinarySha256",
        }
        or channel_evidence["enabledClientToRemoteClipboard"] is not True
        or channel_evidence["enabledDisplayControl"] is not True
        or channel_evidence["disabledClipboardTransfers"] != 0
        or channel_evidence["enabledRemoteAudioPackets"] != 1
        or channel_evidence["disabledRemoteAudioPackets"] != 0
        or type(channel_evidence["audioWaveConfirmations"]) is not int
        or not 0 <= channel_evidence["audioWaveConfirmations"] <= 8
        or type(channel_evidence["enabledMicrophoneTonePackets"]) is not int
        or not 1 <= channel_evidence["enabledMicrophoneTonePackets"] <= 60000
        or type(channel_evidence["disabledMicrophonePackets"]) is not int
        or channel_evidence["disabledMicrophonePackets"] != 0
        or channel_evidence["authenticatedLifetimes"] != 2
        or type(channel_evidence["shadowBinarySha256"]) is not str
        or _DIGEST.fullmatch(channel_evidence["shadowBinarySha256"]) is None
    ):
        raise AcceptanceFailure("owned RDP channel evidence is unavailable")
    return {
        "schemaVersion": 1,
        "sourceRevision": revision,
        "packageReceiptSha256": package_digest,
        "testClass": TEST_CLASS,
        "testName": TEST_NAME,
        "ownedHostPackages": package_versions,
        "ownedShadowFixture": {
            "version": SHADOW_SOURCE_VERSION,
            "sourceCommit": SHADOW_SOURCE_COMMIT,
            "sourceArchiveSha256": SHADOW_SOURCE_SHA256,
            "patchSha256": SHADOW_PATCH_SHA256,
            "audioPatchSha256": SHADOW_AUDIO_PATCH_SHA256,
            "microphonePatchSha256": SHADOW_MICROPHONE_PATCH_SHA256,
        },
        "scope": "ownedShadowChannelsAudioAndMicrophone",
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
            "channels": channel_evidence,
            "remoteAudioQueueCompletion": True,
            "microphoneToneReceivedByHost": True,
            "cleanClose": True,
        },
        "unsupportedOrUnproven": [
            "ime", "remoteToClientClipboard", "physicalAudioAudibility", "physicalMicrophoneQuality",
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
    declared_type = element.attrib.get("type", "")
    raw_type = declared_type
    text = "".join(element.itertext())
    first = text.splitlines()[0].strip() if text.splitlines() else ""
    header_type = first.split(":", 1)[0]
    if raw_type not in _KNOWN_EXCEPTION_TYPES:
        raw_type = (
            header_type if header_type in _KNOWN_EXCEPTION_TYPES
            else "unclassified"
        )
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
    stage_type = (
        declared_type if declared_type in _ACCEPTANCE_STAGES
        else header_type if not declared_type and header_type in _ACCEPTANCE_STAGES
        else None
    )
    acceptance_stage = _ACCEPTANCE_STAGES.get(stage_type)
    test_body_failure: dict[str, str] | None = None
    if acceptance_stage is not None and not (
            code == "instrumentation_test_failure"
            and _ACCEPTANCE_STAGE_FRAME.search(text) is not None):
        # Merely placing a known class name in an untrusted report must not
        # upgrade a failure. The original exact test and its owned source frame
        # are both required for a bounded stage classification.
        raw_type = "unclassified"
        acceptance_stage = None
    elif acceptance_stage is not None:
        raw_type = stage_type
        if stage_type == _TEST_BODY_FAILURE_TYPE:
            marker = _TEST_BODY_MARKER.fullmatch(first)
            if marker is None or not _classification_source_matches():
                raw_type = "unclassified"
                acceptance_stage = None
            else:
                test_body_failure = {
                    "lifecycleStage": marker.group(1),
                    "throwableClass": marker.group(2),
                }
    elif raw_type in _ACCEPTANCE_STAGES:
        # A stage class found outside the actual connected-test shapes (an
        # exact declared type, or an absent type plus first throwable header)
        # is untrusted message content.
        raw_type = "unclassified"
    diagnostic = {
        "code": code,
        "exceptionType": raw_type,
        "frames": frames,
        "counts": counts,
    }
    if acceptance_stage is not None:
        diagnostic["acceptanceStage"] = acceptance_stage
    if test_body_failure is not None:
        diagnostic["testBodyFailure"] = test_body_failure
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
    has_resize_requested = "serverResizeRequested" in diagnostic
    resize_requested = diagnostic.get("serverResizeRequested")
    has_test_lifecycle_stage = "testLifecycleStage" in diagnostic
    test_lifecycle_stage = diagnostic.get("testLifecycleStage")
    has_initial_frame_observation = "initialFrameObservation" in diagnostic
    initial_frame_observation = diagnostic.get("initialFrameObservation")
    has_initial_frame_terminal = "initialFrameTerminal" in diagnostic
    initial_frame_terminal = diagnostic.get("initialFrameTerminal")
    has_test_body_failure = "testBodyFailure" in diagnostic
    test_body_failure = diagnostic.get("testBodyFailure")
    has_owned_body_failure = "ownedBodyFailure" in diagnostic
    owned_body_failure = diagnostic.get("ownedBodyFailure")
    has_marker_availability = "ownedMarkerAvailability" in diagnostic
    marker_availability = diagnostic.get("ownedMarkerAvailability")
    has_shadow_process = "ownedShadowProcess" in diagnostic
    shadow_process = diagnostic.get("ownedShadowProcess")
    has_open_boundaries = "openBoundaries" in diagnostic
    open_boundaries = diagnostic.get("openBoundaries")
    diagnostic_shape = set(diagnostic) - {
        "serverResizeRequested", "testLifecycleStage", "initialFrameObservation",
        "initialFrameTerminal", "testBodyFailure", "ownedBodyFailure",
        "ownedMarkerAvailability", "ownedShadowProcess", "openBoundaries",
    }
    if ((has_resize_requested and type(resize_requested) is not bool)
            or (has_test_lifecycle_stage
                and test_lifecycle_stage not in _TEST_LIFECYCLE_STAGE_SET)
            or (has_initial_frame_observation
                and initial_frame_observation is None)
            or diagnostic_shape not in ({"code", "exceptionType", "frames"}, {
            "code", "exceptionType", "frames", "counts"}, {
            "code", "exceptionType", "frames", "counts", "identity"}, {
            "code", "exceptionType", "frames", "counts", "probeOutcome"}, {
            "code", "exceptionType", "frames", "counts", "acceptanceStage"}, {
            "code", "exceptionType", "frames", "reportShape", "childSuiteCount"})):
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    if has_marker_availability:
        if (type(marker_availability) is not dict
                or set(marker_availability) != {"channel", "record", "writer"}
                or marker_availability["channel"] not in {"available", "unavailable"}
                or marker_availability["record"] not in {
                    "observed", "absent", "invalid", "readUnavailable",
                }
                or marker_availability["writer"] not in {"observed", "unknown"}
                or (marker_availability["writer"] == "observed")
                != (marker_availability["record"] == "observed")):
            raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    if has_shadow_process:
        if (not _classification_source_matches()
                or type(shadow_process) is not dict
                or set(shadow_process) != {"state", "exitCode"}):
            raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
        shadow_state = shadow_process["state"]
        shadow_code = shadow_process["exitCode"]
        if (shadow_state not in {
                "live", "exited", "timedOut", "signalled", "unknown",
        } or (shadow_state == "exited" and (
                type(shadow_code) is not int or not 0 <= shadow_code <= 255
        )) or (shadow_state == "signalled" and (
                type(shadow_code) is not int or not -255 <= shadow_code < 0
        )) or (shadow_state in {"live", "timedOut", "unknown"}
               and shadow_code is not None)):
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
    acceptance_stage = diagnostic.get("acceptanceStage")
    if has_owned_body_failure:
        if (not has_marker_availability
                or marker_availability != {
                    "channel": "available", "record": "observed",
                    "writer": "observed",
                }
                or code != "instrumentation_test_failure"
                or counts != {
                    "tests": 1, "skipped": 0, "failures": 1, "errors": 0,
                }
                or not _classification_source_matches()
                or type(owned_body_failure) is not dict
                or set(owned_body_failure) != {
                    "lifecycleStage", "throwableClass",
                }
                or owned_body_failure["lifecycleStage"]
                not in _TEST_LIFECYCLE_STAGE_SET
                or owned_body_failure["throwableClass"]
                not in _TEST_BODY_THROWABLE_TYPES):
            raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    expected_stage = _ACCEPTANCE_STAGES.get(exception_type)
    if ((acceptance_stage is None) != (expected_stage is None)
            or acceptance_stage is not None and (
                code != "instrumentation_test_failure"
                or acceptance_stage != expected_stage
                or not any(
                    frame["file"] == "RdpPackagedHostAcceptanceTest.kt"
                    for frame in frames
                ))):
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    if has_test_body_failure:
        if (exception_type != _TEST_BODY_FAILURE_TYPE
                or acceptance_stage != "testBody"
                or not _classification_source_matches()
                or type(test_body_failure) is not dict
                or set(test_body_failure) != {
                    "lifecycleStage", "throwableClass",
                }
                or test_body_failure["lifecycleStage"]
                not in _TEST_LIFECYCLE_STAGE_SET
                or test_body_failure["throwableClass"]
                not in _TEST_BODY_THROWABLE_TYPES):
            raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    elif exception_type == _TEST_BODY_FAILURE_TYPE:
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    if has_open_boundaries and (
            not _valid_open_boundaries(open_boundaries)
            or not has_test_body_failure
            or not has_owned_body_failure
            or test_body_failure != owned_body_failure
            or test_body_failure["lifecycleStage"] not in _OPEN_STAGES
            or test_body_failure["throwableClass"] != _NATIVE_FAILURE_TYPE
            or counts != {"tests": 1, "failures": 1, "errors": 0, "skipped": 0}
            or not _classification_source_matches()):
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    initial_kind = _INITIAL_FRAME_FAILURE_KINDS.get(exception_type)
    if has_initial_frame_observation and (
            initial_kind is None
            or test_lifecycle_stage != "initialFrameWait"
            or not _valid_initial_frame_observation(
                initial_kind, initial_frame_observation,
            )):
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    expected_terminal = _INITIAL_FRAME_TERMINAL_EXCEPTIONS.get(exception_type)
    if expected_terminal is not None:
        if (not _terminal_classification_source_matches()
                or not has_initial_frame_terminal
                or initial_frame_terminal != expected_terminal):
            raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
        if has_initial_frame_observation and (
                initial_frame_observation["sessionPhase"]
                != expected_terminal["sessionPhase"]
                or initial_frame_observation["failureCode"]
                != expected_terminal["failureCode"]):
            raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
    elif has_initial_frame_terminal:
        raise AcceptanceFailure("packaged RDP public diagnostics are invalid")
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
        "ownedShadowFixture": {
            "version": SHADOW_SOURCE_VERSION,
            "sourceCommit": SHADOW_SOURCE_COMMIT,
            "sourceArchiveSha256": SHADOW_SOURCE_SHA256,
            "patchSha256": SHADOW_PATCH_SHA256,
            "audioPatchSha256": SHADOW_AUDIO_PATCH_SHA256,
            "microphonePatchSha256": SHADOW_MICROPHONE_PATCH_SHA256,
        },
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
    channel_evidence: dict[str, object],
) -> Path:
    revision, package_digest = _provenance()
    receipt = acceptance_receipt(
        package_versions,
        revision=revision,
        package_digest=package_digest,
        channel_evidence=channel_evidence,
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
    server_resize_requested: bool | None = None,
    test_lifecycle_stage: str | None = None,
    owned_marker_evidence: _OwnedMarkerEvidence | None = None,
    owned_shadow_process: dict[str, object] | None = None,
) -> None:
    diagnostic = (failure_diagnostic() if code is None
                  else _static_diagnostic(code))
    if owned_marker_evidence is not None:
        diagnostic = _apply_owned_marker_evidence(
            diagnostic, owned_marker_evidence,
        )
    if owned_shadow_process is not None:
        diagnostic["ownedShadowProcess"] = owned_shadow_process
    exception_type = diagnostic.get("exceptionType")
    terminal = _INITIAL_FRAME_TERMINAL_EXCEPTIONS.get(exception_type)
    if terminal is not None:
        if _terminal_classification_source_matches():
            diagnostic["initialFrameTerminal"] = dict(terminal)
        else:
            diagnostic["exceptionType"] = "unclassified"
            diagnostic.pop("acceptanceStage", None)
    if server_resize_requested is not None:
        diagnostic["serverResizeRequested"] = server_resize_requested
    if test_lifecycle_stage is not None:
        diagnostic["testLifecycleStage"] = test_lifecycle_stage
        observation = getattr(
            test_lifecycle_stage, "initial_frame_observation", None,
        )
        if (observation is None
                and owned_marker_evidence is not None
                and owned_marker_evidence.channel == "available"
                and owned_marker_evidence.record == "observed"
                and owned_marker_evidence.writer == "observed"
                and owned_marker_evidence.stage == test_lifecycle_stage):
            observation = owned_marker_evidence.initial_frame_observation
        kind = _INITIAL_FRAME_FAILURE_KINDS.get(
            diagnostic.get("exceptionType"),
        )
        if (observation is not None
                and _classification_source_matches()
                and _valid_initial_frame_observation(kind, observation)):
            diagnostic["initialFrameObservation"] = observation
    publish_public_failure(diagnostic, runner_temp, package_versions)


def _adb_path() -> Path | None:
    root_value = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if not root_value:
        return None
    root = Path(root_value)
    adb = root / "platform-tools/adb"
    try:
        root_metadata = root.lstat()
        adb_metadata = adb.lstat()
        resolved_root = root.resolve(strict=True)
        resolved_adb = adb.resolve(strict=True)
    except (OSError, RuntimeError):
        return None
    if (not stat.S_ISDIR(root_metadata.st_mode)
            or not stat.S_ISREG(adb_metadata.st_mode)
            or resolved_adb.parent != resolved_root / "platform-tools"
            or not os.access(resolved_adb, os.X_OK)):
        return None
    return resolved_adb


def _test_lifecycle_filename(nonce: str) -> str:
    if _DIAGNOSTIC_NONCE.fullmatch(nonce) is None:
        raise ValueError("invalid packaged RDP diagnostic nonce")
    return f"files/f62-owned-stage-{nonce}"


def _owned_effect_control_filename(nonce: str, phase: str) -> str:
    if _DIAGNOSTIC_NONCE.fullmatch(nonce) is None:
        raise ValueError("invalid packaged RDP effect-control nonce")
    if phase not in _EFFECT_CONTROL_PHASE_CODES:
        raise ValueError("invalid packaged RDP effect-control phase")
    return f"files/f62-owned-arm-{nonce}-{phase}"


def _owned_effect_control_record(
    nonce: str,
    phase: str,
    source_sha256: str,
) -> bytes:
    _owned_effect_control_filename(nonce, phase)
    if _DIGEST.fullmatch(source_sha256) is None:
        raise ValueError("invalid packaged RDP effect-control source")
    record = b"".join((
        _EFFECT_CONTROL_MAGIC,
        _EFFECT_CONTROL_PHASE_CODES[phase],
        nonce.encode("ascii"),
        source_sha256.encode("ascii"),
        _OWNED_TEST_DIGEST.encode("ascii"),
    ))
    if len(record) != _EFFECT_CONTROL_BYTES:
        raise AssertionError("invalid packaged RDP effect-control record")
    return record


def _decode_owned_effect_control_record(
    record: bytes,
    *,
    nonce: str,
    phase: str,
    source_sha256: str,
) -> str | None:
    try:
        expected = _owned_effect_control_record(nonce, phase, source_sha256)
    except ValueError:
        return None
    return phase if record == expected else None


class _OwnedEffectControlPhases:
    """Accept the two exact one-shot effect controls in causal order."""

    def __init__(self) -> None:
        self._accepted: list[str] = []

    @property
    def accepted(self) -> tuple[str, ...]:
        return tuple(self._accepted)

    def accept(self, phase: str) -> str:
        if phase in self._accepted:
            raise BaselineFailure(
                "host_channel_witness_invalid",
                "owned effect control was replayed",
            )
        expected = (
            "audio" if not self._accepted
            else "microphone" if self._accepted == ["audio"]
            else None
        )
        if phase != expected:
            raise BaselineFailure(
                "host_channel_witness_invalid",
                "owned effect control order was invalid",
            )
        self._accepted.append(phase)
        return phase


def _read_owned_effect_control_file(
    nonce: str,
    phase: str,
    *,
    deadline: float,
) -> bytes | None:
    filename = _owned_effect_control_filename(nonce, phase)
    adb = _adb_path()
    if adb is None:
        return None
    prefix = _test_lifecycle_adb_prefix(adb)
    if prefix is None:
        return None

    def invoke(arguments: list[str]) -> subprocess.CompletedProcess[bytes] | None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            return subprocess.run(
                [*prefix, "exec-out", "run-as", _TEST_PACKAGE, *arguments],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=remaining,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None

    exists = invoke(["test", "-e", filename])
    if exists is None or exists.returncode == 1:
        return None
    if exists.returncode != 0:
        return None
    result = invoke(["dd", f"if={filename}", "bs=209", "count=1"])
    if result is None or result.returncode != 0:
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned effect control could not be read",
        )
    return result.stdout


def _poll_owned_effect_control(
    nonce: str,
    phases: _OwnedEffectControlPhases,
    *,
    timeout: float = 0.5,
) -> str | None:
    """Consume at most one exact control without consulting diagnostics."""
    if not _classification_source_matches():
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned effect control source was unavailable",
        )
    deadline = time.monotonic() + max(0.0, timeout)
    records = {
        phase: _read_owned_effect_control_file(
            nonce, phase, deadline=deadline,
        )
        for phase in _EFFECT_CONTROL_PHASE_CODES
    }
    present = [phase for phase, record in records.items() if record is not None]
    if not present:
        return None
    expected = "audio" if not phases.accepted else "microphone"
    if present != [expected]:
        # Simultaneous first controls, a retained prior record, or a repeated
        # phase are all non-causal. None may arm a host effect.
        candidate = present[0]
        phases.accept(candidate)
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned effect control order was invalid",
        )
    raw = records[expected]
    if raw is None or _decode_owned_effect_control_record(
        raw,
        nonce=nonce,
        phase=expected,
        source_sha256=_CLASSIFICATION_SOURCE_SHA256,
    ) is None:
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned effect control record was invalid",
        )
    accepted = phases.accept(expected)
    filename = _owned_effect_control_filename(nonce, expected)
    adb = _adb_path()
    prefix = None if adb is None else _test_lifecycle_adb_prefix(adb)
    if prefix is None:
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned effect control could not be consumed",
        )
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned effect control could not be consumed",
        )
    try:
        removed = subprocess.run(
            [*prefix, "shell", "run-as", _TEST_PACKAGE, "rm", "-f", filename],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=remaining,
        )
    except (OSError, subprocess.TimeoutExpired):
        removed = None
    if removed is None or removed.returncode != 0:
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned effect control could not be consumed",
        )
    return accepted


class _ObservedLifecycleStage(str):
    def __new__(
        cls,
        stage: str,
        observation: dict[str, object],
    ) -> _ObservedLifecycleStage:
        value = str.__new__(cls, stage)
        value.initial_frame_observation = observation
        return value


class _ObservedBodyFailure(str):
    def __new__(
        cls,
        stage: str,
        throwable_class: str,
    ) -> _ObservedBodyFailure:
        value = str.__new__(cls, stage)
        value.body_failure = {
            "lifecycleStage": stage,
            "throwableClass": throwable_class,
        }
        return value


class _ObservedOpenFailure(_ObservedBodyFailure):
    def __new__(cls, stage: str, boundaries: dict[str, object]):
        value = super().__new__(cls, stage, _NATIVE_FAILURE_TYPE)
        value.open_boundaries = boundaries
        return value


@dataclass(frozen=True)
class _OwnedMarkerEvidence:
    channel: str
    record: str
    writer: str
    stage: str | None = None
    body_failure: dict[str, str] | None = None
    initial_frame_observation: dict[str, object] | None = None
    open_boundaries: dict[str, object] | None = None
    conflict: bool = False

    def availability(self) -> dict[str, str]:
        return {
            "channel": self.channel,
            "record": self.record,
            "writer": self.writer,
        }


def _merge_owned_marker_evidence(
    previous: _OwnedMarkerEvidence,
    observed: _OwnedMarkerEvidence,
    *,
    writer_quiesced: bool = False,
) -> _OwnedMarkerEvidence:
    if previous.conflict:
        return previous
    if observed.record == "invalid":
        # A live AtomicFile writer can expose a transient empty/partial read.
        # Never publish that read as a fact or erase an earlier complete fact.
        # The final read after Gradle exits still rejects malformed storage.
        if writer_quiesced or previous.record != "observed":
            return observed
        return previous
    if observed.record == "observed":
        if (previous.body_failure is not None
                and (previous.stage != observed.stage
                     or previous.body_failure != observed.body_failure)
                or previous.open_boundaries is not None
                and previous.open_boundaries != observed.open_boundaries):
            return _OwnedMarkerEvidence("available", "invalid", "unknown", conflict=True)
        return observed
    if previous.record == "observed":
        return previous
    if observed.channel == "available" or previous.channel != "available":
        return observed
    return previous


def _valid_initial_frame_observation(
    kind: str | None,
    observation: object,
) -> bool:
    if type(observation) is not dict or set(observation) != {
        "callbackCount", "callbackCountCapped", "lastFrame",
        "sessionPhase", "failureCode",
    }:
        return False
    callback_count = observation["callbackCount"]
    capped = observation["callbackCountCapped"]
    last_frame = observation["lastFrame"]
    phase = observation["sessionPhase"]
    failure_code = observation["failureCode"]
    if (type(callback_count) is not int or not 0 <= callback_count <= 4096
            or type(capped) is not bool
            or capped != (callback_count == 4096)
            or phase not in {"active", "awaitingFrameAck", "failed", "cancelled"}
            or failure_code not in {
                None, "connectionFailed", "frameBackpressure",
                "framebufferUnavailable", "staleSession",
            }):
        return False
    if last_frame is not None and (
            type(last_frame) is not dict
            or set(last_frame) != {"width", "height"}
            or any(type(last_frame[key]) is not int
                   or not 1 <= last_frame[key] <= 8192
                   for key in ("width", "height"))):
        return False
    if kind == "terminal":
        return (
            phase == "failed" and failure_code is not None
            or phase == "cancelled" and failure_code is None
        )
    if phase not in {"active", "awaitingFrameAck"} or failure_code is not None:
        return False
    if kind == "noCallback":
        return callback_count == 0 and not capped and last_frame is None and phase == "active"
    if kind == "sizeMismatch":
        return (
            callback_count > 0 and last_frame is not None
            and (last_frame["width"], last_frame["height"]) != _SOURCE_DIMENSIONS
        )
    if kind == "stalledAfterCallback":
        return callback_count > 0 and last_frame is None
    return False


def _decode_test_lifecycle_marker(
    raw: bytes,
) -> tuple[str | None, dict[str, object] | None]:
    try:
        value = raw.decode("ascii").strip()
    except UnicodeDecodeError:
        return None, None
    parts = value.split("|")
    if len(parts) == 7 and parts[:2] == ["openFailure", "v1"]:
        if raw != value.encode("ascii"):
            return None, None
        _, _, stage, safe_code, bits, terminal, raw_timeout = parts
        if (stage not in _OPEN_STAGES or re.fullmatch(r"[01]{7}", bits) is None
                or raw_timeout not in {"0", "1"}):
            return None, None
        boundaries = {
            **dict(zip(_OPEN_BOOLEAN_KEYS, (bit == "1" for bit in bits))),
            "terminal": terminal, "timeout": raw_timeout == "1",
            "safeCode": safe_code,
        }
        if not _valid_open_boundaries(boundaries):
            return None, None
        return _ObservedOpenFailure(stage, boundaries), None
    if len(parts) == 4 and parts[:2] == ["bodyFailure", "v1"]:
        _, _, stage, throwable_class = parts
        if (stage not in _TEST_LIFECYCLE_STAGE_SET
                or throwable_class not in _TEST_BODY_THROWABLE_TYPES):
            return None, None
        return _ObservedBodyFailure(stage, throwable_class), None
    if value in _TEST_LIFECYCLE_STAGE_SET:
        return value, None
    if len(parts) != 9 or parts[0] != "initialFrameWait" or parts[1] != "v1":
        return None, None
    _, _, kind, raw_count, raw_capped, raw_width, raw_height, phase, raw_code = parts
    if kind not in set(_INITIAL_FRAME_FAILURE_KINDS.values()):
        return None, None
    try:
        callback_count = int(raw_count)
        capped = {"0": False, "1": True}[raw_capped]
        if (raw_width == "-") != (raw_height == "-"):
            return None, None
        last_frame = None if raw_width == "-" else {
            "width": int(raw_width), "height": int(raw_height),
        }
    except (KeyError, ValueError):
        return None, None
    observation = {
        "callbackCount": callback_count,
        "callbackCountCapped": capped,
        "lastFrame": last_frame,
        "sessionPhase": phase,
        "failureCode": None if raw_code == "-" else raw_code,
    }
    if not _valid_initial_frame_observation(kind, observation):
        return None, None
    return "initialFrameWait", observation


def _test_lifecycle_adb_prefix(adb: Path) -> list[str] | None:
    serial = os.environ.get("ANDROID_SERIAL")
    if serial is None:
        return [str(adb)]
    if _ADB_SERIAL.fullmatch(serial) is None:
        return None
    return [str(adb), "-s", serial]


def _peek_test_lifecycle_stage(nonce: str, *, timeout: float = 5) -> str | None:
    """Read a fixed enum without consuming the marker or retaining raw output."""
    try:
        filename = _test_lifecycle_filename(nonce)
    except ValueError:
        return None
    adb = _adb_path()
    if adb is None:
        return None
    prefix = _test_lifecycle_adb_prefix(adb)
    if prefix is None:
        return None
    try:
        result = subprocess.run(
            [
                *prefix, "exec-out", "run-as", _TEST_PACKAGE,
                "dd", f"if={filename}", "bs=129", "count=1",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0 or len(result.stdout) > 128:
        return None
    stage, observation = _decode_test_lifecycle_marker(result.stdout)
    if stage is not None and observation is not None:
        return _ObservedLifecycleStage(stage, observation)
    return stage


def _read_owned_marker(
    nonce: str,
    *,
    timeout: float = 5,
) -> _OwnedMarkerEvidence:
    try:
        filename = _test_lifecycle_filename(nonce)
    except ValueError:
        return _OwnedMarkerEvidence("unavailable", "absent", "unknown")
    adb = _adb_path()
    if adb is None:
        return _OwnedMarkerEvidence("unavailable", "absent", "unknown")
    prefix = _test_lifecycle_adb_prefix(adb)
    if prefix is None:
        return _OwnedMarkerEvidence("unavailable", "absent", "unknown")
    deadline = time.monotonic() + max(0.0, timeout)

    def invoke(arguments: list[str]) -> subprocess.CompletedProcess[bytes] | None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            return subprocess.run(
                [*prefix, "exec-out", "run-as", _TEST_PACKAGE, *arguments],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=remaining,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None

    channel = invoke(["true"])
    if channel is None or channel.returncode != 0:
        return _OwnedMarkerEvidence("unavailable", "absent", "unknown")
    exists = invoke(["test", "-e", filename])
    if exists is None:
        return _OwnedMarkerEvidence("available", "readUnavailable", "unknown")
    if exists.returncode == 1:
        return _OwnedMarkerEvidence("available", "absent", "unknown")
    if exists.returncode != 0:
        return _OwnedMarkerEvidence("available", "readUnavailable", "unknown")
    result = invoke(["dd", f"if={filename}", "bs=129", "count=1"])
    if result is None or result.returncode != 0:
        return _OwnedMarkerEvidence("available", "readUnavailable", "unknown")
    if not result.stdout or len(result.stdout) > 128:
        return _OwnedMarkerEvidence("available", "invalid", "unknown")
    stage, observation = _decode_test_lifecycle_marker(result.stdout)
    if stage is None:
        return _OwnedMarkerEvidence("available", "invalid", "unknown")
    body_failure = getattr(stage, "body_failure", None)
    observed_stage = str(stage)
    if observation is not None:
        observed_stage = str(_ObservedLifecycleStage(stage, observation))
    return _OwnedMarkerEvidence(
        "available", "observed", "observed",
        stage=observed_stage,
        body_failure=body_failure,
        initial_frame_observation=observation,
        open_boundaries=getattr(stage, "open_boundaries", None),
    )


def _apply_owned_marker_evidence(
    diagnostic: dict[str, object],
    evidence: _OwnedMarkerEvidence,
) -> dict[str, object]:
    updated = dict(diagnostic)
    updated["ownedMarkerAvailability"] = evidence.availability()
    exact_counts = {
        "tests": 1, "skipped": 0, "failures": 1, "errors": 0,
    }
    body_failure = evidence.body_failure
    serialized_body = diagnostic.get("testBodyFailure")
    serialized_stage = diagnostic.get("acceptanceStage")
    conflicts = body_failure is not None and (
        serialized_body is not None and serialized_body != body_failure
        or serialized_stage is not None and serialized_stage != "testBody"
    )
    if conflicts:
        updated["ownedMarkerAvailability"] = {
            "channel": "available", "record": "invalid", "writer": "unknown",
        }
        return updated
    if (diagnostic.get("code") == "instrumentation_test_failure"
            and diagnostic.get("counts") == exact_counts
            and evidence.channel == "available"
            and evidence.record == "observed"
            and evidence.writer == "observed"
            and body_failure is not None
            and evidence.stage == body_failure.get("lifecycleStage")
            and _classification_source_matches()):
        updated["ownedBodyFailure"] = dict(body_failure)
        if (serialized_body == body_failure
                and serialized_stage == "testBody"
                and diagnostic.get("exceptionType") == _TEST_BODY_FAILURE_TYPE
                and body_failure.get("lifecycleStage") in _OPEN_STAGES
                and body_failure.get("throwableClass") == _NATIVE_FAILURE_TYPE
                and _valid_open_boundaries(evidence.open_boundaries)):
            updated["openBoundaries"] = dict(evidence.open_boundaries)
    return updated


def _cleanup_test_lifecycle_stage(nonce: str) -> None:
    """Remove only this invocation's marker, after observation has stopped."""
    try:
        filename = _test_lifecycle_filename(nonce)
    except ValueError:
        return
    adb = _adb_path()
    if adb is None:
        return
    prefix = _test_lifecycle_adb_prefix(adb)
    if prefix is None:
        return
    try:
        subprocess.run(
            [
                *prefix, "shell", "run-as", _TEST_PACKAGE,
                "rm", "-f", filename, f"{filename}.new", f"{filename}.bak",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass


def _read_test_lifecycle_stage(nonce: str) -> str | None:
    try:
        return _peek_test_lifecycle_stage(nonce)
    finally:
        _cleanup_test_lifecycle_stage(nonce)


class _OwnedLifecycleObserver:
    """Cache only a nonce-bound enum while Gradle still owns the installed app.

    adb runs independently of the channel witness loop, whose phase deadlines
    must not wait for diagnostic I/O. A transient failed peek cannot erase a
    previously observed stage; absence remains unknown rather than acceptance.
    """

    def __init__(self, nonce: str):
        _test_lifecycle_filename(nonce)
        self._nonce = nonce
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._stage: str | None = None
        self._evidence = _OwnedMarkerEvidence(
            "unavailable", "absent", "unknown",
        )
        self._thread = threading.Thread(target=self._observe, daemon=True)

    def start(self) -> None:
        try:
            self._thread.start()
        except RuntimeError:
            # Resource exhaustion in a secondary observer is not test failure.
            pass

    def _observe(self) -> None:
        while not self._stop.is_set():
            try:
                evidence = _read_owned_marker(self._nonce, timeout=1)
            except Exception:
                # Diagnostic failures must never replace the owned test result.
                evidence = _OwnedMarkerEvidence(
                    "unavailable", "absent", "unknown",
                )
            with self._lock:
                if self._stop.is_set():
                    return
                self._evidence = _merge_owned_marker_evidence(
                    self._evidence, evidence,
                )
                self._stage = (
                    self._evidence.stage
                    if self._evidence.record == "observed" else None
                )
            if self._stop.is_set():
                return
            self._stop.wait(0.5)

    def last_stage(self) -> str | None:
        with self._lock:
            return self._stage

    def last_evidence(self) -> _OwnedMarkerEvidence:
        with self._lock:
            return self._evidence

    def stop(self) -> str | None:
        self._stop.set()
        if self._thread.ident is not None:
            try:
                self._thread.join(timeout=2)
            except RuntimeError:
                pass
        return self.last_stage()

    def observe_after_host_exit(
        self,
    ) -> tuple[str | None, _OwnedMarkerEvidence]:
        """Stop polling and make one final bounded read after host exit."""
        self.stop()
        if self._thread.is_alive():
            return self.last_stage(), self.last_evidence()
        try:
            observed = _read_owned_marker(self._nonce, timeout=1)
        except Exception:
            observed = _OwnedMarkerEvidence(
                "unavailable", "absent", "unknown",
            )
        with self._lock:
            self._evidence = _merge_owned_marker_evidence(
                self._evidence, observed, writer_quiesced=True,
            )
            self._stage = (
                self._evidence.stage
                if self._evidence.record == "observed" else None
            )
            return self._stage, self._evidence


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


def _owned_regular(
    path: Path,
    *,
    executable: bool = False,
    mode: int | None = None,
    max_size: int = 256 * 1024 * 1024,
) -> Path:
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture input was unavailable",
        ) from error
    actual_mode = stat.S_IMODE(metadata.st_mode)
    if (
        not path.is_absolute()
        or resolved != path
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > max_size
        or mode is not None and actual_mode != mode
        or executable and (
            actual_mode & stat.S_IXUSR == 0 or actual_mode & 0o022 != 0
        )
    ):
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture input was invalid",
        )
    return path


def _owned_regular_sha256(path: Path, *, max_size: int) -> str:
    try:
        before = path.lstat()
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        opened = os.fstat(fd)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or opened.st_nlink != 1
            or opened.st_size <= 0
            or opened.st_size > max_size
            or (before.st_dev, before.st_ino, before.st_size) !=
                (opened.st_dev, opened.st_ino, opened.st_size)
        ):
            raise OSError()
        digest = hashlib.sha256()
        remaining = opened.st_size
        while remaining:
            chunk = os.read(fd, min(1024 * 1024, remaining))
            if not chunk:
                raise OSError()
            digest.update(chunk)
            remaining -= len(chunk)
        after = path.lstat()
        if (after.st_dev, after.st_ino, after.st_size) != (
            opened.st_dev, opened.st_ino, opened.st_size,
        ):
            raise OSError()
        return digest.hexdigest()
    except OSError as error:
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture binary identity changed",
        ) from error
    finally:
        if "fd" in locals():
            os.close(fd)


def _append_private_log(fd: int, current_size: int, chunk: bytes) -> int:
    if not chunk or current_size + len(chunk) > _MAX_SHADOW_LOG_BYTES:
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture log exceeded its bound",
        )
    offset = 0
    while offset < len(chunk):
        written = os.write(fd, chunk[offset:])
        if written <= 0:
            raise BaselineFailure(
                "host_channel_fixture_unavailable",
                "owned channel fixture log was unavailable",
            )
        offset += written
    return current_size + len(chunk)


def _drain_shadow_output(
    stream_fd: int,
    log_fd: int,
    current_size: int,
) -> int:
    while True:
        try:
            chunk = os.read(stream_fd, 4096)
        except BlockingIOError:
            return current_size
        if not chunk:
            return current_size
        current_size = _append_private_log(log_fd, current_size, chunk)


def _server_resize_requested(path: Path) -> bool:
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or not 0 <= metadata.st_size <= _MAX_SHADOW_LOG_BYTES
        ):
            raise OSError()
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino, opened.st_size) != (
            metadata.st_dev, metadata.st_ino, metadata.st_size,
        ):
            raise OSError()
        chunks: list[bytes] = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(fd, min(64 * 1024, remaining))
            if not chunk:
                raise OSError()
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        return _SERVER_RESIZE_REQUESTED.search(data) is not None
    except OSError as error:
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture diagnostic log was invalid",
        ) from error
    finally:
        if "fd" in locals():
            os.close(fd)


def _owned_directory(path: Path, *, parent: Path) -> Path:
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
        resolved.relative_to(parent)
    except (OSError, RuntimeError, ValueError) as error:
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture directory was unavailable",
        ) from error
    if (
        resolved != path
        or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) & 0o022 != 0
    ):
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture directory was invalid",
        )
    return path


def _shadow_port_open() -> bool:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.settimeout(0.2)
        return probe.connect_ex(("127.0.0.1", _SHADOW_PORT)) == 0
    finally:
        probe.close()


def _wait_shadow_ready(
    process: subprocess.Popen[bytes],
    log_fd: int,
    *,
    timeout: float = 15,
) -> int:
    deadline = time.monotonic() + timeout
    size = 0
    while time.monotonic() < deadline:
        if process.stdout is not None:
            size = _drain_shadow_output(process.stdout.fileno(), log_fd, size)
        if process.poll() is not None:
            break
        if _shadow_port_open():
            return size
        time.sleep(0.05)
    raise BaselineFailure(
        "host_channel_fixture_unavailable",
        "owned channel fixture did not become ready",
    )


def _start_owned_shadow(
    runner_temp: Path,
    witness_base: Path,
    audio_witness_base: Path,
    diagnostic_nonce: str,
    microphone_witness_base: Path,
) -> tuple[subprocess.Popen[bytes], int, int, int, str, int, Path, int]:
    binary_raw = os.environ.get("RDP_ACCEPTANCE_SHADOW_BINARY", "")
    source_raw = os.environ.get("RDP_ACCEPTANCE_SHADOW_SOURCE", "")
    build_raw = os.environ.get("RDP_ACCEPTANCE_SHADOW_BUILD", "")
    source = _owned_directory(Path(source_raw), parent=runner_temp)
    build = _owned_directory(Path(build_raw), parent=runner_temp)
    binary = _owned_regular(Path(binary_raw), executable=True)
    if binary != build / SHADOW_CLI_RELATIVE or source == build:
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture binary layout was invalid",
        )
    try:
        verify_patched_source(source)
    except FixtureError:
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture source identity was invalid",
        ) from None
    binary_digest = _owned_regular_sha256(binary, max_size=256 * 1024 * 1024)
    sam = _owned_regular(
        runner_temp / "larenor-rdp.sam", mode=0o600, max_size=64 * 1024,
    )
    if (
        _shadow_port_open()
        or witness_base.exists()
        or any(Path(f"{witness_base}.{ordinal}").exists() for ordinal in (1, 2, 3))
        or microphone_witness_base.exists()
        or any(Path(f"{microphone_witness_base}.{ordinal}").exists() for ordinal in (1, 2, 3))
        or audio_witness_base.exists()
        or any(Path(f"{audio_witness_base}.{ordinal}").exists() for ordinal in (1, 2, 3))
    ):
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture state was not empty",
        )
    read_fd, write_fd = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
    audio_read_fd, audio_write_fd = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
    microphone_read_fd, microphone_write_fd = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
    log_path = witness_base.parent / "shadow.log"
    try:
        log_fd = os.open(
            log_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
    except OSError as error:
        os.close(read_fd)
        os.close(write_fd)
        os.close(audio_read_fd)
        os.close(audio_write_fd)
        os.close(microphone_read_fd)
        os.close(microphone_write_fd)
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture diagnostic log could not be created",
        ) from error
    environment = {
        key: os.environ[key]
        for key in ("HOME", "LANG", "LC_ALL", "LD_LIBRARY_PATH", "PATH", "TMPDIR")
        if key in os.environ
    }
    environment.update({
        "DISPLAY": _DISPLAY,
        "WLOG_LEVEL": "INFO",
        "LARENOR_F62_CHANNEL_WITNESS": str(witness_base),
        "LARENOR_F62_CHANNEL_PHASE_FD": str(write_fd),
        "LARENOR_F62_AUDIO_WITNESS": str(audio_witness_base),
        "LARENOR_F62_MICROPHONE_WITNESS": str(microphone_witness_base),
        "LARENOR_F62_MICROPHONE_ARM_FD": str(microphone_read_fd),
        "LARENOR_F62_AUDIO_ARM_FD": str(audio_read_fd),
        "LARENOR_F62_AUDIO_NONCE": diagnostic_nonce,
        "LARENOR_F62_EXPECT_WIDTH": str(_TARGET_DIMENSIONS[0]),
        "LARENOR_F62_EXPECT_HEIGHT": str(_TARGET_DIMENSIONS[1]),
    })
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            [
                str(binary),
                f"/port:{_SHADOW_PORT}",
                "/sec:nla",
                f"/sam-file:{sam}",
            ],
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            pass_fds=(write_fd, audio_read_fd, microphone_read_fd),
            start_new_session=True,
        )
        if _owned_regular_sha256(
            binary, max_size=256 * 1024 * 1024,
        ) != binary_digest:
            raise BaselineFailure(
                "host_channel_fixture_unavailable",
                "owned channel fixture binary changed during launch",
            )
        os.close(write_fd)
        write_fd = -1
        os.close(audio_read_fd)
        audio_read_fd = -1
        if process.stdout is None:
            raise BaselineFailure(
                "host_channel_fixture_unavailable",
                "owned channel fixture diagnostic pipe was unavailable",
            )
        os.set_blocking(process.stdout.fileno(), False)
        log_size = _wait_shadow_ready(process, log_fd)
        return process, read_fd, audio_write_fd, microphone_write_fd, binary_digest, log_fd, log_path, log_size
    except (OSError, subprocess.SubprocessError):
        if process is not None:
            _stop_owned_process(process)
        os.close(read_fd)
        os.close(audio_write_fd)
        os.close(microphone_write_fd)
        os.close(log_fd)
        raise BaselineFailure(
            "host_channel_fixture_unavailable",
            "owned channel fixture could not start",
        ) from None
    except BaseException:
        if process is not None:
            _stop_owned_process(process)
        os.close(read_fd)
        os.close(audio_write_fd)
        os.close(microphone_write_fd)
        os.close(log_fd)
        raise
    finally:
        if write_fd >= 0:
            os.close(write_fd)
        if audio_read_fd >= 0:
            os.close(audio_read_fd)
        os.close(microphone_read_fd)



def _acknowledge_microphone_effect(nonce: str) -> None:
    if _DIAGNOSTIC_NONCE.fullmatch(nonce) is None:
        raise BaselineFailure("host_channel_witness_invalid", "owned microphone identity invalid")
    adb = _adb_path()
    prefix = _test_lifecycle_adb_prefix(adb) if adb is not None else None
    if prefix is None:
        raise BaselineFailure("host_channel_witness_invalid", "owned microphone app unavailable")
    # Generated nonce is the only interpolated value. No shell credentials/provider text.
    command = f"umask 077; set -C; cat > files/f62-owned-microphone-{nonce}"
    try:
        result = subprocess.run([*prefix, "exec-in", "run-as", _TEST_PACKAGE, "sh", "-c", command],
            input=nonce.encode("ascii"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        raise BaselineFailure("host_channel_witness_invalid", "owned microphone acknowledgement failed") from None
    if result.returncode != 0:
        raise BaselineFailure("host_channel_witness_invalid", "owned microphone acknowledgement failed")


def _mark_clipboard_effect() -> None:
    try:
        result = subprocess.run(
            ["/usr/bin/xsetroot", "-solid", _CLIPBOARD_MARKER_COLOR],
            env={**os.environ, "DISPLAY": _DISPLAY},
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned clipboard display marker was unavailable",
        ) from error
    if result.returncode != 0:
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned clipboard display marker was not applied",
        )


def _arm_owned_audio(fd: int, diagnostic_nonce: str, *, magic: bytes = _AUDIO_ARM_MAGIC) -> None:
    if _DIAGNOSTIC_NONCE.fullmatch(diagnostic_nonce) is None:
        raise BaselineFailure(
            "host_channel_witness_invalid", "owned audio arm identity was invalid"
        )
    payload = magic + diagnostic_nonce.encode("ascii")
    if len(payload) != _AUDIO_ARM_BYTES:
        raise BaselineFailure(
            "host_channel_witness_invalid", "owned audio arm identity was invalid"
        )
    try:
        written = os.write(fd, payload)
    except OSError as error:
        raise BaselineFailure(
            "host_channel_witness_invalid", "owned audio arm could not be delivered"
        ) from error
    if written != len(payload):
        raise BaselineFailure(
            "host_channel_witness_invalid", "owned audio arm could not be delivered"
        )


def _channel_evidence(
    witness_base: Path,
    audio_witness_base: Path,
    microphone_witness_base: Path,
    *,
    timeout: float = 10,
) -> dict[str, object]:
    first = Path(f"{witness_base}.1")
    second = Path(f"{witness_base}.2")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and not (first.exists() and second.exists()):
        time.sleep(0.05)
    try:
        lifetimes = read_lifetimes(witness_base)
        enabled = lifetimes["enabled"]
        disabled = lifetimes["disabled"]
    except (FixtureError, OSError):
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned channel terminal witness was invalid",
        ) from None
    audio_first = Path(f"{audio_witness_base}.1")
    audio_second = Path(f"{audio_witness_base}.2")
    while time.monotonic() < deadline and not (audio_first.exists() and audio_second.exists()):
        time.sleep(0.05)
    try:
        audio = read_audio_lifetimes(audio_witness_base)
        audio_enabled = audio["enabled"]
        audio_disabled = audio["disabled"]
    except (FixtureError, OSError):
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned audio terminal witness was invalid",
        ) from None
    if not (
        enabled["schemaVersion"] == 2
        and disabled["schemaVersion"] == 2
        and enabled["initialDisplayAccepted"] is True
        and disabled["initialDisplayAccepted"] is True
        and enabled["clipboardEffect"] is True
        and enabled["displayEffect"] is True
        and enabled["emptyResponses"] == 0
        and enabled["channelErrors"] == 0
        and enabled["formatLists"] > 0
        and enabled["dataRequests"] > 0
        and enabled["dataResponses"] > 0
        and enabled["displayLayouts"] == 2
        and disabled["displayLayouts"] == 1
        and disabled["displayEffect"] is False
        and disabled["clipboardEffect"] is False
        and disabled["formatLists"] == 0
        and disabled["dataRequests"] == 0
        and disabled["dataResponses"] == 0
        and disabled["emptyResponses"] == 0
        and disabled["channelErrors"] == 0
    ):
        raise BaselineFailure(
            "host_channel_witness_invalid",
            "owned channel terminal witness did not prove both lifetimes",
        )
    try:
        microphone = read_microphone_lifetimes(microphone_witness_base)
    except (FixtureError, OSError):
        raise BaselineFailure("host_channel_witness_invalid",
            "owned microphone terminal witness did not prove both lifetimes") from None
    return {
        "enabledMicrophoneTonePackets": microphone["enabled"]["matchingPackets"],
        "disabledMicrophonePackets": microphone["disabled"]["packets"],
        "enabledClientToRemoteClipboard": True,
        "enabledDisplayControl": True,
        "disabledClipboardTransfers": 0,
        "enabledRemoteAudioPackets": audio_enabled["acceptedCount"],
        "disabledRemoteAudioPackets": audio_disabled["acceptedCount"],
        "audioWaveConfirmations": audio_enabled["waveConfirmations"],
        "authenticatedLifetimes": 2,
    }


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


def _run_owned_shadow_baseline(
    command: list[str],
    *,
    runner_temp: Path,
    diagnostic_nonce: str,
    timeout: float = 1200,
) -> tuple[
    int, dict[str, object] | None, bool | None, str | None,
    _OwnedMarkerEvidence, dict[str, object] | None,
]:
    """Run two authenticated lifetimes against one owned patched shadow host."""
    _test_lifecycle_filename(diagnostic_nonce)
    environment = {**os.environ, "DISPLAY": _DISPLAY}
    xinput: subprocess.Popen[bytes] | None = None
    gradle: subprocess.Popen[bytes] | None = None
    shadow: subprocess.Popen[bytes] | None = None
    phase_fd: int | None = None
    audio_arm_fd: int | None = None
    microphone_arm_fd: int | None = None
    microphone_tone: subprocess.Popen[bytes] | None = None
    shadow_log_fd: int | None = None
    shadow_log_path: Path | None = None
    shadow_log_size = 0
    lifecycle = _OwnedLifecycleObserver(diagnostic_nonce)
    selector = selectors.DefaultSelector()
    deadline = time.monotonic() + timeout
    host_gradle_exited = False
    host_exit_observed = False
    final_stage: str | None = None
    final_evidence = lifecycle.last_evidence()
    pending_error: BaseException | None = None
    with tempfile.TemporaryDirectory(
        prefix="larenor-f62-channels-", dir=runner_temp,
    ) as temporary:
        private = Path(temporary)
        private.chmod(0o700)
        witness_base = private / "terminal-witness"
        audio_witness_base = private / "audio-terminal-witness"
        microphone_witness_base = private / "microphone-terminal-witness"
        pulse_path = runner_temp / "larenor-rdp-microphone"
        try:
            verified_pulse(pulse_path)
        except (MicrophoneFixtureError, OSError):
            raise BaselineFailure("host_channel_fixture_unavailable",
                "isolated owned microphone source was unavailable") from None
        try:
            (
                shadow,
                phase_fd,
                audio_arm_fd,
                microphone_arm_fd,
                shadow_binary_digest,
                shadow_log_fd,
                shadow_log_path,
                shadow_log_size,
            ) = _start_owned_shadow(
                runner_temp,
                witness_base,
                audio_witness_base,
                diagnostic_nonce,
                microphone_witness_base,
            )
            selector.register(phase_fd, selectors.EVENT_READ, "phase")
            if shadow.stdout is None:
                raise BaselineFailure(
                    "host_channel_fixture_unavailable",
                    "owned channel fixture diagnostic pipe was unavailable",
                )
            selector.register(shadow.stdout, selectors.EVENT_READ, "shadow")
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
            selector.register(xinput.stdout, selectors.EVENT_READ, "xi2")
            gradle = subprocess.Popen(
                command,
                cwd=ROOT / "android",
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            lifecycle.start()
            key_witness = Xi2KeyWitness()
            xi2_buffer = b""
            xi2_bytes = 0
            phase_buffer = b""
            phases: list[bytes] = []
            resized = False
            clip_marked = False
            audio_armed = False
            microphone_armed = False
            microphone_acknowledged = False
            effect_controls = _OwnedEffectControlPhases()
            gradle_finished_at: float | None = None
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                gradle_status = gradle.poll()
                if gradle_status is not None:
                    host_gradle_exited = True
                    if gradle_status != 0:
                        shadow_log_size = _drain_shadow_output(
                            shadow.stdout.fileno(), shadow_log_fd, shadow_log_size,
                        )
                        os.fsync(shadow_log_fd)
                        final_stage, final_evidence = (
                            lifecycle.observe_after_host_exit()
                        )
                        host_exit_observed = True
                        return (
                            gradle_status,
                            None,
                            _server_resize_requested(shadow_log_path),
                            final_stage,
                            final_evidence,
                            _owned_shadow_process_status(shadow),
                        )
                    if (
                        key_witness.complete
                        and phases == _CHANNEL_PHASES
                        and phase_buffer == b""
                        and resized
                        and clip_marked
                        and audio_armed
                        and microphone_armed
                        and microphone_acknowledged
                    ):
                        evidence = _channel_evidence(witness_base, audio_witness_base, microphone_witness_base)
                        evidence["shadowBinarySha256"] = shadow_binary_digest
                        final_stage, final_evidence = (
                            lifecycle.observe_after_host_exit()
                        )
                        host_exit_observed = True
                        return (
                            0, evidence, None, None,
                            final_evidence,
                            None,
                        )
                    if gradle_finished_at is None:
                        gradle_finished_at = time.monotonic()
                    elif time.monotonic() - gradle_finished_at >= 5:
                        raise BaselineFailure(
                            "host_channel_witness_invalid",
                            "owned channel phases were incomplete",
                        )
                if xinput.poll() is not None:
                    raise BaselineFailure(
                        "host_keyboard_witness_missing",
                        "owned XI2 key witness stopped early",
                    )
                if shadow.poll() is not None:
                    raise BaselineFailure(
                        "host_channel_fixture_unavailable",
                        "owned channel fixture stopped early",
                    )
                for key, _ in selector.select(timeout=min(0.25, remaining)):
                    try:
                        chunk = os.read(key.fd, 4096)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        raise BaselineFailure(
                            "host_channel_witness_invalid",
                            "owned channel witness closed early",
                        )
                    if key.data == "shadow":
                        shadow_log_size = _append_private_log(
                            shadow_log_fd, shadow_log_size, chunk,
                        )
                    elif key.data == "xi2":
                        xi2_bytes += len(chunk)
                        if xi2_bytes > 1024 * 1024:
                            raise BaselineFailure(
                                "host_keyboard_witness_missing",
                                "owned XI2 key witness exceeded its bound",
                            )
                        xi2_buffer += chunk
                        while b"\n" in xi2_buffer:
                            raw_line, xi2_buffer = xi2_buffer.split(b"\n", 1)
                            key_witness.feed_bytes(raw_line)
                    else:
                        if phases == _CHANNEL_PHASES:
                            raise BaselineFailure(
                                "host_channel_witness_invalid",
                                "owned channel phase witness was ambiguous",
                            )
                        phase_buffer += chunk
                        if len(phase_buffer) > _CHANNEL_PHASE_BYTES:
                            raise BaselineFailure(
                                "host_channel_witness_invalid",
                                "owned channel phase witness was ambiguous",
                            )
                        while len(phase_buffer) >= 8:
                            phase = phase_buffer[:8]
                            phase_buffer = phase_buffer[8:]
                            expected = (_CHANNEL_PHASES[len(phases)]
                                if len(phases) < len(_CHANNEL_PHASES) else None)
                            if phase != expected:
                                raise BaselineFailure(
                                    "host_channel_witness_invalid",
                                    "owned channel phase order was invalid",
                                )
                            phases.append(phase)
                            if phase == _CHANNEL_PHASE_MICROPHONE:
                                if not microphone_armed:
                                    raise BaselineFailure("host_channel_witness_invalid",
                                        "owned microphone effect preceded its arm")
                                _acknowledge_microphone_effect(diagnostic_nonce)
                                microphone_acknowledged = True
                control = _poll_owned_effect_control(
                    diagnostic_nonce,
                    effect_controls,
                    timeout=min(0.5, max(0.0, deadline - time.monotonic())),
                )
                if not audio_armed and control == "audio":
                    if audio_arm_fd is None:
                        raise BaselineFailure(
                            "host_channel_witness_invalid",
                            "owned audio arm pipe was unavailable",
                        )
                    _arm_owned_audio(audio_arm_fd, diagnostic_nonce)
                    os.close(audio_arm_fd)
                    audio_arm_fd = None
                    audio_armed = True
                if not microphone_armed and control == "microphone":
                    if microphone_arm_fd is None:
                        raise BaselineFailure("host_channel_witness_invalid",
                            "owned microphone arm pipe was unavailable")
                    _arm_owned_audio(microphone_arm_fd, diagnostic_nonce, magic=_CHANNEL_PHASE_MICROPHONE)
                    os.close(microphone_arm_fd)
                    microphone_arm_fd = None
                    try:
                        microphone_tone = start_tone(pulse_path, diagnostic_nonce, private)
                    except (MicrophoneFixtureError, OSError):
                        raise BaselineFailure("host_channel_witness_invalid",
                            "owned microphone tone injection failed") from None
                    microphone_armed = True
                if key_witness.complete and _CHANNEL_PHASE_DISP in phases and not resized:
                    _resize_owned_display()
                    resized = True
                if phases == _CHANNEL_PHASES and not clip_marked:
                    if not resized:
                        raise BaselineFailure(
                            "host_channel_witness_invalid",
                            "owned clipboard effect preceded the display effect",
                        )
                    _mark_clipboard_effect()
                    clip_marked = True
        except BaselineFailure as error:
            pending_error = error
            error.owned_shadow_process = _owned_shadow_process_status(shadow)
            if shadow_log_fd is not None and shadow_log_path is not None:
                try:
                    if shadow is not None and shadow.stdout is not None:
                        shadow_log_size = _drain_shadow_output(
                            shadow.stdout.fileno(), shadow_log_fd, shadow_log_size,
                        )
                    os.fsync(shadow_log_fd)
                    error.server_resize_requested = _server_resize_requested(
                        shadow_log_path,
                    )
                except BaselineFailure:
                    error.server_resize_requested = None
            raise
        except subprocess.TimeoutExpired as error:
            pending_error = error
            error.owned_shadow_process = _owned_shadow_process_status(
                shadow, timed_out=True,
            )
            if shadow_log_fd is not None and shadow_log_path is not None:
                try:
                    if shadow is not None and shadow.stdout is not None:
                        shadow_log_size = _drain_shadow_output(
                            shadow.stdout.fileno(), shadow_log_fd, shadow_log_size,
                        )
                    os.fsync(shadow_log_fd)
                    error.server_resize_requested = _server_resize_requested(
                        shadow_log_path,
                    )
                except BaselineFailure:
                    error.server_resize_requested = None
            raise
        except OSError as error:
            pending_error = error
            error.owned_shadow_process = _owned_shadow_process_status(shadow)
            raise
        finally:
            selector.close()
            if gradle is not None and gradle.poll() is None:
                _stop_owned_process(gradle)
            if host_gradle_exited:
                if not host_exit_observed:
                    final_stage, final_evidence = (
                        lifecycle.observe_after_host_exit()
                    )
                    host_exit_observed = True
            else:
                lifecycle.stop()
                final_stage = lifecycle.last_stage()
                final_evidence = lifecycle.last_evidence()
            if pending_error is not None:
                pending_error.test_lifecycle_stage = final_stage
                pending_error.owned_marker_evidence = final_evidence
            if xinput is not None:
                _stop_owned_process(xinput)
            if shadow is not None:
                _stop_owned_process(shadow)
            if microphone_tone is not None:
                _stop_owned_process(microphone_tone)
            (private / "owned-microphone-tone.pcm").unlink(missing_ok=True)
            if microphone_arm_fd is not None:
                os.close(microphone_arm_fd)
            if phase_fd is not None:
                os.close(phase_fd)
            if audio_arm_fd is not None:
                os.close(audio_arm_fd)
            if shadow_log_fd is not None:
                os.close(shadow_log_fd)


def main() -> int:
    password = os.environ.get("RDP_ACCEPTANCE_PASSWORD", "")
    if not password or len(password) > 128 or "\x00" in password:
        raise AcceptanceFailure("owned RDP fixture credential is unavailable")
    package_versions = fixture_package_versions()
    # A cached or skipped invocation must not inherit a previous passing report.
    for report in REPORTS.rglob("TEST-*.xml"):
        report.unlink()
    runner_temp = Path(os.environ["RUNNER_TEMP"])
    diagnostic_nonce = secrets.token_hex(32)
    try:
        with tempfile.TemporaryDirectory(
            prefix="larenor-f62-gradle-", dir=runner_temp
        ) as temporary:
            gradle = materialized_gradle_command(
                Path(temporary) / "launcher",
                project_android=ROOT / "android",
            )
            (
                returncode,
                channel_evidence,
                server_resize_requested,
                test_lifecycle_stage,
                owned_marker_evidence,
                owned_shadow_process,
            ) = _run_owned_shadow_baseline(
                [
                    *gradle, "--no-daemon",
                    ":app:connectedDebugAndroidTest",
                    f"-Pandroid.testInstrumentationRunnerArguments.class={TEST_CLASS}",
                    "-Pandroid.testInstrumentationRunnerArguments.rdpHost=10.0.2.2",
                    f"-Pandroid.testInstrumentationRunnerArguments.rdpPort={_SHADOW_PORT}",
                    "-Pandroid.testInstrumentationRunnerArguments.rdpUsername=larenor",
                    "-Pandroid.testInstrumentationRunnerArguments.rdpDomain=LARENOR",
                    f"-Pandroid.testInstrumentationRunnerArguments.rdpPassword={password}",
                    "-Pandroid.testInstrumentationRunnerArguments."
                    f"rdpDiagnosticNonce={diagnostic_nonce}",
                    "-Pandroid.testInstrumentationRunnerArguments."
                    f"rdpControlSourceSha256={_CLASSIFICATION_SOURCE_SHA256}",
                ],
                runner_temp=runner_temp,
                diagnostic_nonce=diagnostic_nonce,
                timeout=1200,
            )
    except BaselineFailure as error:
        _publish_failed_run(
            runner_temp,
            package_versions,
            code=error.code,
            server_resize_requested=error.server_resize_requested,
            test_lifecycle_stage=getattr(error, "test_lifecycle_stage", None),
            owned_marker_evidence=getattr(error, "owned_marker_evidence", None),
            owned_shadow_process=getattr(error, "owned_shadow_process", None),
        )
        raise AcceptanceFailure(str(error)) from None
    except subprocess.TimeoutExpired as error:
        # TimeoutExpired includes argv, including the disposable credential.
        _publish_failed_run(
            runner_temp,
            package_versions,
            code="instrumentation_timeout",
            server_resize_requested=getattr(
                error, "server_resize_requested", None,
            ),
            test_lifecycle_stage=getattr(error, "test_lifecycle_stage", None),
            owned_marker_evidence=getattr(error, "owned_marker_evidence", None),
            owned_shadow_process=getattr(error, "owned_shadow_process", None),
        )
        raise AcceptanceFailure("packaged RDP instrumentation timed out") from None
    except (AndroidAcceptanceGradleError, OSError) as error:
        _publish_failed_run(
            runner_temp, package_versions,
            code="instrumentation_launch_unavailable",
            test_lifecycle_stage=getattr(error, "test_lifecycle_stage", None),
            owned_marker_evidence=getattr(error, "owned_marker_evidence", None),
            owned_shadow_process=getattr(error, "owned_shadow_process", None),
        )
        raise AcceptanceFailure(
            "packaged RDP instrumentation could not start") from None
    if returncode:
        _publish_failed_run(
            runner_temp,
            package_versions,
            server_resize_requested=server_resize_requested,
            test_lifecycle_stage=test_lifecycle_stage,
            owned_marker_evidence=owned_marker_evidence,
            owned_shadow_process=owned_shadow_process,
        )
        raise AcceptanceFailure(
            "packaged RDP instrumentation failed; public diagnostics written")
    try:
        report = verify_reports()
    except AcceptanceFailure:
        _publish_failed_run(runner_temp, package_versions)
        raise AcceptanceFailure(
            "packaged RDP report failed; public diagnostics written") from None
    if channel_evidence is None:
        raise AcceptanceFailure("owned RDP channel evidence is unavailable")
    publish_public_receipt(
        report, runner_temp, package_versions, channel_evidence,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AcceptanceFailure as error:
        print(f"F62_ACCEPTANCE_FAILURE:{error}", file=sys.stderr)
        raise SystemExit(1) from None
