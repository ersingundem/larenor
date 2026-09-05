#!/usr/bin/env python3
"""Pass through test output; capture one filtered focus failure on CI QEMU only.

No logcat, application data, complete dumpsys output or arbitrary device path is
retained. The one screenshot belongs to the caller's disposable synthetic CI
emulator, never to an attached physical device or a local interactive session.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time
from typing import BinaryIO


MARKER = b"LARENOR_E2E_NATIVE_FOCUS_FAILURE "
MAX_STATE_BYTES = 1024 * 1024
MAX_IMAGE_BYTES = 4 * 1024 * 1024
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
ADB_TIMEOUT_SECONDS = 5


def _adb(serial: str, args: list[str], maximum: int = MAX_STATE_BYTES) -> bytes | None:
    """Cap stdout during reads; share one deadline across reading and exit."""
    process = None
    deadline = time.monotonic() + ADB_TIMEOUT_SECONDS
    try:
        process = subprocess.Popen(
            ["adb", "-s", serial, *args], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0,
        )
        output = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    return None
                # At the limit, read just one byte to distinguish EOF from an
                # overflow. Never buffer the unbounded tail or any stderr.
                chunk = os.read(process.stdout.fileno(), min(65536, maximum - len(output) + 1))
                if not chunk:
                    break
                if len(output) + len(chunk) > maximum:
                    return None
                output.extend(chunk)
        remaining = deadline - time.monotonic()
        if remaining <= 0 or process.wait(timeout=remaining) != 0:
            return None
        return bytes(output)
    except (OSError, subprocess.TimeoutExpired):
        return None
    finally:
        if process is not None:
            # Overflow, timeout and read errors all release the pipe and reap
            # the child. No communicate() call can accumulate a rejected tail.
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()


def _booleans(text: str, names: tuple[str, ...]) -> dict[str, bool]:
    values = {}
    for name in names:
        match = re.search(r"\b" + re.escape(name) + r"\s*=\s*(true|false)\b", text)
        if match:
            values[name] = match[1] == "true"
    return values


def summarize_power(raw: bytes | None) -> dict:
    if raw is None:
        return {"available": False}
    text = raw.decode("utf-8", errors="replace")
    result = {"available": True, **_booleans(text, ("mIsPowered", "mStayOn", "mWakefulnessChanging"))}
    wakefulness = re.search(r"\bmWakefulness\s*=\s*(Awake|Asleep|Dreaming|Dozing)\b", text)
    if wakefulness:
        result["wakefulness"] = wakefulness[1]
    display = re.search(r"Display Power:\s*state=(ON|OFF|DOZE|DOZE_SUSPEND)\b", text)
    if display:
        result["displayState"] = display[1]
    return result


def _focus_owner(value: str) -> str:
    if value.strip() == "null":
        return "none"
    if "Application Error" in value or "Application Not Responding" in value:
        return "application_error_dialog"
    if "com.ersingundem.larenor/" in value:
        return "larenor"
    if "com.android.systemui" in value or "StatusBar" in value or "NotificationShade" in value:
        return "system_ui"
    if "permissioncontroller" in value:
        return "permission_dialog"
    if "ResolverActivity" in value or "ChooserActivity" in value:
        return "resolver_dialog"
    if "launcher" in value.lower():
        return "launcher"
    return "other"


def summarize_windows(raw: bytes | None) -> dict:
    if raw is None:
        return {"available": False}
    text = raw.decode("utf-8", errors="replace")
    result = {"available": True}
    # Only classifications leave this function, never window titles, text,
    # intent URIs, clipboard contents, package lists or raw dumpsys lines.
    for name in ("mCurrentFocus", "mFocusedApp"):
        matches = re.findall(r"^\s*" + name + r"\s*=(.*)$", text, re.MULTILINE)
        result[name] = [_focus_owner(value) for value in matches[:4]]
    return result


def summarize_policy(raw: bytes | None) -> dict:
    if raw is None:
        return {"available": False}
    return {"available": True, **_booleans(raw.decode("utf-8", errors="replace"), (
        "mAwake", "mScreenOnEarly", "mScreenOnFully", "mShowingLockscreen",
        "mDreamingLockscreen", "mKeyguardShowing", "mKeyguardOccluded",
        "showing", "occluded", "inputRestricted",
    ))}


def capture(serial: str, output: Path) -> bool:
    if os.environ.get("GITHUB_ACTIONS") != "true" or not re.fullmatch(r"emulator-[0-9]+", serial):
        return False
    if _adb(serial, ["shell", "getprop", "ro.kernel.qemu"], maximum=32) not in (b"1\n", b"1\r\n"):
        return False
    # Capture the screen before potentially slower system-service reads. The
    # Flutter process is not paused or repaired by this diagnostic observer.
    image = _adb(serial, ["exec-out", "screencap", "-p"], maximum=MAX_IMAGE_BYTES)
    state = {
        "scope": "disposable_ci_emulator_native_focus_failure",
        "power": summarize_power(_adb(serial, ["shell", "dumpsys", "power"])),
        "windows": summarize_windows(_adb(serial, ["shell", "dumpsys", "window", "windows"])),
        "policy": summarize_policy(_adb(serial, ["shell", "dumpsys", "window", "policy"])),
    }
    state["screenshotAvailable"] = image is not None and image.startswith(PNG_SIGNATURE)
    output.mkdir(parents=True, exist_ok=True)
    if state["screenshotAvailable"]:
        (output / "native-focus.png").write_bytes(image)
    (output / "native-focus.json").write_text(json.dumps(state, indent=2) + "\n")
    return True


def relay(serial: str, source: BinaryIO, destination: BinaryIO, output: Path) -> None:
    seen = False
    # readline(size) caps memory even for a broken process emitting no newlines.
    for line in iter(lambda: source.readline(65536), b""):
        destination.write(line)
        destination.flush()
        if not seen and MARKER in line:
            seen = True
            try:
                captured = capture(serial, output)
            except (OSError, ValueError):
                captured = False
            message = (b"CI native focus snapshot captured.\n" if captured else
                       b"CI native focus snapshot unavailable.\n")
            destination.write(message)
            destination.flush()


if __name__ == "__main__":
    relay(sys.argv[1] if len(sys.argv) == 2 else "", sys.stdin.buffer,
          sys.stdout.buffer, Path("build/e2e"))
