#!/usr/bin/env python3
"""Bounded preparation for an explicitly identified disposable AVD.

This does not diagnose why a setting failed to persist. No device output or
stderr is logged. CI also disables the verified AOSP Quickstep home package so
its system ANR dialog cannot take focus from long application journeys.
"""

import os
import re
import selectors
import subprocess
import sys
import time
from typing import NamedTuple


TOTAL_SECONDS = 20
COMMAND_SECONDS = 5
MAX_ATTEMPTS = 5
RETRY_SECONDS = 1
MAX_OUTPUT_BYTES = 256
LAUNCHER_TOTAL_SECONDS = 20
LAUNCHER_COMMAND_SECONDS = 5
LAUNCHER_MAX_ATTEMPTS = 3
_AOSP_HOME_PACKAGE = b"package:com.android.launcher3"


class Outcome(NamedTuple):
    result: str
    attempts: int = 0
    last_observation: str = "unknown"


def _adb(serial, args, deadline):
    """Read at most 256 bytes, kill/reap on any failure and share one deadline."""
    process = None
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
                chunk = os.read(process.stdout.fileno(), MAX_OUTPUT_BYTES - len(output) + 1)
                if not chunk:
                    break
                if len(output) + len(chunk) > MAX_OUTPUT_BYTES:
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
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()


def ensure_awake(serial, *, command=_adb, clock=time.monotonic, sleep=time.sleep):
    if not re.fullmatch(r"emulator-[0-9]+", serial):
        return Outcome("invalid_emulator")
    deadline = clock() + TOTAL_SECONDS

    def run(args):
        return command(serial, args, min(deadline, clock() + COMMAND_SECONDS))

    qemu = run(["shell", "getprop", "ro.kernel.qemu"])
    if clock() >= deadline:
        return Outcome("deadline")
    if qemu is None:
        return Outcome("adb_failed")
    if qemu.rstrip(b"\r\n") != b"1":
        return Outcome("invalid_emulator")

    attempts = 0
    observation = "unknown"
    while attempts < MAX_ATTEMPTS:
        if clock() >= deadline:
            return Outcome("deadline", attempts, observation)
        attempts += 1
        applied = run(["shell", "svc", "power", "stayon", "true"])
        if clock() >= deadline:
            return Outcome("deadline", attempts, observation)
        if applied is None:
            return Outcome("adb_failed", attempts, observation)
        value = run(["shell", "settings", "get", "global", "stay_on_while_plugged_in"])
        if clock() >= deadline:
            return Outcome("deadline", attempts, observation)
        if value is None:
            return Outcome("adb_failed", attempts, observation)
        value = value.rstrip(b"\r\n")
        if value in (b"7", b"15"):
            return Outcome("verified", attempts, "enabled")
        observation = {b"0": "zero", b"null": "unset", b"": "empty"}.get(value, "invalid")
        if attempts < MAX_ATTEMPTS:
            sleep(min(RETRY_SECONDS, max(0, deadline - clock())))
    return Outcome("not_enabled", attempts, observation)


def disable_ci_quickstep(
    serial, *, command=_adb, clock=time.monotonic, sleep=time.sleep,
    environment=os.environ,
):
    """Disable only the resolved AOSP launcher on a GitHub Actions QEMU AVD."""
    if environment.get("GITHUB_ACTIONS") != "true":
        return Outcome("skipped")
    if not re.fullmatch(r"emulator-[0-9]+", serial):
        return Outcome("invalid_emulator")
    deadline = clock() + LAUNCHER_TOTAL_SECONDS

    def run(args):
        return command(
            serial,
            args,
            min(deadline, clock() + LAUNCHER_COMMAND_SECONDS),
        )

    qemu = run(["shell", "getprop", "ro.kernel.qemu"])
    if qemu is None:
        return Outcome("adb_failed")
    if qemu.rstrip(b"\r\n") != b"1":
        return Outcome("invalid_emulator")
    attempts = 0
    home_package = None
    while attempts < LAUNCHER_MAX_ATTEMPTS:
        if clock() >= deadline:
            return Outcome("deadline", attempts)
        attempts += 1
        home_package = run([
            "shell", "pm", "list", "packages", "-s", "--user", "0",
            "com.android.launcher3",
        ])
        if home_package is not None:
            break
        if attempts < LAUNCHER_MAX_ATTEMPTS:
            sleep_seconds = min(RETRY_SECONDS, max(0, deadline - clock()))
            sleep(sleep_seconds)
    if home_package is None:
        return Outcome("adb_failed", attempts)
    if home_package.rstrip(b"\r\n") != _AOSP_HOME_PACKAGE:
        return Outcome("unexpected_home")
    disabled = run([
        "shell", "pm", "disable-user", "--user", "0",
        "com.android.launcher3",
    ])
    if disabled is None:
        return Outcome("adb_failed")
    verified = run([
        "shell", "pm", "list", "packages", "--user", "0", "-d",
        "com.android.launcher3",
    ])
    if verified is None:
        return Outcome("adb_failed")
    if verified.rstrip(b"\r\n") != b"package:com.android.launcher3":
        return Outcome("not_disabled")
    return Outcome("verified", attempts, "aosp_quickstep_disabled")


def main():
    serial = sys.argv[1] if len(sys.argv) == 2 else ""
    result = ensure_awake(serial)
    # All fields are locally generated enums or a bounded attempt count.
    print(f"E2E stay-awake precondition: result={result.result} "
          f"attempts={result.attempts} last_observation={result.last_observation}",
          file=sys.stdout if result.result == "verified" else sys.stderr)
    if result.result != "verified":
        return 2
    launcher = disable_ci_quickstep(serial)
    print(
        f"E2E launcher precondition: result={launcher.result} "
        f"attempts={launcher.attempts} last_observation={launcher.last_observation}",
        file=(sys.stdout if launcher.result in ("verified", "skipped") else sys.stderr),
    )
    return 0 if launcher.result in ("verified", "skipped") else 2


if __name__ == "__main__":
    sys.exit(main())
