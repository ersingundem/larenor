"""Isolated worker primitives; never instantiate these in the API process.

The worker owns its Unix Docker connection and private journal. There is no
shell, TCP listener, Compose input, deletion, image pulling, storage provisioning
or resource adoption here. Phase receipts do not claim installation/health
success. Packaged catalog plans remain disabled; their independent verifier is
the only public plan entry point. ContainerBinding is an internal, already-bound
worker value, not an IPC/request schema. A future dispatcher/worker protocol must
not deserialize it from a Client or API-supplied Docker specification.

Docker HTTP schema: https://docs.docker.com/reference/api/engine/version/v1.47/
Reuses the tested bounded HTTP framing/watchdog from the private-service
transport; only fixed Engine routes and generated resource identities are sent.
"""

from contextlib import contextmanager
from dataclasses import dataclass, field
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import socket
import sqlite3
import stat
import struct
import threading
import time
from urllib.parse import quote, urlencode
import uuid

from ..services.transport import _Deadline, _Reader, _request_bytes, _response, ProbeTransportError


_ID = re.compile(r"[0-9a-f]{32}\Z")
_CONTAINER_ID = re.compile(r"[0-9a-f]{64}\Z")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
_NAME = re.compile(r"larenor-[0-9a-f]{32}\Z")
_REFERENCE = re.compile(r"ghcr\.io/[a-z0-9-]+/[a-z0-9-]+(?::[A-Za-z0-9_][A-Za-z0-9._-]{0,127})?@sha256:[0-9a-f]{64}\Z")
_LABELS = {"org.larenor.server": 32, "org.larenor.installation": 32,
           "org.larenor.worker-journal": 32, "org.larenor.plan": 64,
           "org.larenor.catalog": 64, "org.larenor.manifest": 64}
_CODES = frozenset({"invalid_binding", "invalid_command", "unsafe_worker_path", "engine_peer_rejected",
                    "engine_unavailable", "engine_protocol", "engine_conflict", "engine_image_missing",
                    "journal_unavailable", "worker_busy", "idempotency_conflict", "dispatch_expired",
                    "step_order", "record_missing", "worker_unverified", "worker_resources_unprepared",
                    "catalog_rejected"})
_SPEC_KEYS = {"Image", "User", "Labels", "Env", "HostConfig", "ExposedPorts"}
_HOST_KEYS = {"Privileged", "CapDrop", "CapAdd", "SecurityOpt", "NetworkMode", "Memory", "NanoCpus",
              "PidsLimit", "ReadonlyRootfs", "Init", "Tmpfs", "PortBindings", "RestartPolicy"}
_FORBIDDEN_OBSERVED = {"Binds": (None, []), "Mounts": (None, []), "Devices": (None, []),
                       "DeviceRequests": (None, []), "VolumesFrom": (None, []), "PidMode": (None, ""),
                       "IpcMode": (None, "", "private"), "UTSMode": (None, ""), "UsernsMode": (None, ""),
                       "CgroupnsMode": (None, "", "private"), "ExtraHosts": (None, []), "Sysctls": (None, {}),
                       "AutoRemove": (None, False), "PublishAllPorts": (None, False)}
_STATE_CODES = {
    "prepared": {"accepted"},
    "mutating": {"engine_operation_pending"},
    "uncertain": {"engine_operation_uncertain"},
    "succeeded": {"container_created", "container_started"},
    "needs_attention": {"resource_conflict", "container_not_running", "dispatch_expired"},
}


class DockerWorkerError(Exception):
    def __init__(self, code="engine_unavailable"):
        self.code = code if code in _CODES else "engine_unavailable"
        super().__init__(self.code)


def _require(condition, code="invalid_binding"):
    if not condition:
        raise DockerWorkerError(code)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, "engine_protocol")
        result[key] = value
    return result


def _decode(value, limit=1048576):
    _require(isinstance(value, bytes) and len(value) <= limit, "engine_protocol")
    try:
        result = json.loads(value.decode("utf-8"), object_pairs_hook=_pairs,
                            parse_float=_finite_float,
                            parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        _require(type(result) is dict, "engine_protocol")
        return result
    except (ValueError, UnicodeError, RecursionError):
        raise DockerWorkerError("engine_protocol") from None


def _finite_float(value):
    result = float(value)
    if not math.isfinite(result):
        raise ValueError()
    return result


def _canonical(value):
    try:
        data = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode()
        _require(len(data) <= 65536)
        return data
    except (ValueError, TypeError, RecursionError):
        raise DockerWorkerError("invalid_binding") from None


def _safe_path(path, *, uid, kind, private=False):
    path = Path(path).absolute()
    try:
        _require(".." not in path.parts, "unsafe_worker_path")
        for parent in (*reversed(path.parents), path):
            info = parent.lstat()
            _require(not stat.S_ISLNK(info.st_mode), "unsafe_worker_path")
            if parent != path:
                # Root-owned sticky temporary directories are safe ancestors;
                # arbitrary group/world-writable or foreign-owned parents are not.
                _require(info.st_uid in {0, uid} and (info.st_mode & 0o022 == 0
                         or info.st_uid == 0 and info.st_mode & stat.S_ISVTX), "unsafe_worker_path")
        info = path.lstat()
        _require(info.st_uid == uid and kind(info.st_mode), "unsafe_worker_path")
        _require(info.st_mode & (0o077 if private else 0o007) == 0, "unsafe_worker_path")
        if stat.S_ISREG(info.st_mode):
            _require(info.st_nlink == 1, "unsafe_worker_path")
    except OSError:
        raise DockerWorkerError("unsafe_worker_path") from None
    return path


@dataclass(frozen=True)
class ContainerBinding:
    """Internal output of trusted worker policy, never accepted over the wire.

    This first primitive deliberately handles containers without persistent mounts.
    Their provisioning needs separately journaled resource steps before enablement.
    Image configuration is pinned by image_id and compared for inherited command,
    entrypoint, environment and working directory when recovering an uncertain call.
    """
    name: str
    platform: str
    image_id: str
    specification: bytes = field(repr=False)
    image_configuration: bytes = field(default=b"{}", repr=False)

    def __post_init__(self):
        try:
            _require(_NAME.fullmatch(self.name) is not None)
            _require(self.platform in {"linux/amd64", "linux/arm64"} and _DIGEST.fullmatch(self.image_id) is not None)
            body = _decode(self.specification, 65536)
            _require(set(body) <= _SPEC_KEYS and _REFERENCE.fullmatch(body.get("Image", "")) is not None)
            _require(body.get("User") in {"1000:1000", "0:0"})
            labels = body.get("Labels")
            _require(type(labels) is dict and set(labels) == set(_LABELS))
            for key, length in _LABELS.items():
                _require(isinstance(labels[key], str) and re.fullmatch(r"[0-9a-f]{" + str(length) + "}", labels[key]) is not None)
            _require(self.name == "larenor-" + labels["org.larenor.installation"])
            environment = body.get("Env", [])
            _require(type(environment) is list and len(environment) <= 4)
            _require(all(isinstance(value, str) and re.fullmatch(r"(?:TZ|PORT|WEBUI_PORT|TORRENTING_PORT)=[A-Za-z0-9/_-]{1,80}", value) for value in environment))
            _require(len({value.partition("=")[0] for value in environment}) == len(environment))
            host = body.get("HostConfig")
            _require(type(host) is dict and set(host) <= _HOST_KEYS)
            _require(host.get("Privileged") is False and host.get("CapDrop") == ["ALL"])
            _require(host.get("CapAdd") in ([], ["NET_BIND_SERVICE"]))
            _require(host.get("SecurityOpt") == ["no-new-privileges:true"])
            _require(host.get("NetworkMode") in {"bridge", "host"})
            _require(type(host.get("ReadonlyRootfs")) is bool)
            for key, minimum, maximum in (("Memory", 128 * 1048576, 16384 * 1048576),
                                           ("NanoCpus", 100000000, 16000000000), ("PidsLimit", 32, 4096)):
                _require(type(host.get(key)) is int and minimum <= host[key] <= maximum)
            _require(host.get("Init") is None or type(host["Init"]) is bool)
            _require(host.get("RestartPolicy", {"Name": "no"}) == {"Name": "no"})
            _require(type(host.get("Tmpfs", {})) is dict)
            for target, options in host.get("Tmpfs", {}).items():
                _require(target in {"/run", "/tmp"} and isinstance(options, str))
                _require(re.fullmatch(r"rw,nosuid,nodev,(?:noexec|exec),size=[0-9]{2,3}m,uid=(?:0|1000),gid=(?:0|1000),mode=1777", options) is not None)
            _require(type(body.get("ExposedPorts", {})) is dict and len(body.get("ExposedPorts", {})) <= 8)
            for key, value in body.get("ExposedPorts", {}).items():
                _require(re.fullmatch(r"[0-9]{1,5}/(?:tcp|udp)", key) is not None and value == {} and 1 <= int(key.split("/")[0]) <= 65535)
            _require(type(host.get("PortBindings", {})) is dict and len(host.get("PortBindings", {})) <= 3)
            for port, bindings in host.get("PortBindings", {}).items():
                _require(port in body.get("ExposedPorts", {}) and type(bindings) is list and len(bindings) == 1)
                selected = bindings[0]
                _require(type(selected) is dict and set(selected) == {"HostIp", "HostPort"} and selected["HostIp"] == "0.0.0.0")
                _require(isinstance(selected["HostPort"], str) and selected["HostPort"].isdigit() and 1024 <= int(selected["HostPort"]) <= 65535)
            _require(host["NetworkMode"] != "host" or not host.get("PortBindings"))
            configuration = _decode(self.image_configuration, 65536)
            _require(not configuration.get("Volumes"), "worker_resources_unprepared")
            inherited_env = configuration.get("Env") or []
            _require(type(inherited_env) is list and len(inherited_env) <= 128
                     and all(type(value) is str and "=" in value and len(value) <= 8192 for value in inherited_env))
            inherited_labels = configuration.get("Labels") or {}
            _require(type(inherited_labels) is dict and all(type(value) is str for value in inherited_labels.values()))
            _require(not set(inherited_labels).intersection(_LABELS))
            inherited_ports = configuration.get("ExposedPorts") or {}
            _require(type(inherited_ports) is dict and len(inherited_ports) <= 32)
            object.__setattr__(self, "specification", _canonical(body))
            object.__setattr__(self, "image_configuration", _canonical(configuration))
        except (ValueError, TypeError, AttributeError, DockerWorkerError):
            raise DockerWorkerError("invalid_binding") from None

    @property
    def labels(self):
        return _decode(self.specification)["Labels"]

    def payload(self):
        return {"name": self.name, "platform": self.platform, "image_id": self.image_id,
                "specification": _decode(self.specification), "image_configuration": _decode(self.image_configuration)}


class UnixDockerEngine:
    def __init__(self, path, *, timeout=30.0, socket_uid=0, peer_uid=None):
        _require(type(timeout) in (int, float) and math.isfinite(timeout) and 0 < timeout <= 30, "engine_protocol")
        self.path, self.timeout, self.socket_uid = Path(path).absolute(), timeout, socket_uid
        self.peer_uid = peer_uid or self._linux_peer_uid

    @staticmethod
    def _linux_peer_uid(connection):
        if not hasattr(socket, "SO_PEERCRED"):
            raise DockerWorkerError("engine_peer_rejected")
        return struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]

    def _exchange(self, method, target, body=None):
        _safe_path(self.path, uid=self.socket_uid, kind=stat.S_ISSOCK)
        deadline = time.monotonic() + self.timeout
        watcher = None
        try:
            watcher = _Deadline(deadline)
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            watcher.attach(connection)
            connection.settimeout(self.timeout)
            connection.connect(str(self.path))
            _require(self.peer_uid(connection) == self.socket_uid, "engine_peer_rejected")
            message = _request_bytes(method, "/v1.47" + target, "localhost",
                                     {"Content-Type": "application/json"}, body)
            connection.sendall(message)
            return _response(_Reader(connection, deadline), 1048576)
        except DockerWorkerError:
            raise
        except (OSError, ValueError, ProbeTransportError):
            raise DockerWorkerError("engine_unavailable") from None
        finally:
            if watcher is not None:
                watcher.finish()

    def inspect_container(self, name):
        _require(type(name) is str and (_NAME.fullmatch(name) is not None or _CONTAINER_ID.fullmatch(name) is not None))
        response = self._exchange("GET", "/containers/" + name + "/json")
        if response.status == 404:
            return None
        _require(response.status == 200, "engine_unavailable")
        return _decode(response.body)

    def inspect_image(self, reference):
        _require(type(reference) is str and _REFERENCE.fullmatch(reference) is not None)
        response = self._exchange("GET", "/images/" + quote(reference, safe="") + "/json")
        _require(response.status != 404, "engine_image_missing")
        _require(response.status == 200, "engine_unavailable")
        return _decode(response.body)

    def create_container(self, binding):
        _require(type(binding) is ContainerBinding)
        response = self._exchange("POST", "/containers/create?" + urlencode({"name": binding.name, "platform": binding.platform}), binding.specification)
        _require(response.status != 409, "engine_conflict")
        _require(response.status == 201, "engine_unavailable")
        data = _decode(response.body)
        _require(isinstance(data.get("Id"), str) and _CONTAINER_ID.fullmatch(data["Id"]) is not None, "engine_protocol")
        _require(data.get("Warnings") in (None, []), "engine_protocol")
        return data["Id"]

    def start_container(self, identity):
        _require(type(identity) is str and _CONTAINER_ID.fullmatch(identity) is not None)
        response = self._exchange("POST", "/containers/" + identity + "/start")
        _require(response.status in {204, 304}, "engine_unavailable")


@dataclass(frozen=True)
class WorkerStep:
    job_id: str
    installation_id: str
    kind: str
    dispatch_id: str
    start_deadline: int | float

    def __post_init__(self):
        _require(all(isinstance(value, str) and _ID.fullmatch(value) is not None for value in (self.job_id, self.installation_id, self.dispatch_id)), "invalid_command")
        _require(self.kind in {"create_container", "start_container"}, "invalid_command")
        _require(type(self.start_deadline) in (int, float) and math.isfinite(self.start_deadline), "invalid_command")


@dataclass(frozen=True)
class StepReceipt:
    job_id: str
    step: str
    state: str
    code: str
    container_id: str | None = None


class WorkerJournal:
    def __init__(self, directory, *, initialize=False):
        self.directory = Path(directory).absolute()
        self._thread_lock = threading.Lock()
        self._closed = False
        database = self.directory / "journal.sqlite"
        created = False
        try:
            if not self.directory.exists() and not self.directory.is_symlink() and initialize:
                _safe_path(self.directory.parent, uid=os.getuid(), kind=stat.S_ISDIR, private=True)
                self.directory.mkdir(mode=0o700)
                created = True
            _safe_path(self.directory, uid=os.getuid(), kind=stat.S_ISDIR, private=True)
            if created:
                descriptor = os.open(database, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                os.close(descriptor)
                descriptor = os.open(self.directory / "journal.lock", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                os.close(descriptor)
            _require(database.exists(), "journal_unavailable")
            _safe_path(database, uid=os.getuid(), kind=stat.S_ISREG, private=True)
            for suffix in ("-journal", "-wal", "-shm"):
                sidecar = database.with_name(database.name + suffix)
                if sidecar.exists() or sidecar.is_symlink():
                    _safe_path(sidecar, uid=os.getuid(), kind=stat.S_ISREG, private=True)
            lock = _safe_path(self.directory / "journal.lock", uid=os.getuid(), kind=stat.S_ISREG, private=True)
            self._lock_file = os.open(lock, os.O_RDWR | os.O_NOFOLLOW)
            self._database = sqlite3.connect(database, timeout=2, isolation_level=None, check_same_thread=False)
            self._database.row_factory = sqlite3.Row
            self._database.execute("PRAGMA journal_mode=DELETE")
            self._database.execute("PRAGMA synchronous=FULL")
            with self.locked():
                if created:
                    self._database.execute("BEGIN IMMEDIATE")
                    self._database.execute("CREATE TABLE metadata (identity TEXT NOT NULL, version INTEGER NOT NULL)")
                    self._database.execute("INSERT INTO metadata VALUES (?,1)", (uuid.uuid4().hex,))
                    self._database.execute("""CREATE TABLE operations (
                        job TEXT NOT NULL, step TEXT NOT NULL, installation TEXT NOT NULL,
                        dispatch TEXT UNIQUE NOT NULL, payload BLOB NOT NULL, digest TEXT NOT NULL,
                        state TEXT NOT NULL, code TEXT NOT NULL, container TEXT,
                        PRIMARY KEY(job,step), UNIQUE(installation,step))""")
                    self._database.execute("COMMIT")
                    descriptor = os.open(self.directory, os.O_RDONLY)
                    try:
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                _require(self._database.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "journal_unavailable")
                row = self._database.execute("SELECT identity,version FROM metadata").fetchall()
                _require(len(row) == 1 and row[0]["version"] == 1 and _ID.fullmatch(row[0]["identity"]) is not None, "journal_unavailable")
                self.identity = row[0]["identity"]
                columns = self._database.execute("PRAGMA table_info(operations)").fetchall()
                _require([item["name"] for item in columns] == ["job", "step", "installation", "dispatch", "payload",
                         "digest", "state", "code", "container"], "journal_unavailable")
        except DockerWorkerError:
            self.close()
            raise
        except (OSError, sqlite3.Error, ValueError, TypeError):
            self.close()
            raise DockerWorkerError("journal_unavailable") from None

    @contextmanager
    def locked(self):
        _require(not self._closed and self._thread_lock.acquire(blocking=False), "worker_busy")
        acquired = False
        try:
            try:
                fcntl.flock(self._lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
            except OSError:
                raise DockerWorkerError("worker_busy") from None
            yield
        finally:
            if acquired:
                fcntl.flock(self._lock_file, fcntl.LOCK_UN)
            self._thread_lock.release()

    def close(self):
        if self._closed:
            return
        self._closed = True
        if hasattr(self, "_database"):
            self._database.close()
        if hasattr(self, "_lock_file"):
            os.close(self._lock_file)

    def _read(self, job, step):
        try:
            row = self._database.execute("SELECT * FROM operations WHERE job=? AND step=?", (job, step)).fetchone()
            if row is not None:
                _require(hashlib.sha256(row["payload"]).hexdigest() == row["digest"])
                _require(row["state"] in _STATE_CODES and row["code"] in _STATE_CODES[row["state"]])
                _require(row["container"] is None or _CONTAINER_ID.fullmatch(row["container"]) is not None)
                payload = _decode(row["payload"], 65536)
                _require(set(payload) == {"command", "binding"})
                command = WorkerStep(**payload["command"])
                _require((command.job_id, command.kind, command.installation_id, command.dispatch_id)
                         == (row["job"], row["step"], row["installation"], row["dispatch"]))
                binding = _stored_binding(row)
                _require(binding.labels["org.larenor.worker-journal"] == self.identity
                         and binding.labels["org.larenor.installation"] == command.installation_id)
                if row["state"] == "succeeded":
                    expected = "container_created" if row["step"] == "create_container" else "container_started"
                    _require(row["code"] == expected and row["container"] is not None)
            return row
        except (sqlite3.Error, TypeError, ValueError, KeyError, DockerWorkerError):
            raise DockerWorkerError("journal_unavailable") from None

    def _write_state(self, row, state, code, identity=None):
        try:
            self._database.execute("BEGIN IMMEDIATE")
            self._database.execute("UPDATE operations SET state=?,code=?,container=? WHERE job=? AND step=?",
                                   (state, code, identity, row["job"], row["step"]))
            self._database.execute("COMMIT")
            return self._read(row["job"], row["step"])
        except sqlite3.Error:
            if self._database.in_transaction:
                self._database.execute("ROLLBACK")
            raise DockerWorkerError("journal_unavailable") from None


def _receipt(row):
    return StepReceipt(row["job"], row["step"], row["state"], row["code"], row["container"])


def _stored_binding(row):
    payload = _decode(row["payload"], 65536)
    value = payload["binding"]
    return ContainerBinding(value["name"], value["platform"], value["image_id"],
                            _canonical(value["specification"]), _canonical(value["image_configuration"]))


def _matches(value, binding):
    if type(value) is not dict:
        return False
    body, inherited = _decode(binding.specification), _decode(binding.image_configuration)
    if (not isinstance(value.get("Id"), str) or not _CONTAINER_ID.fullmatch(value["Id"])
            or value.get("Name") != "/" + binding.name or value.get("Image") != binding.image_id
            or value.get("Mounts") not in (None, [])):
        return False
    config, host = value.get("Config"), value.get("HostConfig")
    if type(config) is not dict or type(host) is not dict:
        return False
    expected = {key: item for key, item in body.items() if key != "HostConfig"}
    env = {item.partition("=")[0]: item for item in inherited.get("Env") or []}
    env.update({item.partition("=")[0]: item for item in body.get("Env", [])})
    actual_env = config.get("Env") or []
    if type(actual_env) is not list or not all(type(item) is str for item in actual_env) or sorted(actual_env) != sorted(env.values()):
        return False
    expected["Labels"] = {**(inherited.get("Labels") or {}), **body["Labels"]}
    expected["ExposedPorts"] = {**(inherited.get("ExposedPorts") or {}), **body.get("ExposedPorts", {})}
    for key, item in expected.items():
        actual = (config.get(key) or {}) if key == "ExposedPorts" else config.get(key)
        if key != "Env" and actual != item:
            return False
    for key in ("Cmd", "Entrypoint", "WorkingDir", "Volumes", "Healthcheck", "StopSignal", "Shell"):
        if (config.get(key) or None) != (inherited.get(key) or None):
            return False
    if any(config.get(key) not in (None, False) for key in ("Tty", "OpenStdin", "StdinOnce")):
        return False
    for key, item in body["HostConfig"].items():
        if key == "RestartPolicy":
            item = {"Name": "no", "MaximumRetryCount": 0}
        if host.get(key) != item:
            return False
    for key in _HOST_KEYS - body["HostConfig"].keys():
        if host.get(key) not in (None, False, {}, [], {"Name": "no", "MaximumRetryCount": 0}):
            return False
    return all(host.get(key) in allowed for key, allowed in _FORBIDDEN_OBSERVED.items())


class JournaledContainerOperations:
    """Trusted worker-internal phase operations, not an API/IPC handler.

    Caller must own/rederive ContainerBinding locally. inspect_catalog_plan below
    cannot promote a disabled catalog entry into a mutating binding. These phase
    primitives will serve internal components of the single Larenor installation;
    they are not a standalone service deployment API.
    """
    def __init__(self, journal, engine):
        self.journal, self.engine = journal, engine

    def apply(self, command, binding):
        _require(type(command) is WorkerStep and type(binding) is ContainerBinding, "invalid_command")
        _require(binding.labels["org.larenor.worker-journal"] == self.journal.identity
                 and binding.labels["org.larenor.installation"] == command.installation_id)
        payload = _canonical({"command": command.__dict__, "binding": binding.payload()})
        digest = hashlib.sha256(payload).hexdigest()
        with self.journal.locked():
            row = self.journal._read(command.job_id, command.kind)
            if row is not None:
                _require(row["digest"] == digest, "idempotency_conflict")
                if row["state"] in {"succeeded", "needs_attention"}:
                    return _receipt(row)
                if row["state"] in {"mutating", "uncertain"}:
                    return self._reconcile(row, binding)
            else:
                _require(command.start_deadline > time.time(), "dispatch_expired")
                if command.kind == "start_container":
                    created = self.journal._read(command.job_id, "create_container")
                    _require(created is not None and created["state"] == "succeeded" and _stored_binding(created) == binding, "step_order")
                _require(self.journal._database.execute("SELECT count(*) FROM operations").fetchone()[0] < 10000, "journal_unavailable")
                try:
                    self.journal._database.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,?)",
                        (command.job_id, command.kind, command.installation_id, command.dispatch_id,
                         payload, digest, "prepared", "accepted", None))
                except sqlite3.IntegrityError:
                    raise DockerWorkerError("idempotency_conflict") from None
                except sqlite3.Error:
                    raise DockerWorkerError("journal_unavailable") from None
                row = self.journal._read(command.job_id, command.kind)
            try:
                observed = self.engine.inspect_container(binding.name)
            except DockerWorkerError:
                return _receipt(row)
            if command.kind == "create_container":
                if observed is not None:
                    return _receipt(self.journal._write_state(row, "needs_attention", "resource_conflict"))
                try:
                    image = self.engine.inspect_image(_decode(binding.specification)["Image"])
                except DockerWorkerError:
                    return _receipt(row)
                if (type(image) is not dict or image.get("Id") != binding.image_id
                        or image.get("Os") != "linux" or image.get("Architecture") != binding.platform.split("/")[1]
                        or image.get("Config") != _decode(binding.image_configuration)):
                    return _receipt(self.journal._write_state(row, "needs_attention", "resource_conflict"))
            else:
                created = self.journal._read(command.job_id, "create_container")
                if (created is None or created["state"] != "succeeded" or not _matches(observed, binding)
                        or observed["Id"] != created["container"]
                        or type(observed.get("State")) is not dict or observed["State"].get("Status") != "created"):
                    return _receipt(self.journal._write_state(row, "needs_attention", "resource_conflict"))
            identity = observed["Id"] if observed is not None else None
            if command.start_deadline <= time.time():
                return _receipt(self.journal._write_state(row, "needs_attention", "dispatch_expired", identity))
            row = self.journal._write_state(row, "mutating", "engine_operation_pending", identity)
            try:
                if command.kind == "create_container":
                    identity = self.engine.create_container(binding)
                else:
                    self.engine.start_container(identity)
            except DockerWorkerError as error:
                code = "resource_conflict" if error.code == "engine_conflict" else "engine_operation_uncertain"
                state = "needs_attention" if error.code == "engine_conflict" else "uncertain"
                return _receipt(self.journal._write_state(row, state, code, identity))
            # Record returned identity before the read-only confirmation. Any
            # failure to persist stops here; the prior durable intent survives.
            row = self.journal._write_state(row, "mutating", "engine_operation_pending", identity)
            return self._reconcile(row, binding)

    def _reconcile(self, row, binding):
        try:
            observed = self.engine.inspect_container(binding.name)
        except DockerWorkerError:
            return _receipt(self.journal._write_state(row, "uncertain", "engine_operation_uncertain", row["container"]))
        if not _matches(observed, binding) or row["container"] is not None and observed["Id"] != row["container"]:
            return _receipt(self.journal._write_state(row, "needs_attention", "resource_conflict", row["container"]))
        if row["step"] == "start_container" and (type(observed.get("State")) is not dict
                                                or observed["State"].get("Running") is not True):
            return _receipt(self.journal._write_state(row, "needs_attention", "container_not_running", observed["Id"]))
        code = "container_created" if row["step"] == "create_container" else "container_started"
        return _receipt(self.journal._write_state(row, "succeeded", code, observed["Id"]))

    def reconcile(self, job_id, step):
        with self.journal.locked():
            row = self.journal._read(job_id, step)
            _require(row is not None, "record_missing")
            if row["state"] in {"mutating", "uncertain"}:
                return self._reconcile(row, _stored_binding(row))
            return _receipt(row)

    def observe(self, job_id, step):
        with self.journal.locked():
            row = self.journal._read(job_id, step)
            _require(row is not None, "record_missing")
            return _receipt(row)


def inspect_catalog_plan(plan, catalog):
    """Pure plan boundary. Never open Docker or promote readiness into install."""
    from .catalog import verify_plan
    try:
        verified = verify_plan(plan, catalog)
    except (ValueError, TypeError):
        raise DockerWorkerError("catalog_rejected") from None
    _require(not verified.installable, "worker_unverified")
    return {"planHash": verified.planHash, "catalogDigest": verified.catalogDigest,
            "manifestDigest": verified.manifestDigest, "platform": verified.image.platform,
            "integrationRole": verified.integrationRole,
            "installable": False, "code": "worker_unverified"}
