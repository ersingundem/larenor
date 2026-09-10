"""Bounded lifecycle supervisor for the non-root Proxmox power worker."""

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import sys
import threading
import time

from .worker_runtime import (
    ProxmoxWorkerRuntimeError, WorkerRuntimeConfig, read_health_receipt,
)


class ProxmoxWorkerSupervisorError(Exception):
    def __init__(self):
        super().__init__("supervisor_unavailable")


@dataclass(frozen=True)
class SupervisorConfig:
    runtime: WorkerRuntimeConfig
    max_restarts: int = 3
    initial_backoff: float = 0.1
    max_backoff: float = 0.4
    poll_interval: float = 0.05
    shutdown_timeout: float = 5.0

    def __post_init__(self):
        if (
            not isinstance(self.runtime, WorkerRuntimeConfig)
            or type(self.max_restarts) is not int or not 0 <= self.max_restarts <= 5
            or any(type(value) not in (int, float) or isinstance(value, bool)
                   for value in (self.initial_backoff, self.max_backoff,
                                 self.poll_interval, self.shutdown_timeout))
            or not 0 < self.initial_backoff <= self.max_backoff <= 2
            or not 0 < self.poll_interval <= 0.25
            or not 0.5 <= self.shutdown_timeout <= 10
        ):
            raise ProxmoxWorkerSupervisorError()

    @classmethod
    def from_runtime(cls, runtime):
        return cls(runtime)

    @property
    def command(self):
        runtime = self.runtime
        command = [
            sys.executable, "-m",
            "larenor_server.proxmox_commands.worker_runtime",
            "--socket", str(runtime.socket_path),
            "--health-receipt", str(runtime.health_path),
            "--credential-file", str(runtime.credential_path),
        ]
        if runtime.binding_key_path is not None:
            command.extend(("--binding-key-file", str(runtime.binding_key_path)))
        command.extend(("--api-uid", str(runtime.api_uid)))
        return tuple(command)


def cleanup_exact_socket(path, identity, owner_uid):
    try:
        selected = Path(path)
        if (
            type(identity) is not tuple or len(identity) != 2
            or any(type(value) is not int or value < 0 for value in identity)
            or type(owner_uid) is not int or owner_uid < 1
        ):
            return False
        info = selected.lstat()
        if (
            stat.S_ISLNK(info.st_mode) or not stat.S_ISSOCK(info.st_mode)
            or info.st_uid != owner_uid
            or stat.S_IMODE(info.st_mode) != 0o600
            or (info.st_dev, info.st_ino) != identity
        ):
            return False
        selected.unlink()
        directory = os.open(selected.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        return True
    except OSError:
        return False


def check_health(runtime):
    try:
        if not isinstance(runtime, WorkerRuntimeConfig):
            return False
        receipt = read_health_receipt(runtime.health_path)
        info = runtime.socket_path.lstat()
        return (
            receipt.state == "ready"
            and receipt.worker_uid == os.geteuid() == runtime.api_uid
            and stat.S_ISSOCK(info.st_mode)
            and not stat.S_ISLNK(info.st_mode)
            and info.st_uid == receipt.worker_uid
            and stat.S_IMODE(info.st_mode) == 0o600
            and (info.st_dev, info.st_ino)
            == (receipt.socket_device, receipt.socket_inode)
        )
    except (OSError, ProxmoxWorkerRuntimeError):
        return False


class ProxmoxWorkerSupervisor:
    def __init__(self, config, *, launch=None, sleep=None):
        if not isinstance(config, SupervisorConfig):
            raise ProxmoxWorkerSupervisorError()
        self.config = config
        self.launch = launch or self._launch
        self.sleep = sleep or time.sleep

    @staticmethod
    def _launch(command):
        try:
            return subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                start_new_session=False,
            )
        except OSError:
            raise ProxmoxWorkerSupervisorError() from None

    def _cleanup_child_socket(self):
        try:
            receipt = read_health_receipt(self.config.runtime.health_path)
        except ProxmoxWorkerRuntimeError:
            return False
        if receipt.state != "ready" or receipt.worker_uid != os.geteuid():
            return False
        return cleanup_exact_socket(
            self.config.runtime.socket_path,
            (receipt.socket_device, receipt.socket_inode),
            receipt.worker_uid,
        )

    def _stop(self, process):
        process.terminate()
        try:
            process.wait(timeout=self.config.shutdown_timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=self.config.shutdown_timeout)

    def run(self, stopped):
        if not isinstance(stopped, threading.Event):
            raise ProxmoxWorkerSupervisorError()
        restarts = 0
        while not stopped.is_set():
            try:
                process = self.launch(self.config.command)
            except Exception:
                process = None
            if process is None:
                code = 1
            else:
                while True:
                    if stopped.is_set():
                        try:
                            self._stop(process)
                        except Exception:
                            return 1
                        self._cleanup_child_socket()
                        return 0
                    code = process.poll()
                    if code is not None:
                        break
                    self.sleep(self.config.poll_interval)
                self._cleanup_child_socket()
            if code == 0:
                return 0
            if restarts >= self.config.max_restarts:
                return 1
            delay = min(
                self.config.initial_backoff * (2 ** restarts),
                self.config.max_backoff,
            )
            restarts += 1
            self.sleep(delay)
        return 0


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise ProxmoxWorkerSupervisorError()


def _uid(value):
    if not re.fullmatch(r"[0-9]{1,10}", value) or int(value) >= 2**31:
        raise argparse.ArgumentTypeError()
    return int(value)


def main(argv=None):
    parser = _Parser(prog="larenor-proxmox-power-supervisor", description=__doc__)
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--health-receipt", required=True, type=Path)
    parser.add_argument("--credential-file", required=True, type=Path)
    parser.add_argument("--binding-key-file", type=Path)
    parser.add_argument("--api-uid", required=True, type=_uid)
    parser.add_argument("--check-health", action="store_true")
    try:
        args = parser.parse_args(argv)
        runtime = WorkerRuntimeConfig(
            args.socket, args.health_receipt, args.credential_file, args.api_uid,
            args.binding_key_file,
        )
        selected = SupervisorConfig.from_runtime(runtime)
        if os.getuid() != os.geteuid() or os.geteuid() == 0:
            raise ProxmoxWorkerSupervisorError()
    except Exception:
        print("supervisor_configuration_invalid", file=sys.stderr)
        return 2
    if args.check_health:
        return 0 if check_health(runtime) else 1
    stopped = threading.Event()
    previous = {}

    def stop(_number, _frame):
        stopped.set()

    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.getsignal(number)
            signal.signal(number, stop)
        try:
            return ProxmoxWorkerSupervisor(selected).run(stopped)
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            print("supervisor_unavailable", file=sys.stderr)
            return 1
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
