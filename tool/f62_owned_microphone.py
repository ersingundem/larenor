#!/usr/bin/env python3
"""Isolated Pulse source for the owned F62 emulator; never captures host hardware."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import signal
import select
import stat
import struct
import subprocess
import time


NONCE = re.compile(r"[0-9a-f]{64}")
NAME = re.compile(r"[A-Za-z0-9_/.-]{1,512}")
RATE = 44100
FRAMES = RATE * 3


class MicrophoneFixtureError(ValueError):
    pass


def require(value, code):
    if not value:
        raise MicrophoneFixtureError(code)


def private_file(path: Path, payload: bytes):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(payload)
            stream.flush()
        os.fsync(fd)
    finally:
        os.close(fd)


def private_directory(path: Path):
    require(path.is_absolute() and not path.is_symlink(), "invalid_private_directory")
    info = path.stat()
    require(stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700
            and info.st_uid == os.getuid(), "invalid_private_directory")
    require(NAME.fullmatch(str(path)) is not None, "invalid_private_directory")


def pulse_environment(path: Path):
    private_directory(path)
    return {**os.environ, "PULSE_SERVER": f"unix:{path}/native",
            "PULSE_SOURCE": "larenor_owned_microphone.monitor",
            "PULSE_SINK": "larenor_owned_output",
            "PULSE_CLIENTCONFIG": str(path / "client.conf")}


def _process_start(pid: int):
    try:
        # comm can contain spaces and parentheses; split after its last ')'.
        data = Path(f"/proc/{pid}/stat").read_text()
        return data[data.rindex(")") + 2:].split()[19]
    except (OSError, ValueError, IndexError):
        raise MicrophoneFixtureError("owned_pulse_identity_unavailable") from None


def prepare(path: Path):
    require(not path.exists() and not path.is_symlink(), "output_must_not_exist")
    path.mkdir(mode=0o700)
    private_directory(path)
    private_file(path / "default.pa", (
        f"load-module module-native-protocol-unix socket={path}/native auth-anonymous=1\n"
        "load-module module-null-sink sink_name=larenor_owned_microphone rate=44100 channels=2\n"
        "load-module module-null-sink sink_name=larenor_owned_output rate=44100 channels=2\n"
        "set-default-source larenor_owned_microphone.monitor\n"
        "set-default-sink larenor_owned_output\n"
    ).encode("ascii"))
    private_file(path / "client.conf", (
        f"default-server = unix:{path}/native\n"
        "default-source = larenor_owned_microphone.monitor\n"
        "default-sink = larenor_owned_output\nautospawn = no\n"
    ).encode("ascii"))
    env = pulse_environment(path)
    env.pop("RUNNER_TRACKING_ID", None)
    env["XDG_RUNTIME_DIR"] = str(path)
    log = os.open(path / "pulse.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    process = None
    try:
        process = subprocess.Popen([
            "/usr/bin/pulseaudio", "--daemonize=no", "--exit-idle-time=-1", "--disallow-exit",
            "--use-pid-file=no", "--disable-shm", "--log-level=error", "-n", "-F",
            str(path / "default.pa"),
        ], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        identity = {"schemaVersion": 1, "pid": process.pid, "start": _process_start(process.pid)}
        private_file(path / "process.json", (json.dumps(identity, sort_keys=True) + "\n").encode())
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            require(process.poll() is None, "owned_pulse_start_failed")
            socket = path / "native"
            if socket.exists():
                require(not socket.is_symlink() and stat.S_ISSOCK(socket.stat().st_mode),
                        "owned_pulse_socket_invalid")
                result = subprocess.run(["/usr/bin/pactl", "list", "short", "sources"],
                    env=env, capture_output=True, timeout=5, check=False)
                require(result.returncode == 0 and len(result.stdout) <= 4096,
                        "owned_pulse_source_unavailable")
                sources = [line.split(b"\t")[1] for line in result.stdout.splitlines()]
                require(sorted(sources) == [b"larenor_owned_microphone.monitor",
                                           b"larenor_owned_output.monitor"],
                        "owned_pulse_source_unavailable")
                return
            time.sleep(0.1)
        raise MicrophoneFixtureError("owned_pulse_start_failed")
    except BaseException:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        raise
    finally:
        os.close(log)


def verified_pulse(path: Path):
    private_directory(path)
    record = path / "process.json"
    require(not record.is_symlink(), "owned_pulse_identity_invalid")
    info = record.stat()
    require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
            and info.st_uid == os.getuid() and info.st_size <= 256, "owned_pulse_identity_invalid")
    value = json.loads(record.read_text())
    require(isinstance(value, dict) and set(value) == {"schemaVersion", "pid", "start"}
            and type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
            and type(value["pid"]) is int
            and value["pid"] > 1 and isinstance(value["start"], str)
            and re.fullmatch(r"[0-9]{1,20}", value["start"]), "owned_pulse_identity_invalid")
    require(_process_start(value["pid"]) == value["start"], "owned_pulse_identity_changed")
    command = Path(f"/proc/{value['pid']}/cmdline").read_bytes().split(b"\0")
    require(command[0] == b"/usr/bin/pulseaudio" and str(path / "default.pa").encode() in command,
            "owned_pulse_identity_changed")
    return value["pid"]


def stop(path: Path):
    pid = verified_pulse(path)
    require(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"),
            "owned_pulse_pidfd_unavailable")
    fd = os.pidfd_open(pid)
    try:
        # Recheck start/config identity after acquiring a stable kernel process handle.
        verified_pulse(path)
        signal.pidfd_send_signal(fd, signal.SIGTERM)
        poller = select.poll()
        poller.register(fd, select.POLLIN)
        if poller.poll(5000):
            return
        verified_pulse(path)
        signal.pidfd_send_signal(fd, signal.SIGKILL)
        require(bool(poller.poll(5000)), "owned_pulse_stop_unconfirmed")
    finally:
        os.close(fd)


def tone_bytes(nonce: str):
    require(isinstance(nonce, str) and NONCE.fullmatch(nonce) is not None, "invalid_nonce")
    period = 32 + int(nonce[:4], 16) % 64
    data = bytearray(FRAMES * 4)
    for frame in range(FRAMES):
        sample = 8192 if frame % period < period // 2 else -8192
        struct.pack_into("<hh", data, frame * 4, sample, sample)
    return data


def start_tone(path: Path, nonce: str, private: Path):
    verified_pulse(path)
    private_directory(private)
    data = tone_bytes(nonce)
    tone = private / "owned-microphone-tone.pcm"
    try:
        private_file(tone, data)
    finally:
        data[:] = bytes(len(data))
    env = pulse_environment(path)
    try:
        return subprocess.Popen([
            "/usr/bin/paplay", "--raw", "--rate=44100", "--channels=2", "--format=s16le",
            "--device=larenor_owned_microphone", str(tone),
        ], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
           stderr=subprocess.DEVNULL, start_new_session=True)
    except BaseException:
        tone.unlink(missing_ok=True)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "stop"))
    parser.add_argument("path", type=Path)
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        {"prepare": prepare, "stop": stop}[args.action](args.path)
    except (MicrophoneFixtureError, OSError, ValueError, subprocess.SubprocessError):
        parser.exit(2, "owned_microphone_fixture_failed\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
