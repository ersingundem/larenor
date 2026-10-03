"""Exercise the real XI2 observer on a disposable Linux Xvfb display.

This diagnoses the host-side input observer only. It is never Moonlight,
Sunshine, Android input, or feature acceptance evidence.
"""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time

from tool.f60_sunshine_android_stream import (
    DISPLAY,
    ROOT,
    StreamAcceptanceFailure,
    Xi2KeyWitness,
    Xi2PointerWitness,
    Xi2PointerWitnessFailure,
    _probe_owned_x11_pointer,
    _pointer_witness_after_owned_key,
)
from tool.native_acceptance_receipt import source_revision


@dataclass(frozen=True)
class ProbeMaterial:
    root: Path
    home: Path
    runtime: Path


@dataclass(frozen=True)
class ProbeOwner:
    material: ProbeMaterial


def _click_owned_display() -> None:
    x11 = ctypes.CDLL("libX11.so.6")
    xtst = ctypes.CDLL("libXtst.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    xtst.XTestFakeButtonEvent.argtypes = [
        ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong,
    ]
    xtst.XTestFakeButtonEvent.restype = ctypes.c_int
    display = x11.XOpenDisplay(DISPLAY.encode("ascii"))
    if not display:
        raise StreamAcceptanceFailure("owned pointer probe display unavailable")
    try:
        _probe_owned_x11_pointer(70, 80)
        if not xtst.XTestFakeButtonEvent(display, 1, 1, 0):
            raise StreamAcceptanceFailure("owned pointer probe button unavailable")
        x11.XSync(display, 0)
        _probe_owned_x11_pointer(170, 180)
        if not xtst.XTestFakeButtonEvent(display, 1, 0, 0):
            raise StreamAcceptanceFailure("owned pointer probe button unavailable")
        x11.XSync(display, 0)
    finally:
        x11.XCloseDisplay(display)


def _type_owned_key() -> None:
    x11 = ctypes.CDLL("libX11.so.6")
    xtst = ctypes.CDLL("libXtst.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    xtst.XTestFakeKeyEvent.argtypes = [
        ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong,
    ]
    xtst.XTestFakeKeyEvent.restype = ctypes.c_int
    display = x11.XOpenDisplay(DISPLAY.encode("ascii"))
    if not display:
        raise StreamAcceptanceFailure("owned key probe display unavailable")
    try:
        for pressed in (1, 0):
            if not xtst.XTestFakeKeyEvent(display, 38, pressed, 0):
                raise StreamAcceptanceFailure("owned key probe event unavailable")
            x11.XSync(display, 0)
    finally:
        x11.XCloseDisplay(display)


def run_probe() -> dict[str, object]:
    receipt: dict[str, object] = {
        "schemaVersion": 1,
        "gate": "owned_xi2_observer_only",
        "sourceRevision": source_revision(ROOT),
        "stage": "preflight",
        "result": "failed",
        "listenerReady": False,
        "pointerAndButtonObserved": False,
        "keyObserved": False,
        "keyListenerReaped": False,
        "overlapFailure": "none",
        "failureCode": "none",
        "featureAccepted": False,
    }
    if platform.system() != "Linux" or any(os.path.lexists(path) for path in (
        "/tmp/.X11-unix/X99", "/tmp/.X99-lock",
    )):
        return receipt
    with tempfile.TemporaryDirectory(prefix="larenor-owned-xi2-") as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        home = root / "home"
        runtime = root / "runtime"
        home.mkdir(mode=0o700)
        runtime.mkdir(mode=0o700)
        owner = ProbeOwner(ProbeMaterial(root, home, runtime))
        witness = None
        key = None
        overlap = None
        server = None
        try:
            server = subprocess.Popen(
                ["/usr/bin/Xvfb", DISPLAY, "-screen", "0", "1280x720x24",
                 "-nolisten", "tcp", "-ac", "-noreset"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, cwd=root, close_fds=True,
            )
            receipt["stage"] = "displayReady"
            deadline = time.monotonic() + 5
            while True:
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise StreamAcceptanceFailure("owned pointer probe display unavailable")
                probe = subprocess.run(
                    ["/usr/bin/xdpyinfo", "-display", DISPLAY],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, check=False, timeout=1,
                )
                if probe.returncode == 0:
                    break
                time.sleep(0.05)
            receipt["stage"] = "keyListener"
            key = Xi2KeyWitness(owner)
            key.start()
            receipt["stage"] = "keyEffect"
            # The key reader has no startup ACK. This non-accepting observer
            # probe repeats only its disposable XTest key until the real reader
            # completes, before measuring an overlapping selection.
            key_deadline = time.monotonic() + 5
            while time.monotonic() < key_deadline:
                _type_owned_key()
                if key._done.wait(0.05):
                    break
            key.wait(timeout_seconds=0.05)
            # Diagnose the actual two-listener topology before its ordered
            # handoff. Only a closed error class escapes, never X/device output.
            receipt["stage"] = "overlapListener"
            overlap = Xi2PointerWitness(owner, readiness_timeout_seconds=1)
            try:
                overlap.start()
            except Xi2PointerWitnessFailure as error:
                receipt["overlapFailure"] = error.public_code
            finally:
                overlap.close()
                overlap = None
            receipt["stage"] = "listenerHandoff"
            witness = _pointer_witness_after_owned_key(owner, key, timeout_seconds=5)
            receipt["keyObserved"] = key.observed
            if key._process is None or key._process.poll() is None:
                raise StreamAcceptanceFailure("owned key probe process was not reaped")
            receipt["keyListenerReaped"] = True
            receipt["stage"] = "listenerReady"
            witness.start()
            if server.poll() is not None:
                raise StreamAcceptanceFailure("owned pointer probe display unavailable")
            receipt["listenerReady"] = True
            receipt["stage"] = "pointerEffect"
            _click_owned_display()
            witness.wait(5)
            if server.poll() is not None:
                raise StreamAcceptanceFailure("owned pointer probe display unavailable")
            receipt["pointerAndButtonObserved"] = True
            receipt["result"] = "passed"
            receipt["stage"] = "complete"
        except (StreamAcceptanceFailure, OSError, subprocess.SubprocessError) as error:
            # The finite failing stage is enough; no display/device output escapes.
            receipt["failureCode"] = {
                "owned X11 keymap is invalid": "keymapInvalid",
                "owned XI2 witness could not start": "keyListenerSpawn",
                "owned XI2 key effect was not observed": "keyEffectMissing",
            }.get(str(error), "observerFailure")
        finally:
            try:
                if witness is not None:
                    witness.close()
                if overlap is not None:
                    overlap.close()
                if key is not None:
                    key.close()
            except (StreamAcceptanceFailure, OSError):
                receipt["result"] = "failed"
                receipt["stage"] = "cleanup"
            try:
                if server is not None and server.poll() is None:
                    server.terminate()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=5)
                        receipt["result"] = "failed"
                        receipt["stage"] = "cleanup"
            except (OSError, subprocess.SubprocessError):
                receipt["result"] = "failed"
                receipt["stage"] = "cleanup"
    return receipt


if __name__ == "__main__":
    os.umask(0o077)
    result = run_probe()
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    raise SystemExit(0 if result["result"] == "passed" else 1)
