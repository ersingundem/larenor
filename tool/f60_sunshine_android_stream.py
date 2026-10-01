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
    OWNED_MDNS_NAME,
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
ANDROID_PIN_PORT = 49_361
ANDROID_CONTROL_PORT = 49_362
PIN_MESSAGE_BYTES = 256
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


class StreamAcceptanceFailure(RuntimeError):
    """A secret-free, fail-closed stream acceptance error."""


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
        self._done = threading.Event()
        self._cancelled = threading.Event()
        self._connection: Optional[socket.socket] = None
        self.pin_approved = False
        self.paired_client_observed = False
        self.paired_client_uuid: Optional[str] = None
        self._thread = threading.Thread(target=self._serve, name="f60-pin-bridge", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def _receive(self, connection: socket.socket) -> bytes:
        connection.settimeout(self._timeout)
        data = bytearray()
        while len(data) <= PIN_MESSAGE_BYTES:
            chunk = connection.recv(min(64, PIN_MESSAGE_BYTES + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            if data.endswith(b"\n"):
                extra = connection.recv(1)
                if extra:
                    raise StreamAcceptanceFailure("private PIN control message is invalid")
                break
        if len(data) > PIN_MESSAGE_BYTES:
            raise StreamAcceptanceFailure("private PIN control message is invalid")
        return bytes(data)

    def _serve(self) -> None:
        try:
            connection, address = self._socket.accept()
            self._connection = connection
            if address[0] != "127.0.0.1":
                raise StreamAcceptanceFailure("private PIN peer identity is invalid")
            with connection:
                pin = parse_pin_message(self._receive(connection), expected_nonce=self.nonce)
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
            self._owned.api.approve_pairing(pairing_id, pin, PAIRING_CLIENT_NAME)
            self.pin_approved = True
            pin = "0000"
            while self._monotonic() < deadline and not self._cancelled.is_set():
                self._owned.processes.require_alive()
                try:
                    self.paired_client_uuid = self._owned.api.owned_client_uuid(
                        PAIRING_CLIENT_NAME
                    )
                    self.paired_client_observed = True
                    return
                except HostFailure:
                    self._sleeper(0.1)
            raise StreamAcceptanceFailure("owned paired client was not observed")
        except BaseException as error:
            self._failure = error
        finally:
            self._done.set()
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
                result = subprocess.run(
                    [
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
                    ],
                    cwd=ROOT / "android", check=False, timeout=PROCESS_TIMEOUT_SECONDS,
                )
                if result.returncode:
                    raise StreamAcceptanceFailure("owned Sunshine Android stream failed")
            bridge.wait()
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
