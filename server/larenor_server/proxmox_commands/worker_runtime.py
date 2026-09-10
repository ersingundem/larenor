"""Non-root runtime entry point for the private Proxmox power worker.

This pilot validates an encrypted credential envelope but deliberately uses the
unavailable packaged adapter.  It never opens a Proxmox or LAN connection.
"""

import argparse
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import sys
import threading
import time
import uuid

from ..files import private_read
from ..plugins.worker import DockerWorkerError, _safe_path
from .api_adapter import CREDENTIAL_MAGIC
from .worker_ipc import ProxmoxPowerWorkerServer


MAX_CREDENTIAL_BYTES = 65_536
MAX_HEALTH_BYTES = 4_096
_ID = re.compile(r"[0-9a-f]{32}\Z")


class ProxmoxWorkerRuntimeError(Exception):
    def __init__(self, code="worker_unavailable"):
        self.code = code if code in {
            "worker_unavailable", "worker_configuration_invalid",
            "health_receipt_invalid",
        } else "worker_unavailable"
        super().__init__(self.code)


@dataclass(frozen=True, repr=False)
class EncryptedServiceCredential:
    _sealed: bytes

    def __repr__(self):
        return "EncryptedServiceCredential(<redacted>)"


@dataclass(frozen=True)
class WorkerRuntimeConfig:
    socket_path: Path
    health_path: Path
    credential_path: Path
    api_uid: int

    def __post_init__(self):
        paths = (self.socket_path, self.health_path, self.credential_path)
        if (
            type(self.api_uid) is not int or not 0 <= self.api_uid < 2**31
            or any(not isinstance(path, Path) or not path.is_absolute()
                   or ".." in path.parts or any(ord(char) < 32 or ord(char) == 127
                                                for char in str(path))
                   for path in paths)
            or len(set(paths)) != len(paths)
            or self.socket_path.parent != self.health_path.parent
        ):
            raise ProxmoxWorkerRuntimeError("worker_configuration_invalid")


@dataclass(frozen=True)
class WorkerHealthReceipt:
    schema_version: int
    capability: str
    state: str
    worker_id: str
    worker_uid: int
    socket_device: int
    socket_inode: int
    emitted_at: float


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProxmoxWorkerRuntimeError("health_receipt_invalid")
        result[key] = value
    return result


def _private_file(path):
    try:
        return _safe_path(
            Path(path), uid=os.geteuid(), kind=stat.S_ISREG, private=True
        )
    except (OSError, ValueError, TypeError, DockerWorkerError):
        raise ProxmoxWorkerRuntimeError("worker_configuration_invalid") from None


def load_encrypted_credential(path):
    try:
        source = _private_file(path)
        raw = private_read(source, MAX_CREDENTIAL_BYTES)
        minimum = len(CREDENTIAL_MAGIC) + 12 + 16
        if (
            not minimum <= len(raw) <= MAX_CREDENTIAL_BYTES
            or not raw.startswith(CREDENTIAL_MAGIC)
            or len(raw[len(CREDENTIAL_MAGIC):len(CREDENTIAL_MAGIC) + 12]) != 12
        ):
            raise ValueError()
        return EncryptedServiceCredential(raw)
    except ProxmoxWorkerRuntimeError:
        raise
    except Exception:
        raise ProxmoxWorkerRuntimeError("worker_configuration_invalid") from None


def _receipt_value(receipt):
    return {
        "schemaVersion": receipt.schema_version,
        "capability": receipt.capability,
        "state": receipt.state,
        "workerId": receipt.worker_id,
        "workerUid": receipt.worker_uid,
        "socketDevice": receipt.socket_device,
        "socketInode": receipt.socket_inode,
        "emittedAt": receipt.emitted_at,
    }


def _write_health(path, receipt):
    target = Path(path)
    temporary = None
    descriptor = None
    try:
        _safe_path(target.parent, uid=os.geteuid(), kind=stat.S_ISDIR, private=True)
        if target.exists() or target.is_symlink():
            _private_file(target)
        raw = json.dumps(
            _receipt_value(receipt), sort_keys=True, separators=(",", ":"),
            ensure_ascii=True, allow_nan=False,
        ).encode("ascii")
        if not 1 <= len(raw) <= MAX_HEALTH_BYTES:
            raise ValueError()
        temporary = target.parent / (target.name + "." + uuid.uuid4().hex + ".tmp")
        descriptor = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
        )
        written = 0
        while written < len(raw):
            count = os.write(descriptor, raw[written:])
            if count <= 0:
                raise OSError()
            written += count
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        _private_file(temporary)
        os.replace(temporary, target)
        temporary = None
        _private_file(target)
        directory = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException as error:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise ProxmoxWorkerRuntimeError("worker_unavailable") from None


def read_health_receipt(path):
    try:
        raw = private_read(_private_file(path), MAX_HEALTH_BYTES)
        value = json.loads(
            raw.decode("ascii"), object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        keys = {
            "schemaVersion", "capability", "state", "workerId", "workerUid",
            "socketDevice", "socketInode", "emittedAt",
        }
        if (
            type(value) is not dict or set(value) != keys
            or value["schemaVersion"] != 1
            or type(value["schemaVersion"]) is not int
            or value["capability"] != "proxmox-power-effect"
            or value["state"] not in {"ready", "stopped", "failed"}
            or type(value["workerId"]) is not str
            or _ID.fullmatch(value["workerId"]) is None
            or type(value["workerUid"]) is not int or value["workerUid"] < 1
            or type(value["socketDevice"]) is not int or value["socketDevice"] < 0
            or type(value["socketInode"]) is not int or value["socketInode"] < 0
            or type(value["emittedAt"]) not in (int, float)
            or isinstance(value["emittedAt"], bool)
            or not math.isfinite(value["emittedAt"]) or value["emittedAt"] < 0
        ):
            raise ValueError()
        return WorkerHealthReceipt(
            value["schemaVersion"], value["capability"], value["state"],
            value["workerId"], value["workerUid"], value["socketDevice"],
            value["socketInode"], float(value["emittedAt"]),
        )
    except ProxmoxWorkerRuntimeError:
        raise ProxmoxWorkerRuntimeError("health_receipt_invalid") from None
    except Exception:
        raise ProxmoxWorkerRuntimeError("health_receipt_invalid") from None


def _validate(config):
    if (
        not isinstance(config, WorkerRuntimeConfig)
        or os.getuid() != os.geteuid()
        or os.geteuid() == 0
        or config.api_uid != os.geteuid()
    ):
        raise ProxmoxWorkerRuntimeError("worker_configuration_invalid")
    try:
        _safe_path(
            config.socket_path.parent, uid=os.geteuid(),
            kind=stat.S_ISDIR, private=True,
        )
    except (OSError, DockerWorkerError):
        raise ProxmoxWorkerRuntimeError("worker_configuration_invalid") from None
    load_encrypted_credential(config.credential_path)


def serve_worker(config, stopped, *, adapter=None, peer_uid=None, timeout=5):
    worker = None
    identity = (0, 0)
    worker_id = uuid.uuid4().hex
    try:
        _validate(config)
        if not isinstance(stopped, threading.Event):
            raise ProxmoxWorkerRuntimeError("worker_configuration_invalid")
        worker = ProxmoxPowerWorkerServer(
            config.socket_path, adapter,
            allowed_uid=config.api_uid, peer_uid=peer_uid, timeout=timeout,
        )
        worker.start()
        info = config.socket_path.lstat()
        identity = (info.st_dev, info.st_ino)
        _write_health(config.health_path, WorkerHealthReceipt(
            1, "proxmox-power-effect", "ready", worker_id, os.geteuid(),
            identity[0], identity[1], time.time(),
        ))
        stopped.wait()
        worker.close()
        worker = None
        _write_health(config.health_path, WorkerHealthReceipt(
            1, "proxmox-power-effect", "stopped", worker_id, os.geteuid(),
            identity[0], identity[1], time.time(),
        ))
        return 0
    except BaseException as error:
        if worker is not None:
            try:
                worker.close()
            except Exception:
                pass
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        try:
            if isinstance(config, WorkerRuntimeConfig):
                _write_health(config.health_path, WorkerHealthReceipt(
                    1, "proxmox-power-effect", "failed", worker_id,
                    os.geteuid(), identity[0], identity[1], time.time(),
                ))
        except Exception:
            pass
        return 1


class _ParserExit(Exception):
    def __init__(self, status):
        self.status = status


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise ProxmoxWorkerRuntimeError("worker_configuration_invalid")

    def exit(self, status=0, message=None):
        raise _ParserExit(status)


def _uid(value):
    if not re.fullmatch(r"[0-9]{1,10}", value) or int(value) >= 2**31:
        raise argparse.ArgumentTypeError()
    return int(value)


def main(argv=None):
    parser = _Parser(prog="larenor-proxmox-power-worker", description=__doc__)
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--health-receipt", required=True, type=Path)
    parser.add_argument("--credential-file", required=True, type=Path)
    parser.add_argument("--api-uid", required=True, type=_uid)
    parser.add_argument("--check-config", action="store_true")
    try:
        args = parser.parse_args(argv)
        selected = WorkerRuntimeConfig(
            args.socket, args.health_receipt, args.credential_file, args.api_uid,
        )
        _validate(selected)
    except _ParserExit as result:
        return result.status
    except Exception:
        print("worker_configuration_invalid", file=sys.stderr)
        return 2
    if args.check_config:
        return 0
    stopped = threading.Event()
    previous = {}

    def stop(_number, _frame):
        stopped.set()

    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.getsignal(number)
            signal.signal(number, stop)
        return serve_worker(selected, stopped)
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
