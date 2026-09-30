"""Durable authenticated terminal callbacks from the Unmanic event plugin."""

from contextlib import contextmanager
import fcntl
import hashlib
import hmac
import math
import os
from pathlib import Path
import re
import sqlite3
import stat
import threading
import time

from ..plugins.worker import DockerWorkerError, _safe_path
from .unmanic import (
    UnmanicHttpError,
    UnmanicTerminalLookup,
    _decode_terminal_callback_body,
    _integer,
    _path,
)


_MAX_CALLBACKS = 2048
_MAX_NONCES = 4096
_MAX_DATABASE_BYTES = 64 * 1024 * 1024
_HEX = re.compile(r"[0-9a-f]{64}\Z")
_SCHEMA = (
    "CREATE TABLE callbacks(task_id INTEGER NOT NULL,work_path TEXT NOT NULL,"
    "timestamp INTEGER NOT NULL,nonce TEXT NOT NULL,body BLOB NOT NULL,"
    "body_digest TEXT NOT NULL,signature TEXT NOT NULL,"
    "PRIMARY KEY(task_id,work_path))",
    "CREATE TABLE nonces(nonce TEXT NOT NULL PRIMARY KEY,task_id INTEGER NOT NULL,"
    "work_path TEXT NOT NULL,body_digest TEXT NOT NULL)",
)


class UnmanicTerminalStoreError(RuntimeError):
    _CODES = frozenset({
        "terminal_store_unavailable",
        "terminal_store_busy",
        "terminal_store_full",
        "terminal_callback_invalid",
        "terminal_callback_unauthorized",
        "terminal_callback_replayed",
        "terminal_callback_conflict",
    })

    def __init__(self, code="terminal_store_unavailable"):
        self.code = code if code in self._CODES else "terminal_store_unavailable"
        super().__init__(self.code)


def _require(condition, code="terminal_store_unavailable"):
    if not condition:
        raise UnmanicTerminalStoreError(code)


class UnmanicTerminalStore(UnmanicTerminalLookup):
    """Persist one immutable terminal callback per exact task/work-path pair."""

    def __init__(self, directory, key, *, clock=None, max_skew_seconds=300):
        if (
            type(key) is not bytes
            or len(key) < 32
            or not callable(clock or time.time)
            or type(max_skew_seconds) is not int
            or not 30 <= max_skew_seconds <= 900
        ):
            raise UnmanicTerminalStoreError()
        self.directory = Path(directory).absolute()
        self.database_path = self.directory / "unmanic-terminal.sqlite"
        self.lock_path = self.directory / "unmanic-terminal.lock"
        self._key = hmac.new(
            key, b"larenor-unmanic-callback-v1", hashlib.sha256
        ).digest()
        self._clock = clock or time.time
        self._max_skew = max_skew_seconds
        self._mutex = threading.Lock()
        self._db = None
        self._lock_fd = None
        self._closed = False
        try:
            _safe_path(
                self.directory, uid=os.getuid(), kind=stat.S_ISDIR, private=True
            )
            new_database = not os.path.lexists(self.database_path)
            new_lock = not os.path.lexists(self.lock_path)
            _require(new_database == new_lock)
            if new_database:
                for path in (self.database_path, self.lock_path):
                    descriptor = os.open(
                        path,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                        0o600,
                    )
                    os.close(descriptor)
            for path in (self.database_path, self.lock_path):
                _safe_path(path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
            self._file_identity = (
                self.database_path.stat().st_dev,
                self.database_path.stat().st_ino,
            )
            self._lock_fd = os.open(
                self.lock_path, os.O_RDWR | os.O_NOFOLLOW
            )
            self._db = sqlite3.connect(
                self.database_path,
                isolation_level=None,
                timeout=2,
                check_same_thread=False,
            )
            self._db.row_factory = sqlite3.Row
            self._db.execute("PRAGMA journal_mode=DELETE")
            self._db.execute("PRAGMA synchronous=FULL")
            with self._locked():
                if new_database:
                    self._db.execute("BEGIN IMMEDIATE")
                    for statement in _SCHEMA:
                        self._db.execute(statement)
                    self._db.execute("COMMIT")
                    descriptor = os.open(
                        self.directory, os.O_RDONLY | os.O_DIRECTORY
                    )
                    try:
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                self._validate_schema()
        except Exception:
            self.close()
            raise UnmanicTerminalStoreError() from None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()

    def close(self):
        if self._closed:
            return
        self._closed = True
        if self._db is not None:
            self._db.close()
        if self._lock_fd is not None:
            os.close(self._lock_fd)

    def _paths(self):
        _safe_path(
            self.directory, uid=os.getuid(), kind=stat.S_ISDIR, private=True
        )
        for path in (self.database_path, self.lock_path):
            _safe_path(path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
        current = self.database_path.stat()
        lock = self.lock_path.stat()
        opened = os.fstat(self._lock_fd)
        _require(
            (current.st_dev, current.st_ino) == self._file_identity
            and current.st_size <= _MAX_DATABASE_BYTES
            and (lock.st_dev, lock.st_ino) == (opened.st_dev, opened.st_ino)
        )

    @contextmanager
    def _locked(self):
        _require(
            not self._closed and self._mutex.acquire(blocking=False),
            "terminal_store_busy",
        )
        acquired = False
        try:
            self._paths()
            try:
                fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
            except OSError:
                raise UnmanicTerminalStoreError("terminal_store_busy") from None
            yield
        except DockerWorkerError:
            raise UnmanicTerminalStoreError() from None
        finally:
            if acquired:
                fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            self._mutex.release()

    def _validate_schema(self):
        _require(self._db.execute("PRAGMA integrity_check").fetchone()[0] == "ok")
        rows = self._db.execute(
            "SELECT sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name"
        ).fetchall()
        _require(
            [" ".join(row[0].split()) for row in rows]
            == [" ".join(statement.split()) for statement in _SCHEMA]
        )
        callbacks = self._db.execute(
            "SELECT * FROM callbacks ORDER BY task_id,work_path LIMIT ?",
            (_MAX_CALLBACKS + 1,),
        ).fetchall()
        nonces = self._db.execute(
            "SELECT * FROM nonces ORDER BY nonce LIMIT ?", (_MAX_NONCES + 1,)
        ).fetchall()
        _require(len(callbacks) <= _MAX_CALLBACKS and len(nonces) <= _MAX_NONCES)
        for row in callbacks:
            self._stored(row)
            nonce = self._db.execute(
                "SELECT * FROM nonces WHERE nonce=?", (row["nonce"],)
            ).fetchone()
            _require(
                nonce is not None
                and nonce["task_id"] == row["task_id"]
                and nonce["work_path"] == row["work_path"]
                and nonce["body_digest"] == row["body_digest"]
            )
        for row in nonces:
            _require(
                _HEX.fullmatch(row["nonce"]) is not None
                and _HEX.fullmatch(row["body_digest"]) is not None
            )
            callback = self._db.execute(
                "SELECT * FROM callbacks WHERE task_id=? AND work_path=?",
                (row["task_id"], row["work_path"]),
            ).fetchone()
            _require(
                callback is not None
                and callback["body_digest"] == row["body_digest"]
            )

    def _now(self):
        value = self._clock()
        _require(
            type(value) in (int, float)
            and type(value) is not bool
            and math.isfinite(value)
            and 1 <= value <= 253402300799,
            "terminal_store_unavailable",
        )
        return int(value)

    def _signature(self, timestamp, nonce, body):
        return hmac.new(
            self._key,
            b"v1\n" + str(timestamp).encode("ascii") + b"\n"
            + nonce.encode("ascii") + b"\n" + body,
            hashlib.sha256,
        ).hexdigest()

    def _authenticated(self, headers, body):
        try:
            if type(headers) is not dict or set(headers) != {
                "x-larenor-unmanic-timestamp",
                "x-larenor-unmanic-nonce",
                "x-larenor-unmanic-signature",
            }:
                raise ValueError
            raw_timestamp = headers["x-larenor-unmanic-timestamp"]
            nonce = headers["x-larenor-unmanic-nonce"]
            signature = headers["x-larenor-unmanic-signature"]
            if (
                type(raw_timestamp) is not str
                or not raw_timestamp.isascii()
                or not raw_timestamp.isdecimal()
                or raw_timestamp != str(int(raw_timestamp))
                or type(nonce) is not str
                or _HEX.fullmatch(nonce) is None
                or type(signature) is not str
                or _HEX.fullmatch(signature) is None
            ):
                raise ValueError
            timestamp = int(raw_timestamp)
            if abs(self._now() - timestamp) > self._max_skew:
                raise ValueError
            expected = self._signature(timestamp, nonce, body)
            if not hmac.compare_digest(expected, signature):
                raise ValueError
            receipt = _decode_terminal_callback_body(body)
            return timestamp, nonce, signature, receipt
        except (ValueError, TypeError, UnmanicHttpError):
            raise UnmanicTerminalStoreError(
                "terminal_callback_unauthorized"
            ) from None

    def _stored(self, row):
        try:
            _integer(row["task_id"])
            work_path = _path(row["work_path"])
            _require(
                type(row["timestamp"]) is int
                and 1 <= row["timestamp"] <= 253402300799
                and _HEX.fullmatch(row["nonce"]) is not None
                and type(row["body"]) is bytes
                and _HEX.fullmatch(row["body_digest"]) is not None
                and _HEX.fullmatch(row["signature"]) is not None
                and hmac.compare_digest(
                    hashlib.sha256(row["body"]).hexdigest(), row["body_digest"]
                )
                and hmac.compare_digest(
                    self._signature(row["timestamp"], row["nonce"], row["body"]),
                    row["signature"],
                )
            )
            receipt = _decode_terminal_callback_body(row["body"])
            _require(
                receipt.providerTaskId == row["task_id"]
                and receipt.workPath == work_path
                and receipt.callbackDigest == row["body_digest"]
            )
            return receipt
        except (KeyError, TypeError, ValueError, UnmanicHttpError):
            raise UnmanicTerminalStoreError() from None

    def ingest(self, headers, body):
        timestamp, nonce, signature, receipt = self._authenticated(headers, body)
        digest = receipt.callbackDigest
        with self._locked():
            self._validate_schema()
            try:
                self._db.execute("BEGIN IMMEDIATE")
                replay = self._db.execute(
                    "SELECT * FROM nonces WHERE nonce=?", (nonce,)
                ).fetchone()
                if replay is not None:
                    if (
                        replay["task_id"] == receipt.providerTaskId
                        and replay["work_path"] == receipt.workPath
                        and hmac.compare_digest(replay["body_digest"], digest)
                    ):
                        existing = self._db.execute(
                            "SELECT * FROM callbacks WHERE task_id=? AND work_path=?",
                            (receipt.providerTaskId, receipt.workPath),
                        ).fetchone()
                        _require(existing is not None)
                        result = self._stored(existing)
                        self._db.execute("COMMIT")
                        return result
                    raise UnmanicTerminalStoreError("terminal_callback_replayed")
                existing = self._db.execute(
                    "SELECT * FROM callbacks WHERE task_id=? AND work_path=?",
                    (receipt.providerTaskId, receipt.workPath),
                ).fetchone()
                if existing is not None:
                    current = self._stored(existing)
                    if not hmac.compare_digest(current.callbackDigest, digest):
                        raise UnmanicTerminalStoreError("terminal_callback_conflict")
                counts = (
                    self._db.execute("SELECT COUNT(*) FROM callbacks").fetchone()[0],
                    self._db.execute("SELECT COUNT(*) FROM nonces").fetchone()[0],
                )
                _require(
                    counts[0] < _MAX_CALLBACKS or existing is not None,
                    "terminal_store_full",
                )
                _require(counts[1] < _MAX_NONCES, "terminal_store_full")
                if existing is None:
                    self._db.execute(
                        "INSERT INTO callbacks VALUES(?,?,?,?,?,?,?)",
                        (
                            receipt.providerTaskId, receipt.workPath, timestamp,
                            nonce, body, digest, signature,
                        ),
                    )
                self._db.execute(
                    "INSERT INTO nonces VALUES(?,?,?,?)",
                    (nonce, receipt.providerTaskId, receipt.workPath, digest),
                )
                self._db.execute("COMMIT")
                return receipt if existing is None else current
            except UnmanicTerminalStoreError:
                if self._db.in_transaction:
                    self._db.execute("ROLLBACK")
                raise
            except sqlite3.Error:
                if self._db.in_transaction:
                    self._db.execute("ROLLBACK")
                raise UnmanicTerminalStoreError() from None

    def lookup_terminal(self, provider_task_id, expected_work_path):
        try:
            provider_task_id = _integer(provider_task_id)
            expected_work_path = _path(expected_work_path)
        except (ValueError, UnmanicHttpError):
            raise UnmanicTerminalStoreError("terminal_callback_invalid") from None
        with self._locked():
            self._validate_schema()
            try:
                row = self._db.execute(
                    "SELECT * FROM callbacks WHERE task_id=? AND work_path=?",
                    (provider_task_id, expected_work_path),
                ).fetchone()
                return None if row is None else self._stored(row)
            except sqlite3.Error:
                raise UnmanicTerminalStoreError() from None
