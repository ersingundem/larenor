#!/usr/bin/env python3
"""Run the named packaged-Android stream gate against an owned Sunshine host.

One private wire carries the one-time Moonlight PIN and a distinct nonce-bound
wire coordinates only fixed input/disconnect phases. Provider addresses,
credentials, certificates, PINs, native identifiers, coordinates, media, and
raw provider output never enter the public receipt.
"""

from __future__ import annotations

from dataclasses import dataclass
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import stat
import struct
import subprocess
import tempfile
import threading
import time
from typing import Any, Callable, Mapping, Optional, Sequence
import wave
import xml.etree.ElementTree as ET

from tool.android_acceptance_gradle import materialized_gradle_command
from tool.f60_sunshine_android_discovery import (
    DiscoveryAcceptanceFailure,
    emulator_version,
    package_identity,
    prebuild_android_test as prebuild_owned_android_test,
    single_success_suite,
)
from tool.f60_owned_gamepad import OwnedGamepadAccess
from tool.f60_sunshine_owned_host import (
    DISPLAY,
    HostFailure,
    OwnedSunshineHost,
    ProcessPlan,
    _sunshine_mdns_instance_name,
)
from tool.native_acceptance_receipt import source_revision


ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "build/app/outputs/androidTest-results/connected/debug"
TEST_CLASS = (
    "com.ersingundem.larenor.game.moonlight."
    "MoonlightOwnedSunshineStreamTest"
)
TEST_NAME = (
    "productionNsdPairCatalogTwoStreamLifetimesTouchStopDisconnectAndLocalRetirement"
)
RECEIPT_NAME = "f60-sunshine-android-stream-receipt.json"
FAILURE_RECEIPT_NAME = "f60-sunshine-android-stream-failure.json"
ANDROID_PIN_PORT = 49_361
ANDROID_CONTROL_PORT = 49_362
PIN_MESSAGE_BYTES = 256
PIN_ACKNOWLEDGEMENT = b"LRNPIN1\n"
CONTROL_MESSAGE_BYTES = 512
PAIRING_CLIENT_NAME = "roth"
CONTROL_TIMEOUT_SECONDS = 300.0
PROCESS_TIMEOUT_SECONDS = 1_800
PREBUILD_TIMEOUT_SECONDS = 1_200
MAX_COMMAND_OUTPUT = 64 * 1024
SUNSHINE_STEREO_SINK = "sink-sunshine-stereo"
KEY_A_CODE = 38
PRIMARY_BUTTON = 1
XI2_LINE_BYTES = 4096
XI2_READY_TIMEOUT_SECONDS = 5.0
XI2_READY_POSITIONS = ((17, 19), (23, 29))
MAX_REPORT_BYTES = 1024 * 1024
MAX_PUBLIC_FRAMES = 8
_FAILURE_CODES = frozenset({
    "instrumentation_report_missing",
    "instrumentation_report_ambiguous",
    "instrumentation_report_malformed",
    "instrumentation_report_identity_mismatch",
    "instrumentation_test_failure",
    "instrumentation_test_error",
})
_PIN_BRIDGE_STAGES = frozenset({
    "listening",
    "connectionAccepted",
    "connectionRejected",
    "peerVerified",
    "peerRejected",
    "readRejected",
    "parseRejected",
    "ackRejected",
    "pinReceived",
    "pendingPairingObserved",
    "approvalInFlight",
    "approvalConfirmed",
    "pairedClientObserved",
})
_KNOWN_EXCEPTION_TYPES = frozenset({
    "java.lang.AssertionError",
    "java.lang.IllegalArgumentException",
    "java.lang.IllegalStateException",
    "java.lang.NullPointerException",
    "java.util.concurrent.TimeoutException",
})
_OWNED_FRAME = re.compile(
    r"\s*at (com\.ersingundem\.larenor\.game\.moonlight\."
    r"[A-Za-z0-9_.$]+)\.([A-Za-z0-9_.$<>]+)"
    r"\(([A-Za-z][A-Za-z0-9_]{0,127}\.(?:kt|java)):(\d{1,6})\)\s*"
)
_THROWABLE_HEADER = re.compile(
    r"(java\.(?:lang|util\.concurrent)\.[A-Za-z0-9_.$]+)(?::|$)"
)
_STREAM_COMMAND_MARKER = re.compile(
    r"java\.lang\.AssertionError: F60_STREAM_COMMAND_V1\|"
    r"state=(native_observed|unknown|invalid)\|"
    r"result=(streaming|unknown|invalid)\|"
    r"kind=(connectionStarted|unknown|invalid)\|"
    r"leaseClaim=(transferPending|gameVisible|uncertain|retired|absentOrUnreadable)\|"
    r"outcome=(strictFailure)\|"
    r"classification=(leaseTransferPending|leaseGameVisible|leaseUncertain|"
    r"leaseRetired|leaseAbsentOrUnreadable)"
)
_STREAM_DISPATCH_STAGES = frozenset({
    "beforeIssue", "postIssued", "launchReturned", "callback", "timeout",
})
_STREAM_DISPATCH_FAILURE_CLASSES = frozenset({
    "none",
    "com.ersingundem.larenor.game.moonlight.MoonlightRuntimeFailure",
    "android.content.ActivityNotFoundException",
    "java.lang.SecurityException",
    "java.lang.IllegalArgumentException",
    "java.lang.IllegalStateException",
    "unclassified",
})
_STREAM_RUNTIME_FAILURES = frozenset({
    "none", "authority_changed", "busy", "cancelled", "engine_unavailable",
    "foreground_required", "invalid_account_id", "invalid_authority_id",
    "invalid_candidate", "invalid_candidate_revision", "invalid_core_id",
    "invalid_family_id", "invalid_home_id", "invalid_pairing_revision",
    "invalid_request_id", "invalid_revision", "invalid_session_id",
    "invalid_timeout", "invalid_receipt", "provider_unavailable", "pin_required",
    "quarantined", "stale_candidate", "stale_pairing", "unknown_effect",
})
_STREAM_DISPATCH_MARKER = re.compile(
    r"F60_STREAM_DISPATCH_V1\|"
    r"stage=(beforeIssue|postIssued|launchReturned|callback|timeout)\|"
    r"failureClass=(none|com\.ersingundem\.larenor\.game\.moonlight\."
    r"MoonlightRuntimeFailure|android\.content\.ActivityNotFoundException|"
    r"java\.lang\.SecurityException|java\.lang\.IllegalArgumentException|"
    r"java\.lang\.IllegalStateException|unclassified)\|"
    r"runtimeFailure=(none|authority_changed|busy|cancelled|engine_unavailable|"
    r"foreground_required|invalid_account_id|invalid_authority_id|invalid_candidate|"
    r"invalid_candidate_revision|invalid_core_id|invalid_family_id|invalid_home_id|"
    r"invalid_pairing_revision|invalid_request_id|invalid_revision|invalid_session_id|"
    r"invalid_timeout|invalid_receipt|provider_unavailable|pin_required|quarantined|"
    r"stale_candidate|stale_pairing|unknown_effect)"
)
_CONNECTION_BOUNDARY_KEYS = (
    "surfaceCreated", "positiveSurfaceChanged", "stageStarted", "stageCompleted",
    "stageFailed", "connectionStarted",
)
_CONNECTION_BOUNDARY_PREFIX = "F60_CONNECTION_BOUNDARIES_V1|"
_CONNECTION_BOUNDARY_MARKER = re.compile(
    re.escape(_CONNECTION_BOUNDARY_PREFIX)
    + r"surfaceCreated=(true|false)\|positiveSurfaceChanged=(true|false)\|"
    + r"stageStarted=(true|false)\|stageCompleted=(true|false)\|"
    + r"stageFailed=(true|false)\|connectionStarted=(true|false)"
)
_OWNED_SOURCE_FILES = frozenset({
    "LarenorMoonlightGame.kt",
    "MoonlightAuthority.kt",
    "MoonlightDiscovery.kt",
    "MoonlightEmbeddedRuntime.kt",
    "MoonlightForegroundLeaseRegistry.kt",
    "MoonlightMethodChannelHost.kt",
    "MoonlightOperationJournal.kt",
    "MoonlightOwnedSunshineStreamTest.kt",
    "MoonlightRegistrationStore.kt",
    "MoonlightScopedContext.kt",
    "MoonlightSessionCapabilities.kt",
})
_STAGE_SOURCE = ROOT / (
    "android/app/src/moonlightAndroidTest/kotlin/com/ersingundem/larenor/"
    "game/moonlight/MoonlightOwnedSunshineStreamTest.kt"
)
_STAGE_SOURCE_SHA256 = "372f5a723356386664d9f1653f95ac5000ecf08c058fd112aa8541bf9e860570"
_STAGE_LINES = (
    (52, 68, "fixtureInputs"),
    (69, 103, "discovery"),
    (104, 128, "pairingRegistration"),
    (129, 155, "catalog"),
    (156, 216, "capabilityAndSession"),
    (217, 228, "firstStreamOutput"),
    (229, 237, "ownedInputEffects"),
    (238, 244, "deliberateStop"),
    (245, 266, "secondStreamOutput"),
    (267, 288, "remoteDisconnect"),
    (289, 318, "localRetirement"),
    (319, 331, "cleanup"),
)


class StreamAcceptanceFailure(RuntimeError):
    """A secret-free, fail-closed stream acceptance error."""


@dataclass(frozen=True)
class _GradleObservation:
    pid: int
    returncode: int
    pin_failure_stage: Optional[str]
    timed_out: bool


def _probe_owned_x11_pointer(x: int, y: int) -> None:
    """Warp the owned X pointer once to prove that the XI2 listener is active."""
    try:
        x11 = ctypes.CDLL("libX11.so.6")
        x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x11.XOpenDisplay.restype = ctypes.c_void_p
        x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x11.XDefaultRootWindow.restype = ctypes.c_ulong
        x11.XWarpPointer.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.c_int,
            ctypes.c_int,
        ]
        x11.XWarpPointer.restype = ctypes.c_int
        x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x11.XSync.restype = ctypes.c_int
        x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        x11.XCloseDisplay.restype = ctypes.c_int
        display = x11.XOpenDisplay(DISPLAY.encode("ascii"))
        if not display:
            raise StreamAcceptanceFailure("owned XI2 readiness probe is unavailable")
        try:
            root = x11.XDefaultRootWindow(display)
            if root == 0:
                raise StreamAcceptanceFailure("owned XI2 readiness probe failed")
            x11.XWarpPointer(display, 0, root, 0, 0, 0, 0, x, y)
            x11.XSync(display, 0)
        finally:
            x11.XCloseDisplay(display)
    except (AttributeError, OSError) as error:
        raise StreamAcceptanceFailure("owned XI2 readiness probe is unavailable") from error


def _pairs(values: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in values:
        if key in result:
            raise StreamAcceptanceFailure("private PIN control message is invalid")
        result[key] = value
    return result


def parse_pin_message(raw: bytes, *, expected_nonce: str) -> str:
    if (
        not isinstance(raw, bytes)
        or not 1 <= len(raw) <= PIN_MESSAGE_BYTES
        or re.fullmatch(r"[0-9a-f]{64}", expected_nonce) is None
        or not raw.endswith(b"\n")
        or b"\n" in raw[:-1]
    ):
        raise StreamAcceptanceFailure("private PIN control message is invalid")
    try:
        value = json.loads(raw[:-1].decode("ascii"), object_pairs_hook=_pairs)
    except StreamAcceptanceFailure:
        raise
    except (UnicodeError, json.JSONDecodeError) as error:
        raise StreamAcceptanceFailure("private PIN control message is invalid") from error
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "nonce", "pin"}:
        raise StreamAcceptanceFailure("private PIN control message is invalid")
    nonce = value.get("nonce")
    pin = value.get("pin")
    if (
        type(value.get("schemaVersion")) is not int
        or value.get("schemaVersion") != 1
        or not isinstance(nonce, str)
        or not secrets.compare_digest(nonce, expected_nonce)
        or not isinstance(pin, str)
        or re.fullmatch(r"[0-9]{4}", pin) is None
    ):
        raise StreamAcceptanceFailure("private PIN control message is invalid")
    canonical = (
        '{"schemaVersion":1,"nonce":"' + nonce + '","pin":"' + pin + '"}\n'
    ).encode("ascii")
    if not secrets.compare_digest(raw, canonical):
        raise StreamAcceptanceFailure("private PIN control message is invalid")
    return pin


def _control_message(*, nonce: str, phase: str) -> bytes:
    if (
        re.fullmatch(r"[0-9a-f]{64}", nonce) is None
        or phase
        not in {
            "touch_ready",
            "touch_armed",
            "touch_sent",
            "touch_observed",
            "gamepad_ready",
            "gamepad_armed",
            "gamepad_sent",
            "gamepad_observed",
            "disconnect_ready",
            "owned_sunshine_stopped",
        }
    ):
        raise StreamAcceptanceFailure("private phase control message is invalid")
    return (
        '{"schemaVersion":1,"nonce":"' + nonce + '","phase":"' + phase + '"}\n'
    ).encode("ascii")


def parse_control_message(raw: bytes, *, expected_nonce: str, expected_phase: str) -> None:
    if not isinstance(raw, bytes) or not 1 <= len(raw) <= CONTROL_MESSAGE_BYTES:
        raise StreamAcceptanceFailure("private phase control message is invalid")
    expected = _control_message(nonce=expected_nonce, phase=expected_phase)
    if not secrets.compare_digest(raw, expected):
        raise StreamAcceptanceFailure("private phase control message is invalid")


class OneShotPinBridge:
    """One-use loopback PIN receiver hidden behind an adb reverse mapping."""

    def __init__(
        self,
        owned: OwnedSunshineHost,
        *,
        nonce: str,
        timeout_seconds: float = CONTROL_TIMEOUT_SECONDS,
        monotonic: Callable[[], float] = time.monotonic,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        if re.fullmatch(r"[0-9a-f]{64}", nonce) is None or not 1 <= timeout_seconds <= 600:
            raise StreamAcceptanceFailure("private PIN bridge configuration is invalid")
        self._owned = owned
        self.nonce = nonce
        self._timeout = timeout_seconds
        self._monotonic = monotonic
        self._sleeper = sleeper
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
        self._socket.bind(("127.0.0.1", 0))
        self._socket.listen(1)
        self._socket.settimeout(timeout_seconds)
        self.host_port = int(self._socket.getsockname()[1])
        self._failure: Optional[BaseException] = None
        self._stage = "listening"
        self._stage_lock = threading.Lock()
        self._done = threading.Event()
        self._cancelled = threading.Event()
        self._connection: Optional[socket.socket] = None
        self.pin_approved = False
        self.paired_client_observed = False
        self.paired_client_uuid: Optional[str] = None
        self._thread = threading.Thread(target=self._serve, name="f60-pin-bridge", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def _set_stage(self, stage: str) -> None:
        if stage not in _PIN_BRIDGE_STAGES:
            raise StreamAcceptanceFailure("private PIN bridge stage is invalid")
        with self._stage_lock:
            self._stage = stage

    def public_stage(self) -> str:
        with self._stage_lock:
            return self._stage

    def terminal_failure_stage(self) -> Optional[str]:
        if not self._done.is_set() or self._failure is None:
            return None
        stage = self.public_stage()
        if stage not in _PIN_BRIDGE_STAGES:
            raise StreamAcceptanceFailure("private PIN bridge stage is invalid")
        return stage

    def _set_failure_stage(self, stage: str) -> None:
        if not self._cancelled.is_set():
            self._set_stage(stage)

    def _receive(self, connection: socket.socket) -> bytes:
        connection.settimeout(self._timeout)
        data = bytearray()
        while len(data) < PIN_MESSAGE_BYTES:
            chunk = connection.recv(min(64, PIN_MESSAGE_BYTES + 1 - len(data)))
            if not chunk:
                raise StreamAcceptanceFailure("private PIN control message is invalid")
            data.extend(chunk)
            newline = data.find(b"\n")
            if newline >= 0:
                if newline != len(data) - 1:
                    raise StreamAcceptanceFailure("private PIN control message is invalid")
                return bytes(data)
        if len(data) > PIN_MESSAGE_BYTES:
            raise StreamAcceptanceFailure("private PIN control message is invalid")
        raise StreamAcceptanceFailure("private PIN control message is invalid")

    def _serve(self) -> None:
        connection: Optional[socket.socket] = None
        try:
            try:
                connection, address = self._socket.accept()
            except BaseException:
                self._set_failure_stage("connectionRejected")
                raise
            self._connection = connection
            self._set_stage("connectionAccepted")
            with connection:
                if address[0] != "127.0.0.1":
                    self._set_failure_stage("peerRejected")
                    raise StreamAcceptanceFailure("private PIN peer identity is invalid")
                self._set_stage("peerVerified")
                try:
                    frame = self._receive(connection)
                except BaseException:
                    self._set_failure_stage("readRejected")
                    raise
                try:
                    pin = parse_pin_message(frame, expected_nonce=self.nonce)
                except BaseException:
                    self._set_failure_stage("parseRejected")
                    raise
                try:
                    connection.sendall(PIN_ACKNOWLEDGEMENT)
                except BaseException:
                    self._set_failure_stage("ackRejected")
                    raise
            self._set_stage("pinReceived")
            deadline = self._monotonic() + self._timeout
            pairing_id: Optional[str] = None
            while self._monotonic() < deadline and not self._cancelled.is_set():
                self._owned.processes.require_alive()
                pairing_id = self._owned.api.pending_pairing(PAIRING_CLIENT_NAME)
                if pairing_id is not None:
                    break
                self._sleeper(0.1)
            if pairing_id is None:
                raise StreamAcceptanceFailure("owned pending pairing was not observed")
            self._set_stage("pendingPairingObserved")
            self._set_stage("approvalInFlight")
            self._owned.api.approve_pairing(pairing_id, pin, PAIRING_CLIENT_NAME)
            self.pin_approved = True
            self._set_stage("approvalConfirmed")
            pin = "0000"
            while self._monotonic() < deadline and not self._cancelled.is_set():
                self._owned.processes.require_alive()
                try:
                    self.paired_client_uuid = self._owned.api.owned_client_uuid(
                        PAIRING_CLIENT_NAME
                    )
                    self.paired_client_observed = True
                    self._set_stage("pairedClientObserved")
                    return
                except HostFailure:
                    self._sleeper(0.1)
            raise StreamAcceptanceFailure("owned paired client was not observed")
        except BaseException as error:
            if not self._cancelled.is_set():
                self._failure = error
        finally:
            self._done.set()
            if connection is not None:
                try:
                    connection.close()
                except OSError:
                    pass
            try:
                self._socket.close()
            except OSError:
                pass
            self._connection = None

    def wait(self) -> None:
        if not self._done.wait(self._timeout + 1):
            raise StreamAcceptanceFailure("private PIN bridge did not complete")
        self._thread.join(timeout=1)
        if self._failure is not None:
            raise StreamAcceptanceFailure("private PIN bridge failed") from self._failure
        if (
            not self.pin_approved
            or not self.paired_client_observed
            or self.paired_client_uuid is None
        ):
            raise StreamAcceptanceFailure("private PIN bridge proof is incomplete")

    def close(self) -> None:
        self._cancelled.set()
        connection = self._connection
        if connection is not None:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                connection.close()
            except OSError:
                pass
        try:
            self._socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._socket.close()
        except OSError:
            pass
        if self._thread.is_alive():
            self._thread.join(timeout=2)
        if self._thread.is_alive():
            raise StreamAcceptanceFailure("private PIN bridge cleanup failed")


def write_owned_tone(destination: Path) -> None:
    if not destination.is_absolute() or destination.exists():
        raise StreamAcceptanceFailure("owned tone destination is invalid")
    try:
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            with wave.open(output, "wb") as wav:
                wav.setnchannels(2)
                wav.setsampwidth(2)
                wav.setframerate(48_000)
                frames = bytearray()
                for index in range(24_000):
                    sample = int(8_000 * math.sin(2 * math.pi * 440 * index / 48_000))
                    frames.extend(struct.pack("<hh", sample, sample))
                wav.writeframes(frames)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(destination, 0o600, follow_symlinks=False)
        info = destination.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or not 1 <= info.st_size <= 128 * 1024:
            raise StreamAcceptanceFailure("owned tone identity is invalid")
    except StreamAcceptanceFailure:
        raise
    except (OSError, wave.Error) as error:
        raise StreamAcceptanceFailure("owned tone could not be created") from error


def _pulse_environment(owned: OwnedSunshineHost) -> dict[str, str]:
    return {
        "HOME": str(owned.material.home),
        "LANG": "C.UTF-8",
        "PATH": "/usr/bin:/bin",
        "PULSE_SERVER": "unix:" + str(owned.material.runtime / "pulse/native"),
        "XDG_RUNTIME_DIR": str(owned.material.runtime),
    }


def inject_owned_tone(
    owned: OwnedSunshineHost,
    tone: Path,
    *,
    timeout_seconds: float = CONTROL_TIMEOUT_SECONDS,
    runner: Callable[..., Any] = subprocess.run,
    monotonic: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
    cancelled: Callable[[], bool] = lambda: False,
) -> None:
    if not 1 <= timeout_seconds <= 600:
        raise StreamAcceptanceFailure("owned tone timeout is invalid")
    deadline = monotonic() + timeout_seconds
    environment = _pulse_environment(owned)
    observed = False
    while monotonic() < deadline:
        if cancelled():
            raise StreamAcceptanceFailure("owned audio injection was cancelled")
        owned.processes.require_alive()
        try:
            completed = runner(
                ["/usr/bin/pactl", "list", "short", "sinks"],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=False,
                timeout=2,
                env=environment,
            )
        except (OSError, subprocess.TimeoutExpired):
            sleeper(0.1)
            continue
        output = completed.stdout if isinstance(completed.stdout, str) else ""
        if len(output.encode("utf-8")) > MAX_COMMAND_OUTPUT:
            raise StreamAcceptanceFailure("owned PulseAudio observation is invalid")
        names = {fields[1] for line in output.splitlines() if len(fields := line.split("\t")) >= 2}
        if completed.returncode == 0 and SUNSHINE_STEREO_SINK in names:
            observed = True
            break
        sleeper(0.1)
    if not observed:
        raise StreamAcceptanceFailure("Sunshine stereo sink was not observed")
    if cancelled():
        raise StreamAcceptanceFailure("owned audio injection was cancelled")
    try:
        completed = runner(
            ["/usr/bin/paplay", "--device=" + SUNSHINE_STEREO_SINK, str(tone)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise StreamAcceptanceFailure("owned audio injection failed") from error
    if completed.returncode != 0:
        raise StreamAcceptanceFailure("owned audio injection failed")


def start_owned_visual(owned: OwnedSunshineHost) -> None:
    environment = {
        "DISPLAY": DISPLAY,
        "HOME": str(owned.material.home),
        "LANG": "C.UTF-8",
        "PATH": "/usr/bin:/bin",
        "XDG_RUNTIME_DIR": str(owned.material.runtime),
    }
    owned.processes.spawn(ProcessPlan(
        "owned-changing-visual",
        (
            "/usr/bin/xclock", "-display", DISPLAY, "-digital", "-update", "1",
            "-geometry", "640x240+64+64",
        ),
        owned.material.logs / "owned-changing-visual.log",
        environment,
    ))
    owned.processes.require_alive()


class Xi2KeyWitness:
    def __init__(self, owned: OwnedSunshineHost) -> None:
        self._owned = owned
        self._process: Optional[subprocess.Popen[bytes]] = None
        self._done = threading.Event()
        self._failure: Optional[BaseException] = None
        self._thread: Optional[threading.Thread] = None
        self.observed = False

    def start(self) -> None:
        environment = {
            "DISPLAY": DISPLAY,
            "HOME": str(self._owned.material.home),
            "LANG": "C.UTF-8",
            "PATH": "/usr/bin:/bin",
            "XDG_RUNTIME_DIR": str(self._owned.material.runtime),
        }
        try:
            keymap = subprocess.run(
                ["/usr/bin/xmodmap", "-display", DISPLAY, "-pk"],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
                env=environment,
            )
            output = keymap.stdout if isinstance(keymap.stdout, str) else ""
            if keymap.returncode or len(output.encode("utf-8")) > MAX_COMMAND_OUTPUT or not any(
                re.match(r"^\s*38\s+", line) and "(a)" in line for line in output.splitlines()
            ):
                raise StreamAcceptanceFailure("owned X11 keymap is invalid")
            self._process = subprocess.Popen(
                ["/usr/bin/stdbuf", "-oL", "/usr/bin/xinput", "test-xi2", "--root"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                cwd=str(self._owned.material.root),
                env=environment,
                close_fds=True,
                start_new_session=True,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise StreamAcceptanceFailure("owned XI2 witness could not start") from error
        self._thread = threading.Thread(target=self._read, name="f60-xi2-witness", daemon=True)
        self._thread.start()

    def _read(self) -> None:
        try:
            assert self._process is not None and self._process.stdout is not None
            event: Optional[bytes] = None
            pressed = False
            total = 0
            while True:
                line = self._process.stdout.readline(XI2_LINE_BYTES + 1)
                if not line:
                    break
                total += len(line)
                if total > MAX_COMMAND_OUTPUT:
                    raise StreamAcceptanceFailure("owned XI2 observation is too large")
                if not line.endswith(b"\n") or len(line) > XI2_LINE_BYTES:
                    raise StreamAcceptanceFailure("owned XI2 observation is malformed")
                if line.startswith(b"EVENT"):
                    event = None
                    match = re.fullmatch(rb"EVENT type [0-9]+ \(([A-Za-z]+)\)\n", line)
                    if match is None:
                        raise StreamAcceptanceFailure("owned XI2 observation is malformed")
                    event = match.group(1)
                    continue
                detail = re.fullmatch(rb"\s+detail: ([0-9]+)\n", line)
                if detail is None or int(detail.group(1)) != KEY_A_CODE:
                    continue
                if event == b"KeyPress":
                    pressed = True
                elif event == b"KeyRelease" and pressed:
                    self.observed = True
                    return
        except BaseException as error:
            self._failure = error
        finally:
            self._done.set()

    def wait(self, timeout_seconds: float = CONTROL_TIMEOUT_SECONDS) -> None:
        if not self._done.wait(timeout_seconds):
            raise StreamAcceptanceFailure("owned XI2 key effect was not observed")
        if self._failure is not None or not self.observed:
            raise StreamAcceptanceFailure("owned XI2 key effect was not observed")

    def close(self) -> None:
        process = self._process
        if process is not None:
            try:
                if process.poll() is None:
                    _signal_owned_process_group(process, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        _signal_owned_process_group(process, signal.SIGKILL)
                        process.wait(timeout=5)
            except (OSError, subprocess.SubprocessError) as error:
                raise StreamAcceptanceFailure("owned XI2 witness cleanup failed") from error
            finally:
                if process.stdout is not None:
                    process.stdout.close()
        if self._thread is not None:
            self._thread.join(timeout=1)


class Xi2PointerWitness:
    """Observe the exact owned X11 motion and primary-button effect."""

    def __init__(
        self,
        owned: OwnedSunshineHost,
        *,
        readiness_probe: Callable[[int, int], None] = _probe_owned_x11_pointer,
        readiness_timeout_seconds: float = XI2_READY_TIMEOUT_SECONDS,
    ) -> None:
        if not 0 < readiness_timeout_seconds <= XI2_READY_TIMEOUT_SECONDS:
            raise StreamAcceptanceFailure("owned XI2 readiness timeout is invalid")
        self._owned = owned
        self._readiness_probe = readiness_probe
        self._readiness_timeout = readiness_timeout_seconds
        self._process: Optional[subprocess.Popen[bytes]] = None
        self._ready = threading.Event()
        self._done = threading.Event()
        self._failure: Optional[BaseException] = None
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._readiness_target: Optional[tuple[bytes, bytes]] = None
        self._collect_effects = False
        self._event: Optional[bytes] = None
        self._pressed = False
        self._released = False
        self._positions: set[tuple[bytes, bytes]] = set()
        self.observed = False

    def start(self) -> None:
        environment = {
            "DISPLAY": DISPLAY,
            "HOME": str(self._owned.material.home),
            "LANG": "C.UTF-8",
            "PATH": "/usr/bin:/bin",
            "XDG_RUNTIME_DIR": str(self._owned.material.runtime),
        }
        try:
            self._process = subprocess.Popen(
                ["/usr/bin/stdbuf", "-oL", "/usr/bin/xinput", "test-xi2", "--root"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                cwd=str(self._owned.material.root),
                env=environment,
                close_fds=True,
                start_new_session=True,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise StreamAcceptanceFailure("owned XI2 pointer witness could not start") from error
        self._thread = threading.Thread(
            target=self._read, name="f60-xi2-pointer-witness", daemon=True
        )
        self._thread.start()
        deadline = time.monotonic() + self._readiness_timeout
        probe_index = 0
        while not self._ready.is_set():
            if self._done.is_set() or time.monotonic() >= deadline:
                self.close()
                raise StreamAcceptanceFailure("owned XI2 pointer listener is not ready")
            x, y = XI2_READY_POSITIONS[probe_index % len(XI2_READY_POSITIONS)]
            probe_index += 1
            with self._lock:
                self._readiness_target = (str(x).encode("ascii"), str(y).encode("ascii"))
            try:
                self._readiness_probe(x, y)
            except BaseException as error:
                self.close()
                raise StreamAcceptanceFailure("owned XI2 pointer listener is not ready") from error
            self._ready.wait(min(0.1, max(0.0, deadline - time.monotonic())))
        with self._lock:
            # Readiness probes are never Android input evidence.
            self._event = None
            self._pressed = False
            self._released = False
            self._positions.clear()
            self._collect_effects = True

    def _consume_line(self, line: bytes) -> None:
        if not line.endswith(b"\n") or len(line) > XI2_LINE_BYTES:
            raise StreamAcceptanceFailure("owned XI2 pointer observation is malformed")
        if line.startswith(b"EVENT"):
            # Any event boundary invalidates fields belonging to the prior event.
            self._event = None
            match = re.fullmatch(rb"EVENT type [0-9]+ \(([A-Za-z]+)\)\n", line)
            if match is None:
                raise StreamAcceptanceFailure("owned XI2 pointer observation is malformed")
            self._event = match.group(1)
            return
        root = re.fullmatch(
            rb"\s+root: (-?[0-9]+(?:\.[0-9]+)?)/(-?[0-9]+(?:\.[0-9]+)?)\n",
            line,
        )
        if self._event == b"Motion" and root is not None:
            position = (root.group(1), root.group(2))
            if not self._collect_effects:
                target = self._readiness_target
                if target is not None and all(
                    float(current) == float(expected)
                    for current, expected in zip(position, target)
                ):
                    self._ready.set()
            else:
                self._positions.add(position)
        detail = re.fullmatch(rb"\s+detail: ([0-9]+)\n", line)
        if self._collect_effects and detail is not None and int(detail.group(1)) == PRIMARY_BUTTON:
            if self._event == b"ButtonPress":
                self._pressed = True
            elif self._event == b"ButtonRelease" and self._pressed:
                self._released = True
        if (
            self._collect_effects
            and len(self._positions) >= 2
            and self._pressed
            and self._released
        ):
            self.observed = True

    def _read(self) -> None:
        try:
            assert self._process is not None and self._process.stdout is not None
            total = 0
            while True:
                line = self._process.stdout.readline(XI2_LINE_BYTES + 1)
                if line == b"":
                    break
                total += len(line)
                if total > MAX_COMMAND_OUTPUT:
                    raise StreamAcceptanceFailure("owned XI2 pointer observation is too large")
                with self._lock:
                    self._consume_line(line)
                if self.observed:
                    return
        except BaseException as error:
            self._failure = error
        finally:
            self._done.set()

    def wait(self, timeout_seconds: float = CONTROL_TIMEOUT_SECONDS) -> None:
        if not self._done.wait(timeout_seconds):
            raise StreamAcceptanceFailure("owned XI2 pointer effect was not observed")
        if self._failure is not None or not self.observed:
            raise StreamAcceptanceFailure("owned XI2 pointer effect was not observed")

    def close(self) -> None:
        process = self._process
        if process is not None:
            try:
                if process.poll() is None:
                    _signal_owned_process_group(process, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        _signal_owned_process_group(process, signal.SIGKILL)
                        process.wait(timeout=5)
            except (OSError, subprocess.SubprocessError) as error:
                raise StreamAcceptanceFailure("owned XI2 pointer cleanup failed") from error
            finally:
                if process.stdout is not None:
                    process.stdout.close()
        if self._thread is not None:
            self._thread.join(timeout=1)


class PhaseControlBridge:
    """One authenticated private phase exchange for input and remote disconnect."""

    def __init__(
        self,
        owned: OwnedSunshineHost,
        *,
        nonce: str,
        paired_client_uuid: Callable[[], Optional[str]],
        gamepad: OwnedGamepadAccess,
        timeout_seconds: float = CONTROL_TIMEOUT_SECONDS,
        witness_factory: Callable[[OwnedSunshineHost], Xi2PointerWitness] = Xi2PointerWitness,
    ) -> None:
        if re.fullmatch(r"[0-9a-f]{64}", nonce) is None or not 1 <= timeout_seconds <= 600:
            raise StreamAcceptanceFailure("private phase bridge configuration is invalid")
        self._owned = owned
        self._nonce = nonce
        self._paired_client_uuid = paired_client_uuid
        self._gamepad = gamepad
        self._timeout = timeout_seconds
        self._witness_factory = witness_factory
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
        self._socket.bind(("127.0.0.1", 0))
        self._socket.listen(1)
        self._socket.settimeout(timeout_seconds)
        self.host_port = int(self._socket.getsockname()[1])
        self._failure: Optional[BaseException] = None
        self._done = threading.Event()
        self._cancelled = threading.Event()
        self._connection: Optional[socket.socket] = None
        self._witness: Optional[Xi2PointerWitness] = None
        self.touch_observed = False
        self.gamepad_observed = False
        self.provider_pairing_present_before_disconnect = False
        self.sunshine_stopped = False
        self._thread = threading.Thread(
            target=self._serve, name="f60-phase-control", daemon=True
        )

    def start(self) -> None:
        self._thread.start()

    def _line(self, stream: Any) -> bytes:
        raw = stream.readline(CONTROL_MESSAGE_BYTES + 1)
        if not isinstance(raw, bytes) or not raw.endswith(b"\n") or len(raw) > CONTROL_MESSAGE_BYTES:
            raise StreamAcceptanceFailure("private phase control message is invalid")
        return raw

    def _expect(self, stream: Any, phase: str) -> None:
        parse_control_message(
            self._line(stream), expected_nonce=self._nonce, expected_phase=phase
        )

    def _send(self, stream: Any, phase: str) -> None:
        stream.write(_control_message(nonce=self._nonce, phase=phase))
        stream.flush()

    def _serve(self) -> None:
        try:
            connection, address = self._socket.accept()
            self._connection = connection
            if address[0] != "127.0.0.1":
                raise StreamAcceptanceFailure("private phase peer identity is invalid")
            connection.settimeout(self._timeout)
            with connection, connection.makefile("rwb", buffering=0) as control:
                self._expect(control, "touch_ready")
                self._witness = self._witness_factory(self._owned)
                self._witness.start()
                self._send(control, "touch_armed")
                self._expect(control, "touch_sent")
                self._witness.wait(self._timeout)
                self.touch_observed = True
                self._send(control, "touch_observed")
                self._expect(control, "gamepad_ready")
                self._gamepad.arm()
                self._send(control, "gamepad_armed")
                self._expect(control, "gamepad_sent")
                self._gamepad.wait_effect()
                self._gamepad.disarm()
                self.gamepad_observed = True
                self._send(control, "gamepad_observed")
                self._expect(control, "disconnect_ready")
                client_uuid = self._paired_client_uuid()
                if client_uuid is None:
                    raise StreamAcceptanceFailure("owned paired client proof is incomplete")
                self._owned.api.require_owned_client_present(
                    PAIRING_CLIENT_NAME, client_uuid
                )
                self.provider_pairing_present_before_disconnect = True
                self._owned.processes.stop_sunshine()
                self.sunshine_stopped = True
                self._send(control, "owned_sunshine_stopped")
                if control.read(1) != b"":
                    raise StreamAcceptanceFailure("private phase control message is invalid")
        except BaseException as error:
            self._failure = error
        finally:
            try:
                self._gamepad.disarm()
            except BaseException as error:
                self._failure = self._failure or error
            if self._witness is not None:
                try:
                    self._witness.close()
                except BaseException as error:
                    self._failure = self._failure or error
            self._done.set()
            try:
                self._socket.close()
            except OSError:
                pass
            self._connection = None

    def wait(self) -> None:
        if not self._done.wait(self._timeout + 1):
            raise StreamAcceptanceFailure("private phase bridge did not complete")
        self._thread.join(timeout=1)
        if self._failure is not None:
            raise StreamAcceptanceFailure("private phase bridge failed") from self._failure
        if not (
            self.touch_observed
            and self.gamepad_observed
            and self.provider_pairing_present_before_disconnect
            and self.sunshine_stopped
        ):
            raise StreamAcceptanceFailure("private phase bridge proof is incomplete")

    def close(self) -> None:
        self._cancelled.set()
        connection = self._connection
        if connection is not None:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                connection.close()
            except OSError:
                pass
        try:
            self._socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._socket.close()
        except OSError:
            pass
        if self._thread.is_alive():
            # Allow the bounded nofollow evdev close and ACL restoration to finish
            # before the owned Sunshine context can remove the virtual device.
            self._thread.join(timeout=20)
        if self._thread.is_alive():
            raise StreamAcceptanceFailure("private phase bridge cleanup failed")


def _signal_owned_process_group(process: Any, signal_number: int) -> None:
    pid = getattr(process, "pid", None)
    if (
        type(pid) is not int
        or pid <= 1
        or signal_number not in {signal.SIGTERM, signal.SIGKILL}
    ):
        raise StreamAcceptanceFailure("owned XI2 process identity is invalid")
    try:
        group = os.getpgid(pid)
        if group != pid:
            raise StreamAcceptanceFailure("owned XI2 process group identity is invalid")
        os.killpg(group, signal_number)
    except ProcessLookupError:
        return
    except StreamAcceptanceFailure:
        raise
    except OSError as error:
        raise StreamAcceptanceFailure("owned XI2 process group cleanup failed") from error


def install_adb_reverse(
    host_port: int,
    *,
    android_port: int = ANDROID_PIN_PORT,
    runner: Callable[..., Any] = subprocess.run,
) -> None:
    if not 1 <= host_port <= 65_535 or android_port not in {
        ANDROID_PIN_PORT,
        ANDROID_CONTROL_PORT,
    }:
        raise StreamAcceptanceFailure("private reverse transport port is invalid")
    try:
        completed = runner(
            ["adb", "reverse", "tcp:" + str(android_port), "tcp:" + str(host_port)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise StreamAcceptanceFailure("private reverse transport is unavailable") from error
    if completed.returncode != 0:
        raise StreamAcceptanceFailure("private reverse transport is unavailable")


def _terminate_and_reap_owned_process(
    process: Any,
    *,
    terminate_timeout_seconds: float = 5.0,
    kill_timeout_seconds: float = 5.0,
) -> int:
    pid = getattr(process, "pid", None)
    if type(pid) is not int or pid <= 1:
        raise StreamAcceptanceFailure("Android stream child identity is invalid")
    returncode = process.poll()
    if returncode is not None:
        process.wait(timeout=1)
        return int(returncode)
    try:
        group = os.getpgid(pid)
        if group != pid:
            raise StreamAcceptanceFailure("Android stream child group identity is invalid")
        os.killpg(group, signal.SIGTERM)
    except ProcessLookupError:
        return int(process.wait(timeout=1))
    except StreamAcceptanceFailure:
        raise
    except OSError as error:
        raise StreamAcceptanceFailure("Android stream child cleanup failed") from error
    try:
        return int(process.wait(timeout=terminate_timeout_seconds))
    except subprocess.TimeoutExpired:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as error:
            raise StreamAcceptanceFailure("Android stream child cleanup failed") from error
        try:
            return int(process.wait(timeout=kill_timeout_seconds))
        except subprocess.TimeoutExpired as error:
            raise StreamAcceptanceFailure("Android stream child cleanup failed") from error


def _terminate_and_reap_process_handle(
    process: Any,
    *,
    terminate_timeout_seconds: float = 5.0,
    kill_timeout_seconds: float = 5.0,
) -> int:
    """Reap a returned Popen handle when its numeric identity is unusable."""
    try:
        returncode = process.poll()
        if returncode is not None:
            return int(process.wait(timeout=1))
        process.terminate()
        try:
            return int(process.wait(timeout=terminate_timeout_seconds))
        except subprocess.TimeoutExpired:
            process.kill()
            return int(process.wait(timeout=kill_timeout_seconds))
    except (AttributeError, OSError, subprocess.TimeoutExpired, ValueError) as error:
        raise StreamAcceptanceFailure("Android stream child cleanup failed") from error


def _run_gradle_with_pin_observation(
    argv: Sequence[str],
    bridge: OneShotPinBridge,
    *,
    cwd: Path,
    timeout_seconds: float,
    poll_seconds: float = 0.1,
    process_factory: Callable[..., Any] = subprocess.Popen,
    monotonic: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> _GradleObservation:
    if (
        not argv
        or any(not isinstance(value, str) or not value for value in argv)
        or not cwd.is_absolute()
        or not 0 < timeout_seconds <= PROCESS_TIMEOUT_SECONDS
        or not 0 < poll_seconds <= 1
    ):
        raise StreamAcceptanceFailure("Android stream child configuration is invalid")
    process = process_factory(
        list(argv),
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    pid = getattr(process, "pid", None)
    if type(pid) is not int or pid <= 1:
        _terminate_and_reap_process_handle(process)
        raise StreamAcceptanceFailure("Android stream child identity is invalid")
    try:
        deadline = monotonic() + timeout_seconds
        while True:
            returncode = process.poll()
            if returncode is not None:
                process.wait(timeout=1)
                return _GradleObservation(
                    pid, int(returncode), bridge.terminal_failure_stage(), False,
                )
            failure_stage = bridge.terminal_failure_stage()
            if failure_stage is not None:
                return _GradleObservation(
                    pid,
                    _terminate_and_reap_owned_process(process),
                    failure_stage,
                    False,
                )
            if monotonic() >= deadline:
                return _GradleObservation(
                    pid, _terminate_and_reap_owned_process(process), None, True,
                )
            sleeper(poll_seconds)
    except BaseException:
        try:
            _terminate_and_reap_owned_process(process)
        except BaseException:
            pass
        raise


def remove_adb_reverse(
    *,
    android_port: int = ANDROID_PIN_PORT,
    runner: Callable[..., Any] = subprocess.run,
) -> None:
    if android_port not in {ANDROID_PIN_PORT, ANDROID_CONTROL_PORT}:
        raise StreamAcceptanceFailure("private reverse transport port is invalid")
    try:
        completed = runner(
            ["adb", "reverse", "--remove", "tcp:" + str(android_port)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise StreamAcceptanceFailure("private reverse transport cleanup failed") from error
    if completed.returncode != 0:
        raise StreamAcceptanceFailure("private reverse transport cleanup failed")


def prebuild_android_test(
    gradle: Sequence[str],
    *,
    runner: Callable[..., Any] = subprocess.run,
) -> None:
    if not gradle or any(not isinstance(value, str) or not value for value in gradle):
        raise StreamAcceptanceFailure("Android stream Gradle launcher is invalid")
    try:
        prebuild_owned_android_test(gradle, runner=runner)
    except DiscoveryAcceptanceFailure as error:
        raise StreamAcceptanceFailure("owned Sunshine Android prebuild failed") from error


def verify_report(root: Path = REPORTS) -> dict[str, int | str]:
    try:
        info = root.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise StreamAcceptanceFailure("Android stream report identity is invalid")
        reports = list(root.rglob("TEST-*.xml"))
        if len(reports) != 1:
            raise StreamAcceptanceFailure("Android stream report is missing or ambiguous")
        report = reports[0]
        relative = report.relative_to(root)
        cursor = root
        for part in relative.parts[:-1]:
            cursor /= part
            if cursor.is_symlink():
                raise StreamAcceptanceFailure("Android stream report identity is invalid")
        report_info = report.lstat()
        if stat.S_ISLNK(report_info.st_mode) or not stat.S_ISREG(report_info.st_mode) or not 1 <= report_info.st_size <= 1024 * 1024:
            raise StreamAcceptanceFailure("Android stream report identity is invalid")
        suite = ET.parse(report).getroot()
    except (OSError, ET.ParseError) as error:
        raise StreamAcceptanceFailure("Android stream report is malformed") from error
    try:
        suite = single_success_suite(suite)
    except DiscoveryAcceptanceFailure:
        raise StreamAcceptanceFailure("Android stream report aggregate is invalid") from None
    cases = list(suite.iter("testcase"))
    if len(cases) != 1:
        raise StreamAcceptanceFailure("Android stream report is missing or ambiguous")
    case = cases[0]
    if case.attrib.get("classname") != TEST_CLASS or case.attrib.get("name") != TEST_NAME:
        raise StreamAcceptanceFailure("Android stream report identity is invalid")
    if any(case.find(kind) is not None for kind in ("failure", "error", "skipped")):
        raise StreamAcceptanceFailure("Android stream test did not pass")
    return {"className": TEST_CLASS, "testName": TEST_NAME, "tests": 1,
            "failures": 0, "errors": 0, "skipped": 0}


def _static_failure(code: str) -> dict[str, object]:
    if code not in _FAILURE_CODES:
        raise StreamAcceptanceFailure("Android stream failure code is invalid")
    return {"code": code, "exceptionType": "unclassified", "frames": []}


def _counts(element: ET.Element) -> dict[str, int]:
    values = {
        key: int(element.attrib[key])
        for key in ("tests", "failures", "errors", "skipped")
    }
    if any(value < 0 or value > 1024 for value in values.values()):
        raise ValueError()
    return values


def _failure_suite(root: ET.Element) -> tuple[ET.Element, dict[str, int]]:
    if root.tag == "testsuite":
        return root, _counts(root)
    if root.tag != "testsuites":
        raise ValueError()
    children = list(root)
    suites = [child for child in children if child.tag == "testsuite"]
    if len(children) != 1 or len(suites) != 1:
        raise ValueError()
    aggregate = _counts(root)
    if _counts(suites[0]) != aggregate:
        raise ValueError()
    return suites[0], aggregate


def _acceptance_stage(line: int) -> Optional[str]:
    try:
        if hashlib.sha256(_STAGE_SOURCE.read_bytes()).hexdigest() != _STAGE_SOURCE_SHA256:
            return None
    except OSError:
        return None
    for first, last, stage in _STAGE_LINES:
        if first <= line <= last:
            return stage
    return None


def _failure_details(
    element: ET.Element,
    *,
    code: str,
    counts: Mapping[str, int],
) -> dict[str, object]:
    text = "".join(element.itertext())
    lines = text.splitlines()
    declared = element.attrib.get("type", "")
    header = _THROWABLE_HEADER.match(lines[0].strip()) if lines else None
    exception_type = declared if declared in _KNOWN_EXCEPTION_TYPES else (
        header.group(1) if header is not None and header.group(1) in _KNOWN_EXCEPTION_TYPES
        else "unclassified"
    )
    frames: list[dict[str, object]] = []
    seen: set[tuple[str, int]] = set()
    stage: Optional[str] = None
    for line in lines:
        match = _OWNED_FRAME.fullmatch(line)
        if match is None:
            continue
        class_name, method_name, filename, raw_line = match.groups()
        source_line = int(raw_line)
        source_class = filename.rsplit(".", 1)[0]
        outer_class = class_name.rsplit(".", 1)[-1].split("$", 1)[0]
        key = (filename, source_line)
        if (
            filename not in _OWNED_SOURCE_FILES
            or outer_class not in {source_class, source_class + "Kt"}
            or key in seen
        ):
            continue
        seen.add(key)
        frames.append({"file": filename, "line": source_line})
        if (
            class_name == TEST_CLASS
            and method_name == TEST_NAME
            and filename == "MoonlightOwnedSunshineStreamTest.kt"
        ):
            stage = _acceptance_stage(source_line)
        if len(frames) == MAX_PUBLIC_FRAMES:
            break
    if not frames:
        exception_type = "unclassified"
    diagnostic: dict[str, object] = {
        "code": code,
        "exceptionType": exception_type,
        "frames": frames,
        "counts": dict(counts),
        "namedTest": {"className": TEST_CLASS, "testName": TEST_NAME},
    }
    if stage is not None:
        diagnostic["acceptanceStage"] = stage
    markers = [match for line in lines if (match := _STREAM_COMMAND_MARKER.fullmatch(line.strip()))]
    if stage == "firstStreamOutput" and exception_type == "java.lang.AssertionError" and len(markers) == 1:
        marker = markers[0]
        lease_claim = marker.group(4)
        classification = marker.group(6)
        expected_classification = {
            "transferPending": "leaseTransferPending",
            "gameVisible": "leaseGameVisible",
            "uncertain": "leaseUncertain",
            "retired": "leaseRetired",
            "absentOrUnreadable": "leaseAbsentOrUnreadable",
        }[lease_claim]
        if classification == expected_classification:
            diagnostic["streamCommand"] = {
                "state": marker.group(1),
                "result": marker.group(2),
                "observationKind": marker.group(3),
                "leaseClaim": lease_claim,
                "outcome": marker.group(5),
                "classification": classification,
            }
    dispatch_markers = [
        match for line in lines
        if (match := _STREAM_DISPATCH_MARKER.fullmatch(line.strip()))
    ]
    if (
        stage == "firstStreamOutput"
        and exception_type == "java.lang.AssertionError"
        and len(markers) == 1
        and len(dispatch_markers) == 1
        and "streamCommand" in diagnostic
    ):
        dispatch = dispatch_markers[0]
        failure_class = dispatch.group(2)
        runtime_failure = dispatch.group(3)
        runtime_class = (
            "com.ersingundem.larenor.game.moonlight.MoonlightRuntimeFailure"
        )
        if (failure_class == runtime_class) == (runtime_failure != "none"):
            diagnostic["streamDispatch"] = {
                "stage": dispatch.group(1),
                "failureClass": failure_class,
                "runtimeFailure": runtime_failure,
            }
    boundary_lines = [
        line.strip() for line in lines
        if line.strip().startswith(_CONNECTION_BOUNDARY_PREFIX)
    ]
    if (
        code == "instrumentation_test_failure"
        and counts == {"tests": 1, "failures": 1, "errors": 0, "skipped": 0}
        and stage == "firstStreamOutput"
        and exception_type == "java.lang.AssertionError"
        and "streamCommand" in diagnostic
        and len(boundary_lines) == 1
        and (boundary := _CONNECTION_BOUNDARY_MARKER.fullmatch(boundary_lines[0]))
    ):
        diagnostic["connectionBoundaries"] = {
            key: value == "true"
            for key, value in zip(_CONNECTION_BOUNDARY_KEYS, boundary.groups())
        }
    return diagnostic


def _read_bounded_report(report: Path, expected: os.stat_result) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(report, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or opened.st_uid != os.getuid()
            or (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino)
            or opened.st_size != expected.st_size
            or not 1 <= opened.st_size <= MAX_REPORT_BYTES
        ):
            raise ValueError()
        chunks: list[bytes] = []
        total = 0
        while total <= MAX_REPORT_BYTES:
            chunk = os.read(descriptor, min(64 * 1024, MAX_REPORT_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        finished = os.fstat(descriptor)
        if (
            total == 0
            or total > MAX_REPORT_BYTES
            or finished.st_nlink != 1
            or finished.st_uid != opened.st_uid
            or (finished.st_dev, finished.st_ino) != (opened.st_dev, opened.st_ino)
            or finished.st_size != opened.st_size
            or finished.st_size != total
        ):
            raise ValueError()
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def failure_diagnostic(root: Optional[Path] = None) -> dict[str, object]:
    root = REPORTS if root is None else root
    try:
        info = root.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            return _static_failure("instrumentation_report_malformed")
        reports = list(root.rglob("TEST-*.xml"))
    except OSError:
        return _static_failure("instrumentation_report_missing")
    if not reports:
        return _static_failure("instrumentation_report_missing")
    if len(reports) != 1:
        return _static_failure("instrumentation_report_ambiguous")
    report = reports[0]
    try:
        relative = report.relative_to(root)
        cursor = root
        for part in relative.parts[:-1]:
            cursor /= part
            if cursor.is_symlink():
                raise ValueError()
        metadata = report.lstat()
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.getuid()
            or not 1 <= metadata.st_size <= MAX_REPORT_BYTES
        ):
            raise ValueError()
        raw = _read_bounded_report(report, metadata)
        if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
            raise ValueError()
        suite, counts = _failure_suite(ET.fromstring(raw))
        if suite.findall(".//testsuite"):
            raise ValueError()
        cases = list(suite.iter("testcase"))
        if len(cases) != 1 or counts["tests"] != 1 or counts["skipped"] != 0:
            diagnostic = _static_failure("instrumentation_report_identity_mismatch")
            diagnostic["counts"] = counts
            diagnostic["identity"] = {
                "caseCount": min(len(cases), 1024),
                "classExpected": len(cases) == 1
                and cases[0].attrib.get("classname") == TEST_CLASS,
                "methodExpected": len(cases) == 1
                and cases[0].attrib.get("name") == TEST_NAME,
            }
            return diagnostic
        case = cases[0]
        if (
            case.attrib.get("classname") != TEST_CLASS
            or case.attrib.get("name") != TEST_NAME
        ):
            diagnostic = _static_failure("instrumentation_report_identity_mismatch")
            diagnostic["counts"] = counts
            diagnostic["identity"] = {
                "caseCount": 1,
                "classExpected": case.attrib.get("classname") == TEST_CLASS,
                "methodExpected": case.attrib.get("name") == TEST_NAME,
            }
            return diagnostic
        failures = list(case.findall("failure"))
        errors = list(case.findall("error"))
        if (
            counts == {"tests": 1, "failures": 1, "errors": 0, "skipped": 0}
            and len(failures) == 1
            and not errors
        ):
            return _failure_details(
                failures[0], code="instrumentation_test_failure", counts=counts
            )
        if (
            counts == {"tests": 1, "failures": 0, "errors": 1, "skipped": 0}
            and len(errors) == 1
            and not failures
        ):
            return _failure_details(
                errors[0], code="instrumentation_test_error", counts=counts
            )
    except (OSError, ET.ParseError, KeyError, TypeError, ValueError):
        pass
    return _static_failure("instrumentation_report_malformed")


def _validate_failure_diagnostic(diagnostic: Mapping[str, object]) -> None:
    allowed = {
        "code", "exceptionType", "frames", "counts", "identity", "namedTest",
        "acceptanceStage", "pinBridgeStage", "streamCommand", "streamDispatch",
        "connectionBoundaries",
    }
    if not set(diagnostic).issubset(allowed):
        raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    code = diagnostic.get("code")
    exception_type = diagnostic.get("exceptionType")
    frames = diagnostic.get("frames")
    if (
        code not in _FAILURE_CODES
        or exception_type not in {*_KNOWN_EXCEPTION_TYPES, "unclassified"}
        or type(frames) is not list
        or len(frames) > MAX_PUBLIC_FRAMES
    ):
        raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    for frame in frames:
        if (
            type(frame) is not dict
            or set(frame) != {"file", "line"}
            or frame["file"] not in _OWNED_SOURCE_FILES
            or type(frame["line"]) is not int
            or not 1 <= frame["line"] <= 1_000_000
        ):
            raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")

    counts = diagnostic.get("counts")
    if counts is not None and (
        type(counts) is not dict
        or set(counts) != {"tests", "failures", "errors", "skipped"}
        or any(type(value) is not int or not 0 <= value <= 1024 for value in counts.values())
    ):
        raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    exact = code in {"instrumentation_test_failure", "instrumentation_test_error"}
    expected_counts = {
        "instrumentation_test_failure": {
            "tests": 1, "failures": 1, "errors": 0, "skipped": 0,
        },
        "instrumentation_test_error": {
            "tests": 1, "failures": 0, "errors": 1, "skipped": 0,
        },
    }
    if exact and counts != expected_counts[code]:
        raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    if not exact and (
        exception_type != "unclassified" or frames or diagnostic.get("acceptanceStage") is not None
    ):
        raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    named = diagnostic.get("namedTest")
    if (exact and named != {"className": TEST_CLASS, "testName": TEST_NAME}) or (
        not exact and named is not None
    ):
        raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    identity = diagnostic.get("identity")
    if (code == "instrumentation_report_identity_mismatch") != (identity is not None):
        raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    if identity is not None and (
        type(identity) is not dict
        or set(identity) != {"caseCount", "classExpected", "methodExpected"}
        or type(identity["caseCount"]) is not int
        or not 0 <= identity["caseCount"] <= 1024
        or type(identity["classExpected"]) is not bool
        or type(identity["methodExpected"]) is not bool
    ):
        raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    stage = diagnostic.get("acceptanceStage")
    pin_stage = diagnostic.get("pinBridgeStage")
    if pin_stage is not None and pin_stage not in _PIN_BRIDGE_STAGES:
        raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    frame_stages = {
        _acceptance_stage(frame["line"])
        for frame in frames
        if frame["file"] == "MoonlightOwnedSunshineStreamTest.kt"
    }
    if stage is not None and (
        not exact
        or stage not in {value[2] for value in _STAGE_LINES}
        or stage not in frame_stages
    ):
        raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    command = diagnostic.get("streamCommand")
    if command is not None:
        expected_keys = {
            "state", "result", "observationKind", "leaseClaim", "outcome", "classification",
        }
        classifications = {
            "transferPending": "leaseTransferPending",
            "gameVisible": "leaseGameVisible",
            "uncertain": "leaseUncertain",
            "retired": "leaseRetired",
            "absentOrUnreadable": "leaseAbsentOrUnreadable",
        }
        if (
            not exact
            or stage != "firstStreamOutput"
            or exception_type != "java.lang.AssertionError"
            or type(command) is not dict
            or set(command) != expected_keys
            or command["state"] not in {"native_observed", "unknown", "invalid"}
            or command["result"] not in {"streaming", "unknown", "invalid"}
            or command["observationKind"] not in {"connectionStarted", "unknown", "invalid"}
            or command["leaseClaim"] not in classifications
            or command["outcome"] != "strictFailure"
            or command["classification"] != classifications.get(command["leaseClaim"])
        ):
            raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    dispatch = diagnostic.get("streamDispatch")
    if dispatch is not None:
        runtime_class = (
            "com.ersingundem.larenor.game.moonlight.MoonlightRuntimeFailure"
        )
        if (
            command is None
            or type(dispatch) is not dict
            or set(dispatch) != {"stage", "failureClass", "runtimeFailure"}
            or dispatch["stage"] not in _STREAM_DISPATCH_STAGES
            or dispatch["failureClass"] not in _STREAM_DISPATCH_FAILURE_CLASSES
            or dispatch["runtimeFailure"] not in _STREAM_RUNTIME_FAILURES
            or (dispatch["failureClass"] == runtime_class)
            != (dispatch["runtimeFailure"] != "none")
        ):
            raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")
    if "connectionBoundaries" in diagnostic:
        boundaries = diagnostic["connectionBoundaries"]
        if (
            code != "instrumentation_test_failure"
            or counts != {"tests": 1, "failures": 1, "errors": 0, "skipped": 0}
            or command is None
            or stage != "firstStreamOutput"
            or exception_type != "java.lang.AssertionError"
            or type(boundaries) is not dict
            or set(boundaries) != set(_CONNECTION_BOUNDARY_KEYS)
            or any(type(value) is not bool for value in boundaries.values())
        ):
            raise StreamAcceptanceFailure("Android stream public diagnostic is invalid")


def write_failure_receipt(
    destination: Path,
    *,
    version: str,
    moonlight_package: Mapping[str, str],
    diagnostic: Mapping[str, object],
) -> None:
    _validate_failure_diagnostic(diagnostic)
    package = dict(moonlight_package)
    if (
        set(package) != {
            "aarSha256", "classesSha256", "engineRevision", "sourceCommit",
            "sourceTree",
        }
        or any(type(value) is not str for value in package.values())
        or re.fullmatch(r"[0-9a-f]{64}", package["aarSha256"]) is None
        or re.fullmatch(r"[0-9a-f]{64}", package["classesSha256"]) is None
        or re.fullmatch(r"[0-9a-f]{40}", package["sourceCommit"]) is None
        or re.fullmatch(r"[0-9a-f]{40}", package["sourceTree"]) is None
        or re.fullmatch(r"[A-Za-z0-9._-]{1,128}", package["engineRevision"]) is None
        or re.fullmatch(r"[0-9]+(?:\.[0-9]+){2,3}", version) is None
    ):
        raise StreamAcceptanceFailure("Android stream failure provenance is invalid")
    payload = {
        "schemaVersion": 1,
        "gate": "owned_sunshine_android_stream",
        "sourceRevision": source_revision(ROOT),
        "emulatorVersion": version,
        "moonlightPackage": package,
        "result": "failed",
        "diagnostic": dict(diagnostic),
    }
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
    if len(encoded) > 8192:
        raise StreamAcceptanceFailure("Android stream failure receipt exceeds its bound")
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    created = os.fstat(descriptor)
    try:
        if (
            not stat.S_ISREG(created.st_mode)
            or created.st_nlink != 1
            or created.st_uid != os.getuid()
            or stat.S_IMODE(created.st_mode) != 0o600
        ):
            raise OSError("Android stream failure receipt identity is invalid")
        offset = 0
        while offset < len(encoded):
            written = os.write(descriptor, encoded[offset:])
            if type(written) is not int or written <= 0 or written > len(encoded) - offset:
                raise OSError("Android stream failure receipt write failed")
            offset += written
        os.fsync(descriptor)
    except BaseException:
        try:
            current = destination.lstat()
            if (
                stat.S_ISREG(current.st_mode)
                and (current.st_dev, current.st_ino) == (created.st_dev, created.st_ino)
            ):
                destination.unlink()
        except OSError:
            pass
        raise
    finally:
        os.close(descriptor)


def _remove_raw_reports(root: Optional[Path] = None) -> None:
    root = REPORTS if root is None else root
    try:
        for report in root.rglob("TEST-*.xml"):
            if report.is_symlink() or not report.is_file():
                continue
            report.unlink()
    except OSError:
        # The disposable runner is never allowed to turn cleanup trouble into
        # a different public diagnosis or mask the original test failure.
        return


def _publish_failed_test(
    runner_temp: Path,
    *,
    version: str,
    moonlight_package: Mapping[str, str],
    pin_bridge_stage: Optional[str] = None,
) -> None:
    try:
        diagnostic = failure_diagnostic()
        if pin_bridge_stage is not None:
            if pin_bridge_stage not in _PIN_BRIDGE_STAGES:
                raise StreamAcceptanceFailure("private PIN bridge stage is invalid")
            diagnostic["pinBridgeStage"] = pin_bridge_stage
        write_failure_receipt(
            runner_temp / FAILURE_RECEIPT_NAME,
            version=version,
            moonlight_package=moonlight_package,
            diagnostic=diagnostic,
        )
    finally:
        _remove_raw_reports()


def _capture_failed_test(
    runner_temp: Path,
    *,
    version: str,
    moonlight_package: Mapping[str, str],
    pin_bridge_stage: Optional[str] = None,
) -> None:
    try:
        _publish_failed_test(
            runner_temp,
            version=version,
            moonlight_package=moonlight_package,
            pin_bridge_stage=pin_bridge_stage,
        )
    except Exception:
        # Diagnostics are secondary evidence. Their failure must never replace
        # the connected-test result or change its exit status.
        return


def write_receipt(
    destination: Path,
    *,
    version: str,
    report: Mapping[str, int | str],
    moonlight_package: Mapping[str, str],
    host_proof: Mapping[str, bool],
) -> None:
    expected_host_proof = {
        "touchMouseEffect": True,
        "gamepadEffect": True,
        "providerPairingPresentBeforeDisconnect": True,
        "ownedSunshineStopped": True,
    }
    if dict(host_proof) != expected_host_proof:
        raise StreamAcceptanceFailure("owned stream host proof is incomplete")
    payload = {
        "schemaVersion": 1,
        "gate": "owned_sunshine_android_stream",
        "scope": "twoStreamOscInputDisconnectAndLocalRetirement",
        "sourceRevision": source_revision(ROOT),
        "provider": "Sunshine",
        "providerTag": "v2026.914.233613",
        "emulatorVersion": version,
        "moonlightPackage": dict(moonlight_package),
        "test": dict(report),
        "proof": {
            "productionNsd": True,
            "cryptographicPairing": True,
            "catalogRead": True,
            "launchReadback": True,
            "connectionStarted": True,
            "renderedFrame": True,
            "fullPcmWrite": True,
            "softwareKeyEffect": True,
            "connectionStopped": True,
            "touchMouseEffect": True,
            "gamepadEffect": True,
            "secondConnectionStarted": True,
            "secondRenderedFrame": True,
            "secondFullPcmWrite": True,
            "providerPairingPresentBeforeDisconnect": True,
            "ownedSunshineStopped": True,
            "connectionTerminated": True,
            "remoteDisconnect": True,
            "zeroRedispatch": True,
            "localBindingCleared": True,
            "providerPairingRemoved": False,
        },
        "streamAccepted": True,
        "featureAccepted": False,
        "inputMode": "moonlightOnScreenController",
        "limits": {
            "providerPairingRemoval": "unaccepted",
            "physicalDisplay": "manual",
            "physicalAudio": "manual",
            "physicalPointerDevice": "manual",
            "externalController": "manual",
            "controllerRumble": "manual",
            "gameConsumption": "manual",
            "inputLatency": "manual",
        },
    }
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
    if len(encoded) > 8192:
        raise StreamAcceptanceFailure("Android stream receipt exceeds its bound")
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, encoded)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _run_tone(
    owned: OwnedSunshineHost,
    tone: Path,
    state: dict[str, object],
    cancelled: threading.Event,
) -> None:
    try:
        inject_owned_tone(owned, tone, cancelled=cancelled.is_set)
        state["injected"] = True
    except BaseException as error:
        state["failure"] = error


def _run() -> int:
    version = emulator_version()
    moonlight_package = package_identity()
    for report in REPORTS.rglob("TEST-*.xml"):
        report.unlink()
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    with tempfile.TemporaryDirectory(prefix="f60-stream-prebuild-", dir=runner_temp) as temporary:
        prebuild_gradle = materialized_gradle_command(
            Path(temporary) / "launcher", project_android=ROOT / "android",
        )
        prebuild_android_test(prebuild_gradle)
    nonce = secrets.token_hex(32)
    expected_instance = _sunshine_mdns_instance_name()
    bridge: Optional[OneShotPinBridge] = None
    phase_bridge: Optional[PhaseControlBridge] = None
    xi2: Optional[Xi2KeyWitness] = None
    pin_reverse_installed = False
    control_reverse_installed = False
    with OwnedGamepadAccess(os.environ) as gamepad, OwnedSunshineHost.start(
        stream_profile=True
    ) as owned:
        readiness = owned.public_readiness()
        if readiness.get("state") != "host_ready" or readiness.get("streamAccepted") is not False:
            raise StreamAcceptanceFailure("owned Sunshine host is not ready")
        start_owned_visual(owned)
        tone = owned.material.root / "owned-tone.wav"
        write_owned_tone(tone)
        bridge = OneShotPinBridge(owned, nonce=nonce)
        phase_bridge = PhaseControlBridge(
            owned,
            nonce=nonce,
            paired_client_uuid=lambda: bridge.paired_client_uuid,
            gamepad=gamepad,
        )
        xi2 = Xi2KeyWitness(owned)
        tone_state: dict[str, object] = {}
        tone_cancelled = threading.Event()
        tone_thread = threading.Thread(
            target=_run_tone, args=(owned, tone, tone_state, tone_cancelled),
            name="f60-owned-tone", daemon=True,
        )
        try:
            bridge.start()
            install_adb_reverse(bridge.host_port)
            pin_reverse_installed = True
            phase_bridge.start()
            install_adb_reverse(
                phase_bridge.host_port, android_port=ANDROID_CONTROL_PORT
            )
            control_reverse_installed = True
            xi2.start()
            tone_thread.start()
            with tempfile.TemporaryDirectory(prefix="f60-stream-gradle-", dir=runner_temp) as temporary:
                gradle = materialized_gradle_command(
                    Path(temporary) / "launcher", project_android=ROOT / "android",
                )
                gradle_argv = [
                    *gradle, "--no-daemon", ":app:connectedDebugAndroidTest",
                    f"-Pandroid.testInstrumentationRunnerArguments.class={TEST_CLASS}",
                    "-Pandroid.testInstrumentationRunnerArguments.larenorF60OwnedStream=required",
                    "-Pandroid.testInstrumentationRunnerArguments."
                    f"larenorF60OwnedMdnsInstance={expected_instance}",
                    "-Pandroid.testInstrumentationRunnerArguments."
                    f"larenorF60PinNonce={nonce}",
                    "-Pandroid.testInstrumentationRunnerArguments."
                    f"larenorF60PinPort={ANDROID_PIN_PORT}",
                    "-x", ":app:compileFlutterBuildDebug",
                ]
                try:
                    observation = _run_gradle_with_pin_observation(
                        gradle_argv,
                        bridge,
                        cwd=ROOT / "android",
                        timeout_seconds=PROCESS_TIMEOUT_SECONDS,
                    )
                except (OSError, StreamAcceptanceFailure):
                    _capture_failed_test(
                        runner_temp,
                        version=version,
                        moonlight_package=moonlight_package,
                        pin_bridge_stage=bridge.public_stage(),
                    )
                    raise StreamAcceptanceFailure(
                        "owned Sunshine Android stream failed"
                    ) from None
                if (
                    observation.returncode != 0
                    or observation.timed_out
                    or observation.pin_failure_stage is not None
                ):
                    _capture_failed_test(
                        runner_temp,
                        version=version,
                        moonlight_package=moonlight_package,
                        pin_bridge_stage=(
                            observation.pin_failure_stage or bridge.public_stage()
                        ),
                    )
                    raise StreamAcceptanceFailure("owned Sunshine Android stream failed")
            try:
                bridge.wait()
            except StreamAcceptanceFailure:
                _capture_failed_test(
                    runner_temp,
                    version=version,
                    moonlight_package=moonlight_package,
                    pin_bridge_stage=bridge.public_stage(),
                )
                raise
            phase_bridge.wait()
            tone_thread.join(timeout=CONTROL_TIMEOUT_SECONDS)
            if tone_thread.is_alive() or tone_state.get("injected") is not True:
                raise StreamAcceptanceFailure("owned audio injection proof is incomplete") from tone_state.get("failure")
            xi2.wait()
        finally:
            cleanup_error: Optional[BaseException] = None
            tone_cancelled.set()
            if tone_thread.is_alive():
                tone_thread.join(timeout=12)
            if tone_thread.is_alive():
                cleanup_error = StreamAcceptanceFailure("owned audio injector cleanup failed")
            if control_reverse_installed:
                try:
                    remove_adb_reverse(android_port=ANDROID_CONTROL_PORT)
                except BaseException as error:
                    cleanup_error = error
            if pin_reverse_installed:
                try:
                    remove_adb_reverse()
                except BaseException as error:
                    cleanup_error = error
            if xi2 is not None:
                try:
                    xi2.close()
                except BaseException as error:
                    cleanup_error = cleanup_error or error
            if bridge is not None:
                try:
                    bridge.close()
                except BaseException as error:
                    cleanup_error = cleanup_error or error
            if phase_bridge is not None:
                try:
                    phase_bridge.close()
                except BaseException as error:
                    cleanup_error = cleanup_error or error
            if cleanup_error is not None:
                raise cleanup_error
    report = verify_report()
    if phase_bridge is None:
        raise StreamAcceptanceFailure("private phase bridge proof is incomplete")
    write_receipt(
        runner_temp / RECEIPT_NAME,
        version=version,
        report=report,
        moonlight_package=moonlight_package,
        host_proof={
            "touchMouseEffect": phase_bridge.touch_observed,
            "gamepadEffect": phase_bridge.gamepad_observed,
            "providerPairingPresentBeforeDisconnect": (
                phase_bridge.provider_pairing_present_before_disconnect
            ),
            "ownedSunshineStopped": phase_bridge.sunshine_stopped,
        },
    )
    return 0


def main() -> int:
    def interrupted(_signum: int, _frame: Any) -> None:
        raise KeyboardInterrupt

    previous_term = signal.signal(signal.SIGTERM, interrupted)
    previous_interrupt = signal.signal(signal.SIGINT, interrupted)
    try:
        return _run()
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_interrupt)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except StreamAcceptanceFailure as error:
        print("F60_STREAM_FAILURE:" + str(error), file=os.sys.stderr)
        raise SystemExit(1) from None
    except KeyboardInterrupt:
        print("F60_STREAM_FAILURE:interrupted", file=os.sys.stderr)
        raise SystemExit(130) from None
