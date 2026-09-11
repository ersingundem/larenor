"""Private Keenetic worker CLI and bounded lifecycle supervisor."""

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import platform
import re
import signal
import stat
import sys
import time
import uuid

from pydantic import Field

from ..files import checked_path, private_read, sync_directory
from ..home_resources.models import FrozenModel, Identity
from ..plugins.worker import _safe_path
from .credential_lease import KeeneticCredentialLeaseVerifier
from .rci_adapter import PackagedRciCommandAdapter
from .rci_transport import LeasedKeeneticRciTransport
from .worker_ipc import KeeneticCommandWorkerServer


MAX_POLICY_BYTES = 32768


class RuntimeConfigurationError(ValueError):
    """Static runtime failure that never contains a path or credential."""

    def __init__(self, code="worker_configuration_invalid"):
        self.code = code if code in {
            "worker_configuration_invalid",
            "worker_health_invalid",
            "worker_unavailable",
        } else "worker_unavailable"
        super().__init__(self.code)


@dataclass(frozen=True, repr=False)
class KeeneticWorkerPolicy:
    adapter: str
    secret_file: Path | None

    def __repr__(self):
        return "KeeneticWorkerPolicy(<private>)"


class WorkerHealthReceipt(FrozenModel):
    schemaVersion: int = Field(ge=1, le=1)
    workerId: Identity
    workerPid: int = Field(ge=1, le=2**31 - 1)
    socketDevice: int = Field(ge=0)
    socketInode: int = Field(ge=1)
    status: str = Field(pattern=r"^ready$")


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RuntimeConfigurationError()
        result[key] = value
    return result


def _absolute(value):
    if type(value) is not str:
        raise RuntimeConfigurationError()
    path = Path(value)
    if (
        not path.is_absolute()
        or ".." in path.parts
        or path == Path("/")
        or len(value.encode("utf-8")) > 4096
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        raise RuntimeConfigurationError()
    return path


def load_policy(path):
    invalid = False
    result = None
    try:
        source = checked_path(Path(path))
        raw = private_read(source, MAX_POLICY_BYTES)
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_pairs,
            parse_float=lambda _value: (_ for _ in ()).throw(ValueError()),
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        if (
            type(value) is not dict
            or set(value) != {"version", "adapter", "secretFile"}
            or type(value["version"]) is not int
            or value["version"] != 1
            or value["adapter"] not in {"unavailable", "rci"}
            or value["secretFile"] is not None
            and type(value["secretFile"]) is not str
            or value["adapter"] == "unavailable"
            and value["secretFile"] is not None
            or value["adapter"] == "rci"
            and value["secretFile"] is None
        ):
            raise ValueError()
        secret = None
        if value["secretFile"] is not None:
            secret = _absolute(value["secretFile"])
            _safe_path(secret, uid=os.geteuid(), kind=stat.S_ISREG, private=True)
            if len(private_read(secret, 32)) != 32:
                raise ValueError()
        result = KeeneticWorkerPolicy(value["adapter"], secret)
    except Exception:
        invalid = True
    if invalid or type(result) is not KeeneticWorkerPolicy:
        raise RuntimeConfigurationError() from None
    return result


def runtime_adapter_factory(policy, *, clock=None):
    """Build worker-bound RCI adapters without retaining decrypted credentials."""
    if (
        not isinstance(policy, KeeneticWorkerPolicy)
        or policy.adapter != "rci"
        or policy.secret_file is None
        or clock is not None and not callable(clock)
    ):
        raise RuntimeConfigurationError()

    def build(worker_id):
        try:
            key = private_read(policy.secret_file, 32)
            if len(key) != 32:
                raise ValueError()
            verifier = KeeneticCredentialLeaseVerifier(
                key,
                worker_id=worker_id,
                clock=clock or time.time,
            )
            return PackagedRciCommandAdapter(
                LeasedKeeneticRciTransport(verifier)
            )
        except Exception:
            raise RuntimeConfigurationError() from None

    return build


class WorkerHealthStore:
    def __init__(self, path, *, owner_uid):
        if type(owner_uid) is not int or not 0 <= owner_uid < 2**31:
            raise RuntimeConfigurationError("worker_health_invalid")
        self.path = _absolute(str(path))
        self.owner_uid = owner_uid

    def _socket(self, path):
        try:
            source = _safe_path(
                _absolute(str(path)),
                uid=self.owner_uid,
                kind=stat.S_ISSOCK,
            )
            info = source.lstat()
            if stat.S_IMODE(info.st_mode) not in {0o600, 0o660}:
                raise ValueError()
            return source, info
        except Exception:
            raise RuntimeConfigurationError("worker_health_invalid") from None

    def _read(self):
        try:
            raw = private_read(self.path, 4096)
            value = json.loads(raw.decode("ascii"), object_pairs_hook=_pairs)
            return WorkerHealthReceipt.model_validate(value)
        except Exception:
            raise RuntimeConfigurationError("worker_health_invalid") from None

    def publish_ready(self, socket_path, *, worker_id, worker_pid):
        _, info = self._socket(socket_path)
        receipt = WorkerHealthReceipt(
            schemaVersion=1,
            workerId=worker_id,
            workerPid=worker_pid,
            socketDevice=info.st_dev,
            socketInode=info.st_ino,
            status="ready",
        )
        try:
            _safe_path(self.path.parent, uid=self.owner_uid,
                       kind=stat.S_ISDIR, private=True)
            temporary = self.path.parent / ("." + self.path.name + "." + uuid.uuid4().hex)
            descriptor = os.open(
                temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
            )
            try:
                raw = json.dumps(
                    receipt.model_dump(mode="json"),
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=True,
                ).encode("ascii")
                with os.fdopen(descriptor, "wb", closefd=False) as stream:
                    stream.write(raw)
                    stream.flush()
                    os.fsync(stream.fileno())
            finally:
                os.close(descriptor)
            if self.path.exists() or self.path.is_symlink():
                _safe_path(self.path, uid=self.owner_uid,
                           kind=stat.S_ISREG, private=True)
            os.replace(temporary, self.path)
            sync_directory(self.path.parent)
        except Exception:
            try:
                if "temporary" in locals() and temporary.exists():
                    temporary.unlink()
            except OSError:
                pass
            raise RuntimeConfigurationError("worker_health_invalid") from None
        return receipt

    def verify_ready(self, socket_path):
        receipt = self._read()
        _, info = self._socket(socket_path)
        if (info.st_dev, info.st_ino) != (
            receipt.socketDevice, receipt.socketInode
        ):
            raise RuntimeConfigurationError("worker_health_invalid")
        return receipt

    def remove(self, *, worker_id=None):
        if not self.path.exists() and not self.path.is_symlink():
            return
        receipt = self._read()
        if worker_id is not None and receipt.workerId != worker_id:
            raise RuntimeConfigurationError("worker_health_invalid")
        try:
            self.path.unlink()
            sync_directory(self.path.parent)
        except OSError:
            raise RuntimeConfigurationError("worker_health_invalid") from None

    def cleanup_orphan(self, socket_path, *, process_alive):
        if not callable(process_alive):
            raise RuntimeConfigurationError("worker_health_invalid")
        if not self.path.exists() and not self.path.is_symlink():
            if Path(socket_path).exists() or Path(socket_path).is_symlink():
                raise RuntimeConfigurationError("worker_health_invalid")
            return
        receipt = self._read()
        if process_alive(receipt.workerPid):
            raise RuntimeConfigurationError("worker_health_invalid")
        path = Path(socket_path)
        if path.exists() or path.is_symlink():
            _, info = self._socket(path)
            if (info.st_dev, info.st_ino) != (
                receipt.socketDevice, receipt.socketInode
            ):
                raise RuntimeConfigurationError("worker_health_invalid")
            try:
                path.unlink()
            except OSError:
                raise RuntimeConfigurationError("worker_health_invalid") from None
        self.remove(worker_id=receipt.workerId)


class KeeneticWorkerSupervisor:
    def __init__(self, run_once, *, cleanup, max_restarts=3,
                 initial_backoff=.25):
        if (
            not callable(run_once)
            or not callable(cleanup)
            or type(max_restarts) is not int
            or not 0 <= max_restarts <= 8
            or type(initial_backoff) not in (int, float)
            or not 0 < initial_backoff <= 2
        ):
            raise RuntimeConfigurationError("worker_unavailable")
        self._run_once = run_once
        self._cleanup = cleanup
        self._max_restarts = max_restarts
        self._initial_backoff = initial_backoff

    def run(self, stop):
        for attempt in range(self._max_restarts + 1):
            if stop.is_set():
                return 0
            try:
                self._cleanup()
                outcome = self._run_once(stop)
            except Exception:
                if stop.is_set():
                    return 1
                outcome = "failed"
            if outcome == "stopped" or stop.is_set():
                return 0
            if outcome != "failed" or attempt == self._max_restarts:
                return 1
            if stop.wait(min(2.0, self._initial_backoff * 2**attempt)):
                return 0
        return 1


def run_worker_once(socket_path, health_path, *, api_uid, socket_gid, stop,
                    peer_uid=None, adapter_factory=None):
    worker_id = uuid.uuid4().hex
    store = WorkerHealthStore(health_path, owner_uid=os.geteuid())
    adapter = None if adapter_factory is None else adapter_factory(worker_id)
    worker = KeeneticCommandWorkerServer(
        socket_path,
        adapter,
        allowed_uid=api_uid,
        socket_gid=socket_gid,
        peer_uid=peer_uid,
        timeout=5,
    )
    published = False
    try:
        worker.start()
        store.publish_ready(
            socket_path, worker_id=worker_id, worker_pid=os.getpid()
        )
        published = True
        while not stop.wait(.05):
            if not worker.is_alive:
                return "failed"
        return "stopped"
    except Exception:
        return "failed"
    finally:
        try:
            worker.close()
        finally:
            if published:
                store.remove(worker_id=worker_id)


def _process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _platform():
    machine = platform.machine().lower()
    if not sys.platform.startswith("linux"):
        return "unsupported"
    if machine in {"aarch64", "arm64"}:
        return "linux/arm64"
    if machine in {"x86_64", "amd64"}:
        return "linux/amd64"
    return "unsupported"


def _uid(value):
    if not re.fullmatch(r"[0-9]{1,10}", value) or int(value) >= 2**31:
        raise argparse.ArgumentTypeError("invalid")
    return int(value)


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise RuntimeConfigurationError()


def main(argv=None):
    parser = _Parser(prog="larenor-keenetic-worker", description=__doc__)
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--socket", type=Path)
    parser.add_argument("--health", type=Path)
    parser.add_argument("--api-uid", type=_uid)
    parser.add_argument("--socket-gid", type=_uid)
    parser.add_argument("--check-config", action="store_true")
    parser.add_argument("--health-check", action="store_true")
    try:
        args = parser.parse_args(argv)
        policy = load_policy(args.policy)
        if _platform() not in {"linux/amd64", "linux/arm64"}:
            raise RuntimeConfigurationError()
        if args.check_config:
            return 0
        if args.socket is None or args.health is None or args.api_uid is None:
            raise RuntimeConfigurationError()
        _absolute(str(args.socket))
        _absolute(str(args.health))
        if args.health_check:
            receipt = WorkerHealthStore(
                args.health, owner_uid=os.geteuid()
            ).verify_ready(args.socket)
            return 0 if _process_alive(receipt.workerPid) else 1
        adapter_factory = (
            runtime_adapter_factory(policy) if policy.adapter == "rci" else None
        )
    except (RuntimeConfigurationError, OSError, ValueError):
        print("worker_configuration_invalid", file=sys.stderr)
        return 2

    stopped = __import__("threading").Event()
    previous = {}

    def stop(_number, _frame):
        stopped.set()

    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.getsignal(number)
            signal.signal(number, stop)
        store = WorkerHealthStore(args.health, owner_uid=os.geteuid())
        supervisor = KeeneticWorkerSupervisor(
            lambda event: run_worker_once(
                args.socket,
                args.health,
                api_uid=args.api_uid,
                socket_gid=args.socket_gid,
                stop=event,
                adapter_factory=adapter_factory,
            ),
            cleanup=lambda: store.cleanup_orphan(
                args.socket, process_alive=_process_alive
            ),
        )
        result = supervisor.run(stopped)
    except Exception:
        result = 1
    finally:
        for number, handler in previous.items():
            try:
                signal.signal(number, handler)
            except Exception:
                result = 1
    if result:
        print("worker_unavailable", file=sys.stderr)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
