"""Standalone Unmanic 0.4.1 event plugin with a durable, authenticated outbox.

This file is packaged as plugin.py without Larenor/Pydantic dependencies. Never
log the upstream event: it may contain paths, filenames and complete task logs.
"""

from contextlib import contextmanager
import fcntl
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import stat
import threading
import time


class CallbackOutboxError(RuntimeError):
    def __init__(self):
        super().__init__("archive_callback_unavailable")


def _check(value):
    if not value:
        raise CallbackOutboxError()


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _unique(pairs):
    value = {}
    for key, item in pairs:
        _check(key not in value)
        value[key] = item
    return value


def _private(path, directory=False):
    path = Path(path)
    _check(path.is_absolute() and ".." not in path.parts and path != Path("/"))
    for parent in (path, *path.parents):
        info = parent.lstat()
        _check(not stat.S_ISLNK(info.st_mode))
        if parent != path:
            _check(info.st_uid in {0, os.geteuid()})
            _check(not info.st_mode & 0o022 or info.st_uid == 0 and info.st_mode & stat.S_ISVTX)
    info = path.lstat()
    _check(info.st_uid == os.geteuid())
    _check(stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600))
    _check(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
    return path


def _sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _file(path, maximum):
    path = _private(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        value = stream.read(maximum+1)
    _check(len(value) <= maximum)
    return value


def _path(value, root):
    _check(type(value) is str and 1 <= len(value) <= 4096
           and all(ord(char) >= 32 and ord(char) != 127 for char in value))
    path = Path(value)
    _check(path.is_absolute() and ".." not in path.parts and str(path) == value)
    _check(path != root and root in path.parents)
    return value


def _body(data, work_root):
    _check(type(data) is dict)
    for field in ("task_id", "library_id"):
        _check(type(data.get(field)) is int and 1 <= data[field] <= 2**63-1)
    _check(data.get("task_type") == "local")
    _check(type(data.get("source_data")) is dict and type(data.get("destination_data")) is dict)
    source = _path(data["source_data"].get("abspath"), work_root)
    destination = _path(data["destination_data"].get("abspath"), work_root)
    paths = data.get("destination_files")
    _check(type(paths) is list and 0 <= len(paths) <= 16)
    paths = [_path(path, work_root) for path in paths]
    _check(len(set(paths)) == len(paths))
    for field in ("task_success", "file_move_processes_success"):
        _check(type(data.get(field)) is bool)
    _check(not (data['task_success'] and data['file_move_processes_success']) or destination in paths)
    start, finish = data.get("start_time"), data.get("finish_time")
    _check(type(start) in {int, float} and type(finish) in {int, float}
           and math.isfinite(start) and math.isfinite(finish) and 1 <= start <= finish <= 253402300799)
    worker = data.get("processed_by_worker")
    _check(type(worker) is str and 1 <= len(worker) <= 240
           and all(ord(char) >= 32 and ord(char) != 127 for char in worker))
    body = _canonical({
        "schemaVersion": 1, "taskId": data["task_id"], "libraryId": data["library_id"],
        "taskType": "local", "sourcePath": source, "destinationPath": destination,
        "destinationFiles": paths, "taskSuccess": data["task_success"],
        "fileMoveProcessesSuccess": data["file_move_processes_success"],
        "startTime": start, "finishTime": finish, "processedByWorker": worker,
    })
    _check(len(body) <= 64*1024)
    return body


class UnmanicCallbackOutbox:
    """Commit before returning from the event; remove only after a signed ACK."""

    def __init__(self, directory, key, work_root, port, *, clock=None):
        _check(type(key) is bytes and len(key) >= 32)
        _check(type(port) is int and 1024 <= port <= 65535)
        self.directory = _private(directory, True)
        self.work_root = _private(work_root, True)
        _check(self.directory != self.work_root and self.directory not in self.work_root.parents
               and self.work_root not in self.directory.parents)
        self._key = hmac.new(key, b"larenor-unmanic-callback-v1", hashlib.sha256).digest()
        self._port, self._clock = port, clock or time.time
        self._mutex, self._stopped = threading.Lock(), threading.Event()
        self._thread = None
        self._closed = False
        self.path = self.directory / "callback-outbox.sqlite"
        self.lock_path = self.directory / "callback-outbox.lock"
        created = not os.path.lexists(self.path)
        _check(created == (not os.path.lexists(self.lock_path)))
        if created:
            for path in (self.path, self.lock_path):
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                os.close(fd)
            _sync_directory(self.directory)
        _private(self.path)
        _private(self.lock_path)
        self._identity = (self.path.stat().st_dev, self.path.stat().st_ino)
        self._directory_identity = (self.directory.stat().st_dev, self.directory.stat().st_ino)
        self._lock_identity = (self.lock_path.stat().st_dev, self.lock_path.stat().st_ino)
        self._lock_fd = os.open(self.lock_path, os.O_RDWR | os.O_NOFOLLOW)
        self._db = sqlite3.connect(self.path, timeout=2, isolation_level=None, check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=DELETE")
        self._db.execute("PRAGMA synchronous=FULL")
        try:
            with self._locked():
                schema = "CREATE TABLE outbox(id TEXT PRIMARY KEY,body BLOB NOT NULL,signature TEXT NOT NULL)"
                if created:
                    self._db.execute(schema)
                _check(self._db.execute("PRAGMA integrity_check").fetchone()[0] == "ok")
                statements = self._db.execute("SELECT sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").fetchall()
                _check(statements == [(schema,)])
                rows = self._db.execute("SELECT id,body,signature FROM outbox LIMIT 2049").fetchall()
                _check(len(rows) <= 2048)
                identities = set()
                for row in rows:
                    value = self._validate(row)
                    identity = (value['taskId'], value['sourcePath'])
                    _check(identity not in identities)
                    identities.add(identity)
        except Exception:
            self.close()
            raise CallbackOutboxError() from None

    def __repr__(self):
        return "UnmanicCallbackOutbox(<private>)"

    @contextmanager
    def _locked(self):
        _check(self._mutex.acquire(timeout=2))
        locked = False
        try:
            _check(not self._closed)
            _private(self.directory, True)
            _private(self.path)
            _private(self.lock_path)
            info = self.path.stat()
            _check((info.st_dev, info.st_ino) == self._identity and info.st_size <= 128*1024*1024)
            directory_info, lock_info = self.directory.stat(), self.lock_path.stat()
            _check((directory_info.st_dev, directory_info.st_ino) == self._directory_identity
                   and (lock_info.st_dev, lock_info.st_ino) == self._lock_identity)
            fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = True
            yield
        except Exception:
            raise CallbackOutboxError() from None
        finally:
            if locked:
                fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            self._mutex.release()

    def _signature(self, body):
        return hmac.new(self._key, b"outbox-v1\n"+body, hashlib.sha256).hexdigest()

    def _validate(self, row):
        identifier, body, signature = row
        _check(type(identifier) is str and type(signature) is str
               and type(body) is bytes and 1 <= len(body) <= 64*1024
               and identifier == hashlib.sha256(body).hexdigest()
               and hmac.compare_digest(signature, self._signature(body)))
        value = json.loads(body.decode('utf-8'), object_pairs_hook=_unique)
        _check(_canonical(value) == body)
        _check(_body({
            'task_id': value['taskId'], 'library_id': value['libraryId'],
            'task_type': value['taskType'], 'source_data': {'abspath': value['sourcePath']},
            'destination_data': {'abspath': value['destinationPath']},
            'destination_files': value['destinationFiles'], 'task_success': value['taskSuccess'],
            'file_move_processes_success': value['fileMoveProcessesSuccess'],
            'start_time': value['startTime'], 'finish_time': value['finishTime'],
            'processed_by_worker': value['processedByWorker'],
        }, self.work_root) == body)
        return value

    def enqueue(self, data):
        try:
            body = _body(data, self.work_root)
            identifier = hashlib.sha256(body).hexdigest()
            with self._locked():
                row = self._db.execute("SELECT id,body,signature FROM outbox WHERE id=?", (identifier,)).fetchone()
                if row is not None:
                    self._validate(row)
                    return identifier
                rows = self._db.execute("SELECT id,body,signature FROM outbox LIMIT 2049").fetchall()
                _check(len(rows) < 2048)
                value = json.loads(body)
                for existing in rows:
                    other = self._validate(existing)
                    _check((other['taskId'], other['sourcePath']) != (value['taskId'], value['sourcePath']))
                self._db.execute("BEGIN IMMEDIATE")
                try:
                    self._db.execute("INSERT INTO outbox VALUES(?,?,?)", (identifier, body, self._signature(body)))
                    self._db.execute("COMMIT")
                except Exception:
                    self._db.execute("ROLLBACK")
                    raise
                _sync_directory(self.directory)
            return identifier
        except Exception:
            raise CallbackOutboxError() from None

    def pending(self):
        with self._locked():
            return self._db.execute("SELECT COUNT(*) FROM outbox").fetchone()[0]

    def _send(self, identifier, body):
        timestamp, nonce = str(int(self._clock())), secrets.token_hex(32)
        signature = hmac.new(self._key, ("v1\n"+timestamp+"\n"+nonce+"\n").encode()+body,
                             hashlib.sha256).hexdigest()
        message = (
            "POST /larenor/unmanic/terminal HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self._port}\r\nConnection: close\r\n"
            f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
            f"X-Larenor-Unmanic-Timestamp: {timestamp}\r\n"
            f"X-Larenor-Unmanic-Nonce: {nonce}\r\n"
            f"X-Larenor-Unmanic-Signature: {signature}\r\n\r\n"
        ).encode("ascii")+body
        deadline = time.monotonic()+2
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as stream:
            stream.settimeout(max(0.001, deadline-time.monotonic()))
            stream.connect(("127.0.0.1", self._port))
            stream.settimeout(max(0.001, deadline-time.monotonic()))
            stream.sendall(message)
            response = bytearray()
            while b"\r\n\r\n" not in response:
                stream.settimeout(max(0.001, deadline-time.monotonic()))
                piece = stream.recv(2048)
                _check(piece and len(response)+len(piece) <= 4096 and time.monotonic() < deadline)
                response.extend(piece)
            head, raw = bytes(response).split(b"\r\n\r\n", 1)
            lines = head.split(b"\r\n")
            _check(lines[0] in {b"HTTP/1.0 200 OK", b"HTTP/1.1 200 OK"})
            headers = {}
            for line in lines[1:]:
                name, value = line.decode("ascii").split(":", 1)
                _check(name.lower() not in headers)
                headers[name.lower()] = value.strip()
            _check(headers.get("content-type") == "application/json"
                   and "transfer-encoding" not in headers)
            length = int(headers["content-length"])
            _check(1 <= length <= 512 and len(raw) <= length)
            while len(raw) < length:
                stream.settimeout(max(0.001, deadline-time.monotonic()))
                piece = stream.recv(length-len(raw))
                _check(piece and time.monotonic() < deadline)
                raw += piece
        ack = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique)
        _check(set(ack) == {"schemaVersion", "acceptedDigest", "nonce", "signature"}
               and type(ack["schemaVersion"]) is int and ack["schemaVersion"] == 1
               and ack["acceptedDigest"] == identifier and ack["nonce"] == nonce)
        expected = hmac.new(self._key, ("ack-v1\n"+nonce+"\n"+identifier).encode(), hashlib.sha256).hexdigest()
        _check(hmac.compare_digest(ack["signature"], expected))

    def flush_one(self):
        with self._locked():
            row = self._db.execute("SELECT id,body,signature FROM outbox ORDER BY id LIMIT 1").fetchone()
            if row is None:
                return False
            self._validate(row)
        try:
            self._send(row[0], row[1])
        except Exception:
            return False
        with self._locked():
            self._db.execute("DELETE FROM outbox WHERE id=? AND signature=?", (row[0], row[2]))
            _sync_directory(self.directory)
        return True

    def start(self):
        _check(self._thread is None and not self._closed)

        def run():
            while not self._stopped.is_set():
                try:
                    delivered = self.flush_one()
                except Exception:
                    delivered = False
                self._stopped.wait(0.05 if delivered else 2)

        self._thread = threading.Thread(target=run, name="larenor-callback-outbox", daemon=True)
        self._thread.start()

    def close(self):
        self._stopped.set()
        if self._thread is not None:
            self._thread.join(timeout=3)
        with self._mutex:
            if self._closed:
                return
            _check(self._thread is None or not self._thread.is_alive())
            self._closed = True
            self._db.close()
            os.close(self._lock_fd)


_PLUGIN = None
_PLUGIN_LOCK = threading.Lock()


def _configured():
    raw = _file(os.environ.get("LARENOR_UNMANIC_CALLBACK_CONFIG", "/config/larenor/archive-callback.json"), 4096)
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique)
    _check(set(value) == {"schemaVersion", "outboxDirectory", "workRoot", "keyFile", "callbackPort"}
           and type(value["schemaVersion"]) is int and value["schemaVersion"] == 1)
    key = _file(value["keyFile"], 128)
    return UnmanicCallbackOutbox(value["outboxDirectory"], key, value["workRoot"], value["callbackPort"])


def emit_postprocessor_complete(data):
    global _PLUGIN
    try:
        with _PLUGIN_LOCK:
            if _PLUGIN is None:
                _PLUGIN = _configured()
                _PLUGIN.start()
            _PLUGIN.enqueue(data)
    except Exception:
        raise CallbackOutboxError() from None


# Unmanic dynamically imports this file when loading the library plugin. Start
# retrying existing rows at that point, even if no new task event arrives.
if os.environ.get("LARENOR_UNMANIC_CALLBACK_CONFIG"):
    try:
        _PLUGIN = _configured()
        _PLUGIN.start()
    except Exception:
        raise CallbackOutboxError() from None
