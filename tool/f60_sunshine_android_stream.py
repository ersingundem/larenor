#!/usr/bin/env python3
"""Run the named packaged-Android stream gate against an owned Sunshine host.

The only private control wire carries the one-time Moonlight PIN from the
instrumentation process to this owned host. Provider addresses, credentials,
certificates, PINs, native identifiers, media, and raw provider output never
enter the public receipt.
"""

from __future__ import annotations

from dataclasses import dataclass
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
from tool.f60_sunshine_android_discovery import emulator_version, package_identity
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
TEST_NAME = "productionNsdPairCatalogLaunchStreamWitnessStopAndLocalRetirement"
RECEIPT_NAME = "f60-sunshine-android-stream-receipt.json"
ANDROID_PIN_PORT = 49_361
PIN_MESSAGE_BYTES = 256
PAIRING_CLIENT_NAME = "roth"
CONTROL_TIMEOUT_SECONDS = 300.0
PROCESS_TIMEOUT_SECONDS = 1_800
PREBUILD_TIMEOUT_SECONDS = 1_200
MAX_COMMAND_OUTPUT = 64 * 1024
SUNSHINE_STEREO_SINK = "sink-sunshine-stereo"
KEY_A_CODE = 38


class StreamAcceptanceFailure(RuntimeError):
    """A secret-free, fail-closed stream acceptance error."""


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
        self._process: Optional[subprocess.Popen[str]] = None
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
                text=True,
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
            event: Optional[str] = None
            pressed = False
            total = 0
            for line in self._process.stdout:
                total += len(line.encode("utf-8"))
                if total > MAX_COMMAND_OUTPUT:
                    raise StreamAcceptanceFailure("owned XI2 observation is too large")
                match = re.fullmatch(r"EVENT type [0-9]+ \((KeyPress|KeyRelease)\)\n", line)
                if match:
                    event = match.group(1)
                    continue
                detail = re.fullmatch(r"\s+detail: ([0-9]+)\n", line)
                if detail is None or int(detail.group(1)) != KEY_A_CODE:
                    continue
                if event == "KeyPress":
                    pressed = True
                elif event == "KeyRelease" and pressed:
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


def install_adb_reverse(host_port: int, *, runner: Callable[..., Any] = subprocess.run) -> None:
    if not 1 <= host_port <= 65_535:
        raise StreamAcceptanceFailure("private PIN bridge port is invalid")
    try:
        completed = runner(
            ["adb", "reverse", "tcp:" + str(ANDROID_PIN_PORT), "tcp:" + str(host_port)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise StreamAcceptanceFailure("private PIN reverse transport is unavailable") from error
    if completed.returncode != 0:
        raise StreamAcceptanceFailure("private PIN reverse transport is unavailable")


def remove_adb_reverse(*, runner: Callable[..., Any] = subprocess.run) -> None:
    try:
        completed = runner(
            ["adb", "reverse", "--remove", "tcp:" + str(ANDROID_PIN_PORT)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise StreamAcceptanceFailure("private PIN reverse transport cleanup failed") from error
    if completed.returncode != 0:
        raise StreamAcceptanceFailure("private PIN reverse transport cleanup failed")


def prebuild_android_test(
    gradle: Sequence[str],
    *,
    runner: Callable[..., Any] = subprocess.run,
) -> None:
    if not gradle or any(not isinstance(value, str) or not value for value in gradle):
        raise StreamAcceptanceFailure("Android stream Gradle launcher is invalid")
    try:
        completed = runner(
            [
                *gradle,
                "--no-daemon",
                ":app:assembleDebug",
                ":app:assembleDebugAndroidTest",
                "-x",
                ":app:compileFlutterBuildDebug",
            ],
            cwd=ROOT / "android",
            check=False,
            timeout=PREBUILD_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise StreamAcceptanceFailure("owned Sunshine Android prebuild failed") from error
    if completed.returncode != 0:
        raise StreamAcceptanceFailure("owned Sunshine Android prebuild failed")


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
    if suite.tag != "testsuite" or any(
        suite.attrib.get(key) != value
        for key, value in {"tests": "1", "failures": "0", "errors": "0", "skipped": "0"}.items()
    ) or len(list(suite.iter("testsuite"))) != 1:
        raise StreamAcceptanceFailure("Android stream report aggregate is invalid")
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
) -> None:
    payload = {
        "schemaVersion": 1,
        "gate": "owned_sunshine_android_stream",
        "scope": "streamAndLocalRetirement",
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
            "localBindingCleared": True,
            "providerPairingRemoved": False,
        },
        "streamAccepted": True,
        "featureAccepted": False,
        "limits": {
            "providerPairingRemoval": "unaccepted",
            "physicalDisplay": "manual",
            "physicalAudio": "manual",
            "physicalController": "manual",
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
    xi2: Optional[Xi2KeyWitness] = None
    reverse_installed = False
    with OwnedSunshineHost.start(stream_profile=True) as owned:
        readiness = owned.public_readiness()
        if readiness.get("state") != "host_ready" or readiness.get("streamAccepted") is not False:
            raise StreamAcceptanceFailure("owned Sunshine host is not ready")
        start_owned_visual(owned)
        tone = owned.material.root / "owned-tone.wav"
        write_owned_tone(tone)
        bridge = OneShotPinBridge(owned, nonce=nonce)
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
            reverse_installed = True
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
            tone_thread.join(timeout=CONTROL_TIMEOUT_SECONDS)
            if tone_thread.is_alive() or tone_state.get("injected") is not True:
                raise StreamAcceptanceFailure("owned audio injection proof is incomplete") from tone_state.get("failure")
            xi2.wait()
            if bridge.paired_client_uuid is None:
                raise StreamAcceptanceFailure("owned paired client proof is incomplete")
            owned.api.require_owned_client_present(
                PAIRING_CLIENT_NAME, bridge.paired_client_uuid
            )
            owned.processes.require_alive()
        finally:
            cleanup_error: Optional[BaseException] = None
            tone_cancelled.set()
            if tone_thread.is_alive():
                tone_thread.join(timeout=12)
            if tone_thread.is_alive():
                cleanup_error = StreamAcceptanceFailure("owned audio injector cleanup failed")
            if reverse_installed:
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
            if cleanup_error is not None:
                raise cleanup_error
    report = verify_report()
    write_receipt(
        runner_temp / RECEIPT_NAME,
        version=version,
        report=report,
        moonlight_package=moonlight_package,
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
