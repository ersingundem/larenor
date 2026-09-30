"""Durable NUT NOTIFYCMD producer for authenticated power-recovery events."""

from __future__ import annotations

from dataclasses import dataclass
import argparse
from decimal import Decimal, InvalidOperation
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import signal
import socket
import sqlite3
import ssl
import stat
import struct
import subprocess
import time
import threading
from urllib.parse import urlsplit
import uuid


_SOURCE = re.compile(r"[A-Za-z0-9_.:-]{1,64}\Z")
_UPS = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}@"
    r"[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,251}[A-Za-z0-9])?"
    r"(?::[1-9][0-9]{0,4})?\Z"
)
_HOST = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\Z"
)
_NOTIFY = {"ONLINE", "ONBATT", "LOWBATT"}
_MAX_CONFIG = 32 * 1024
_MAX_UPSC = 64 * 1024
_MAX_RESPONSE = 64 * 1024
_MAX_EVENTS = 4096
_APPLICATION_ID = 0x4C4E5554
_NOTIFY_SOCKET = Path("/run/larenor-power-recovery/notify.sock")
_NOTIFY_WORKER_UID = 10006
_NOTIFY_WORKER_GID = 10006
_MAX_NOTIFY_FRAME = 1024


class NutBridgeError(RuntimeError):
    def __init__(self, code="bridge_unavailable", *, retryable=False):
        self.code = code if code in {
            "bridge_unavailable", "invalid_configuration", "invalid_notification",
            "upsc_unavailable", "invalid_upsc_response", "delivery_unavailable",
            "delivery_conflict", "authentication_failed", "invalid_core_response",
            "event_expired",
        } else "bridge_unavailable"
        self.retryable = retryable
        super().__init__(self.code)


def _pairs(items):
    value = {}
    for key, item in items:
        if key in value:
            raise ValueError()
        value[key] = item
    return value


def _canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"),
        ensure_ascii=True, allow_nan=False,
    ).encode("ascii")


def _safe_file(path, *, private=False, executable=False, maximum=None):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts or str(path) != str(path.absolute()):
        raise ValueError()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_uid not in {0, os.geteuid()}
            or info.st_mode & (0o077 if private else 0o022)
            or executable and not info.st_mode & 0o111
            or maximum is not None and not 1 <= info.st_size <= maximum
        ):
            raise ValueError()
        raw = bytearray()
        if maximum is not None:
            while len(raw) <= maximum:
                part = os.read(descriptor, min(65536, maximum + 1 - len(raw)))
                if not part:
                    break
                raw.extend(part)
            after = os.fstat(descriptor)
            current = os.stat(path, follow_symlinks=False)
            identity = lambda item: (
                item.st_dev, item.st_ino, item.st_uid, item.st_gid,
                item.st_mode, item.st_nlink, item.st_size,
                item.st_mtime_ns, item.st_ctime_ns,
            )
            if len(raw) != info.st_size or identity(info) != identity(after) or identity(after) != identity(current):
                raise ValueError()
        return bytes(raw), info
    finally:
        os.close(descriptor)


def _safe_directory(path):
    path = Path(path)
    info = os.stat(path, follow_symlinks=False)
    if (
        not path.is_absolute() or ".." in path.parts
        or not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise ValueError()
    return path


@dataclass(frozen=True, repr=False)
class NutBridgeConfig:
    source_id: str
    source_revision: int
    source_token: str
    ups_name: str
    core_url: str
    core_host: str
    core_port: int
    ca_file: Path
    ca_sha256: str
    upsc: Path
    upsc_sha256: str
    state_root: Path
    max_event_age_seconds: int
    upsc_timeout_seconds: int
    http_timeout_seconds: int
    retry_seconds: int
    notify_user: str

    def __repr__(self):
        return "NutBridgeConfig(<private>)"

    @classmethod
    def load(cls, path):
        try:
            raw, info = _safe_file(path, private=True, maximum=_MAX_CONFIG)
            if info.st_uid != os.geteuid():
                raise ValueError()
            value = json.loads(
                raw.decode("utf-8"), object_pairs_hook=_pairs,
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
            )
            expected = {
                "schemaVersion", "sourceId", "sourceRevision", "sourceToken",
                "upsName", "coreUrl", "caFile", "caSha256", "upsc", "upscSha256",
                "stateRoot", "maxEventAgeSeconds", "upscTimeoutSeconds",
                "httpTimeoutSeconds", "retrySeconds", "notifyUser",
            }
            if type(value) is not dict or set(value) != expected or value["schemaVersion"] != 1:
                raise ValueError()
            split = urlsplit(value["coreUrl"])
            if (
                split.scheme != "https" or split.username is not None
                or split.password is not None or split.query or split.fragment
                or split.path not in {"", "/"} or split.hostname is None
                or _HOST.fullmatch(split.hostname) is None
                or split.port is None or not 1 <= split.port <= 65535
                or _SOURCE.fullmatch(value["sourceId"]) is None
                or type(value["sourceRevision"]) is not int
                or not 1 <= value["sourceRevision"] <= 2**63 - 1
                or type(value["sourceToken"]) is not str
                or not 32 <= len(value["sourceToken"].encode("utf-8")) <= 512
                or any(ord(char) < 32 or ord(char) == 127 for char in value["sourceToken"])
                or type(value["upsName"]) is not str
                or _UPS.fullmatch(value["upsName"]) is None
                or value["notifyUser"] != "nut"
                or type(value["caSha256"]) is not str
                or re.fullmatch(r"[0-9a-f]{64}", value["caSha256"]) is None
                or type(value["upscSha256"]) is not str
                or re.fullmatch(r"[0-9a-f]{64}", value["upscSha256"]) is None
            ):
                raise ValueError()
            bounds = (
                ("maxEventAgeSeconds", 30, 240),
                ("upscTimeoutSeconds", 1, 10),
                ("httpTimeoutSeconds", 1, 10),
                ("retrySeconds", 1, 60),
            )
            if any(type(value[key]) is not int or not low <= value[key] <= high
                   for key, low, high in bounds):
                raise ValueError()
            ca_file = Path(value["caFile"])
            upsc = Path(value["upsc"])
            ca_raw, _ = _safe_file(ca_file, maximum=1024 * 1024)
            if not __import__("hmac").compare_digest(
                hashlib.sha256(ca_raw).hexdigest(), value["caSha256"]
            ):
                raise ValueError()
            observed, _ = _safe_file(upsc, executable=True, maximum=32 * 1024 * 1024)
            if not __import__("hmac").compare_digest(
                hashlib.sha256(observed).hexdigest(), value["upscSha256"]
            ):
                raise ValueError()
            return cls(
                value["sourceId"], value["sourceRevision"], value["sourceToken"],
                value["upsName"], value["coreUrl"].rstrip("/"), split.hostname,
                split.port, ca_file, value["caSha256"], upsc, value["upscSha256"],
                _safe_directory(Path(value["stateRoot"])),
                value["maxEventAgeSeconds"], value["upscTimeoutSeconds"],
                value["httpTimeoutSeconds"], value["retrySeconds"],
                value["notifyUser"],
            )
        except NutBridgeError:
            raise
        except Exception:
            raise NutBridgeError("invalid_configuration") from None


class NutBridgeOutbox:
    def __init__(self, config, *, clock=None):
        if type(config) is not NutBridgeConfig:
            raise NutBridgeError("invalid_configuration")
        self.config = config
        self.clock = clock or time.time
        key = hashlib.sha256(
            f"{config.source_id}:{config.source_revision}".encode("ascii")
        ).hexdigest()[:24]
        self.path = config.state_root / f"nut-events-{key}.sqlite"
        created = False
        try:
            if not os.path.lexists(self.path):
                try:
                    descriptor = os.open(
                        self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                        0o600,
                    )
                except FileExistsError:
                    pass
                else:
                    os.close(descriptor)
                    created = True
            _safe_file(self.path, private=True)
            with self._connect() as connection:
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute("PRAGMA synchronous=FULL")
                connection.execute("PRAGMA trusted_schema=OFF")
                connection.executescript("""
                    CREATE TABLE IF NOT EXISTS metadata(
                        id INTEGER PRIMARY KEY CHECK(id=1),
                        source_id TEXT NOT NULL,
                        source_revision INTEGER NOT NULL,
                        last_sequence INTEGER NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS notices(
                        ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
                        notice_id TEXT NOT NULL UNIQUE,
                        ups_name TEXT NOT NULL,
                        notify_type TEXT NOT NULL,
                        received_at INTEGER NOT NULL,
                        state TEXT NOT NULL,
                        body BLOB,
                        body_sha256 TEXT,
                        sequence INTEGER UNIQUE,
                        attempts INTEGER NOT NULL DEFAULT 0,
                        last_attempt_at INTEGER,
                        error_code TEXT
                    );
                """)
                if created:
                    connection.execute(f"PRAGMA application_id={_APPLICATION_ID}")
                    connection.execute("PRAGMA user_version=1")
                self._validate_storage(connection)
                row = connection.execute("SELECT * FROM metadata WHERE id=1").fetchone()
                if row is None:
                    connection.execute(
                        "INSERT INTO metadata VALUES(1,?,?,0)",
                        (config.source_id, config.source_revision),
                    )
                elif (row["source_id"], row["source_revision"]) != (
                    config.source_id, config.source_revision
                ):
                    raise ValueError()
                if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise ValueError()
            if created:
                directory = os.open(config.state_root, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
        except Exception:
            raise NutBridgeError() from None

    def _connect(self):
        connection = sqlite3.connect(self.path, timeout=3)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("PRAGMA trusted_schema=OFF")
        return connection

    @staticmethod
    def _validate_storage(connection):
        expected = {
            "metadata": (
                ("id", "INTEGER", 0, None, 1),
                ("source_id", "TEXT", 1, None, 0),
                ("source_revision", "INTEGER", 1, None, 0),
                ("last_sequence", "INTEGER", 1, None, 0),
            ),
            "notices": (
                ("ordinal", "INTEGER", 0, None, 1),
                ("notice_id", "TEXT", 1, None, 0),
                ("ups_name", "TEXT", 1, None, 0),
                ("notify_type", "TEXT", 1, None, 0),
                ("received_at", "INTEGER", 1, None, 0),
                ("state", "TEXT", 1, None, 0),
                ("body", "BLOB", 0, None, 0),
                ("body_sha256", "TEXT", 0, None, 0),
                ("sequence", "INTEGER", 0, None, 0),
                ("attempts", "INTEGER", 1, "0", 0),
                ("last_attempt_at", "INTEGER", 0, None, 0),
                ("error_code", "TEXT", 0, None, 0),
            ),
        }
        objects = connection.execute(
            "SELECT type,name,sql FROM sqlite_master ORDER BY type,name"
        ).fetchall()
        if any(row["type"] not in {"index", "table"} for row in objects):
            raise ValueError()
        tables = {row["name"] for row in objects if row["type"] == "table"}
        if tables != {"metadata", "notices", "sqlite_sequence"}:
            raise ValueError()
        if any(
            row["type"] == "index"
            and (row["sql"] is not None or not row["name"].startswith("sqlite_autoindex_notices_"))
            for row in objects
        ):
            raise ValueError()
        for table, columns in expected.items():
            observed = tuple(
                (row["name"], row["type"], row["notnull"], row["dflt_value"], row["pk"])
                for row in connection.execute(f"PRAGMA table_info({table})")
            )
            if observed != columns:
                raise ValueError()
        if (
            connection.execute("PRAGMA application_id").fetchone()[0] != _APPLICATION_ID
            or connection.execute("PRAGMA user_version").fetchone()[0] != 1
        ):
            raise ValueError()

    def enqueue(self, environ):
        try:
            ups_name = environ.get("UPSNAME")
            notify_type = environ.get("NOTIFYTYPE")
            if ups_name != self.config.ups_name or notify_type not in _NOTIFY:
                raise NutBridgeError("invalid_notification")
            notice_id = uuid.uuid4().hex
            now = int(self.clock())
            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                count = connection.execute("SELECT COUNT(*) FROM notices").fetchone()[0]
                if count >= _MAX_EVENTS:
                    raise NutBridgeError()
                connection.execute(
                    "INSERT INTO notices(notice_id,ups_name,notify_type,received_at,state) VALUES(?,?,?,?, 'pending')",
                    (notice_id, ups_name, notify_type, now),
                )
                connection.commit()
            return notice_id
        except NutBridgeError:
            raise
        except Exception:
            raise NutBridgeError() from None

    def head(self):
        try:
            with self._connect() as connection:
                row = connection.execute(
                    "SELECT * FROM notices WHERE state!='delivered' ORDER BY ordinal LIMIT 1"
                ).fetchone()
                return None if row is None else dict(row)
        except sqlite3.Error:
            raise NutBridgeError() from None

    def sample(self, notice_id, body):
        raw = _canonical(body)
        digest = hashlib.sha256(raw).hexdigest()
        try:
            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                head = connection.execute(
                    "SELECT * FROM notices WHERE state!='delivered' ORDER BY ordinal LIMIT 1"
                ).fetchone()
                metadata = connection.execute("SELECT last_sequence FROM metadata WHERE id=1").fetchone()
                if head is None or head["notice_id"] != notice_id or head["state"] != "pending":
                    raise ValueError()
                sequence = metadata["last_sequence"] + 1
                body["sequence"] = sequence
                event_material = _canonical({**body, "eventId": notice_id})
                body["eventId"] = hashlib.sha256(
                    b"larenor-nut-event-v1\n" + event_material
                ).hexdigest()[:32]
                raw = _canonical(body)
                digest = hashlib.sha256(raw).hexdigest()
                connection.execute(
                    "UPDATE notices SET state='sampled',body=?,body_sha256=?,sequence=? WHERE notice_id=?",
                    (raw, digest, sequence, notice_id),
                )
                connection.commit()
                return body
        except Exception:
            raise NutBridgeError() from None

    def attempt(self, notice_id, expected_digest, now):
        try:
            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                row = connection.execute(
                    "SELECT state,body_sha256 FROM notices WHERE notice_id=?", (notice_id,)
                ).fetchone()
                if row is None or row["state"] not in {"sampled", "dispatching"} or row["body_sha256"] != expected_digest:
                    raise ValueError()
                connection.execute(
                    "UPDATE notices SET state='dispatching',attempts=attempts+1,last_attempt_at=? WHERE notice_id=?",
                    (now, notice_id),
                )
                connection.commit()
        except Exception:
            raise NutBridgeError() from None

    def delivered(self, notice_id, expected_digest, sequence):
        try:
            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                row = connection.execute(
                    "SELECT state,body_sha256,sequence FROM notices WHERE notice_id=?", (notice_id,)
                ).fetchone()
                metadata = connection.execute("SELECT last_sequence FROM metadata WHERE id=1").fetchone()
                if (
                    row is None or row["state"] != "dispatching"
                    or row["body_sha256"] != expected_digest or row["sequence"] != sequence
                    or metadata["last_sequence"] + 1 != sequence
                ):
                    raise ValueError()
                connection.execute(
                    "UPDATE notices SET state='delivered',error_code=NULL WHERE notice_id=?",
                    (notice_id,),
                )
                connection.execute(
                    "UPDATE metadata SET last_sequence=? WHERE id=1", (sequence,)
                )
                old = connection.execute(
                    "SELECT ordinal FROM notices WHERE state='delivered' ORDER BY ordinal DESC LIMIT 1 OFFSET 255"
                ).fetchone()
                if old is not None:
                    connection.execute(
                        "DELETE FROM notices WHERE state='delivered' AND ordinal<?",
                        (old["ordinal"],),
                    )
                connection.commit()
        except Exception:
            raise NutBridgeError() from None

    def block(self, notice_id, code):
        try:
            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                row = connection.execute(
                    "SELECT state FROM notices WHERE notice_id=?", (notice_id,)
                ).fetchone()
                if row is None or row["state"] == "delivered":
                    raise ValueError()
                connection.execute(
                    "UPDATE notices SET state='blocked',error_code=? WHERE notice_id=?",
                    (code, notice_id),
                )
                connection.commit()
        except Exception:
            raise NutBridgeError() from None

    def status(self):
        try:
            with self._connect() as connection:
                metadata = connection.execute("SELECT * FROM metadata WHERE id=1").fetchone()
                pending = connection.execute(
                    "SELECT COUNT(*) FROM notices WHERE state!='delivered'"
                ).fetchone()[0]
                delivered = connection.execute(
                    "SELECT COUNT(*) FROM notices WHERE state='delivered'"
                ).fetchone()[0]
                blocked = connection.execute(
                    "SELECT error_code FROM notices WHERE state='blocked' ORDER BY ordinal LIMIT 1"
                ).fetchone()
                return {
                    "sourceId": metadata["source_id"],
                    "sourceRevision": metadata["source_revision"],
                    "lastDeliveredSequence": metadata["last_sequence"],
                    "pending": pending,
                    "delivered": delivered,
                    "blocked": None if blocked is None else blocked["error_code"],
                }
        except sqlite3.Error:
            raise NutBridgeError() from None


def _parse_upsc(raw, notify_type):
    try:
        if type(raw) is not bytes or not 1 <= len(raw) <= _MAX_UPSC:
            raise ValueError()
        values = {}
        for line in raw.decode("utf-8").splitlines():
            key, separator, value = line.partition(": ")
            if not separator or key in values or not key or len(key) > 128 or len(value) > 1024:
                raise ValueError()
            values[key] = value
        charge = values["battery.charge"]
        runtime = values["battery.runtime"]
        tokens = set(values["ups.status"].split())
        if (
            re.fullmatch(r"[0-9]+(?:\.0+)?", charge) is None
            or re.fullmatch(r"[0-9]+(?:\.0+)?", runtime) is None
        ):
            raise ValueError()
        charge_decimal, runtime_decimal = Decimal(charge), Decimal(runtime)
        if (
            charge_decimal != charge_decimal.to_integral_value()
            or runtime_decimal != runtime_decimal.to_integral_value()
        ):
            raise ValueError()
        charge_number, runtime_number = int(charge_decimal), int(runtime_decimal)
        if not 0 <= charge_number <= 100 or not 0 <= runtime_number <= 86400:
            raise ValueError()
        if notify_type == "ONLINE":
            if "OL" not in tokens or tokens & {"OB", "LB"}:
                raise ValueError()
            return "online", charge_number, 0
        if "OB" not in tokens or "OL" in tokens:
            raise ValueError()
        if notify_type == "LOWBATT" and "LB" not in tokens:
            raise ValueError()
        return ("lowBattery" if "LB" in tokens else "onBattery"), charge_number, runtime_number
    except (InvalidOperation, KeyError, ValueError, TypeError, UnicodeError):
        raise NutBridgeError("invalid_upsc_response", retryable=True) from None


class NutBridgeWorker:
    def __init__(self, config, outbox, *, upsc, deliver, clock=None):
        if type(config) is not NutBridgeConfig or type(outbox) is not NutBridgeOutbox:
            raise NutBridgeError("invalid_configuration")
        self.config, self.outbox = config, outbox
        self.upsc, self.deliver = upsc, deliver
        self.clock = clock or time.time

    def run_once(self):
        head = self.outbox.head()
        if head is None:
            return "idle"
        if head["state"] == "blocked":
            return "blocked"
        now = int(self.clock())
        if head["state"] == "pending":
            if now - head["received_at"] > self.config.max_event_age_seconds:
                self.outbox.block(head["notice_id"], "event_expired")
                return "blocked"
            try:
                raw = self.upsc(
                    self.config.ups_name, self.config.upsc_timeout_seconds,
                )
                state, charge, runtime = _parse_upsc(raw, head["notify_type"])
            except NutBridgeError as error:
                if error.retryable:
                    return "retry"
                self.outbox.block(head["notice_id"], error.code)
                return "blocked"
            body = {
                "contractVersion": 1,
                "eventId": "0" * 32,
                "sourceId": self.config.source_id,
                "sourceRevision": self.config.source_revision,
                "sequence": 0,
                "state": state,
                "chargePercent": charge,
                "runtimeSeconds": runtime,
                "observedAt": int(self.clock()),
            }
            body = self.outbox.sample(head["notice_id"], body)
            head = self.outbox.head()
        try:
            raw = bytes(head["body"])
            digest = hashlib.sha256(raw).hexdigest()
            if digest != head["body_sha256"]:
                raise NutBridgeError()
            body = json.loads(raw.decode("ascii"), object_pairs_hook=_pairs)
            self.outbox.attempt(head["notice_id"], digest, now)
            receipt = self.deliver(body, self.config.http_timeout_seconds)
            if (
                type(receipt) is not dict or receipt.get("accepted") is not True
                or type(receipt.get("duplicate")) is not bool
                or type(receipt.get("status")) is not dict
                or receipt["status"].get("lastSequence") != body["sequence"]
                or type(receipt["status"].get("policy")) is not dict
                or receipt["status"]["policy"].get("sourceId") != self.config.source_id
                or receipt["status"]["policy"].get("revision") != self.config.source_revision
            ):
                raise NutBridgeError("invalid_core_response")
            self.outbox.delivered(
                head["notice_id"], digest, body["sequence"],
            )
            return "delivered"
        except NutBridgeError as error:
            if error.retryable:
                return "retry"
            self.outbox.block(head["notice_id"], error.code)
            return "blocked"
        except Exception:
            self.outbox.block(head["notice_id"], "bridge_unavailable")
            return "blocked"


class FixedUpsc:
    def __init__(self, config):
        self.config = config

    def __call__(self, peer, timeout):
        if peer != self.config.ups_name or timeout != self.config.upsc_timeout_seconds:
            raise NutBridgeError("upsc_unavailable", retryable=True)
        descriptor = -1
        try:
            descriptor = os.open(self.config.upsc, os.O_RDONLY | os.O_NOFOLLOW)
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_uid not in {0, os.geteuid()}
                or info.st_mode & 0o022 or not info.st_mode & 0o111
            ):
                raise ValueError()
            digest = hashlib.sha256()
            while True:
                part = os.read(descriptor, 1024 * 1024)
                if not part:
                    break
                digest.update(part)
            if not __import__("hmac").compare_digest(digest.hexdigest(), self.config.upsc_sha256):
                raise ValueError()
            os.lseek(descriptor, 0, os.SEEK_SET)
            result = subprocess.run(
                [f"/proc/self/fd/{descriptor}", peer], pass_fds=(descriptor,),
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=timeout, check=False,
                env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
            )
            if result.returncode != 0 or len(result.stdout) > _MAX_UPSC:
                raise ValueError()
            return result.stdout
        except Exception:
            raise NutBridgeError("upsc_unavailable", retryable=True) from None
        finally:
            if descriptor >= 0:
                os.close(descriptor)


class CoreHttpsDelivery:
    def __init__(self, config):
        self.config = config

    def __call__(self, body, timeout):
        connection = None
        try:
            ca_raw, _ = _safe_file(self.config.ca_file, maximum=1024 * 1024)
            if not __import__("hmac").compare_digest(
                hashlib.sha256(ca_raw).hexdigest(), self.config.ca_sha256
            ):
                raise NutBridgeError("invalid_configuration")
            context = ssl.create_default_context(cadata=ca_raw.decode("ascii"))
            connection = http.client.HTTPSConnection(
                self.config.core_host, self.config.core_port,
                timeout=timeout, context=context,
            )
            raw = _canonical(body)
            connection.request(
                "POST", "/api/v1/admin/power-recovery/events", body=raw,
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Content-Length": str(len(raw)),
                    "X-Larenor-Ups-Token": self.config.source_token,
                },
            )
            response = connection.getresponse()
            payload = response.read(_MAX_RESPONSE + 1)
            if len(payload) > _MAX_RESPONSE:
                raise NutBridgeError("invalid_core_response")
            if response.status in {401, 403}:
                raise NutBridgeError("authentication_failed")
            if response.status == 409:
                raise NutBridgeError("delivery_conflict")
            if response.status != 200:
                raise NutBridgeError("delivery_unavailable", retryable=True)
            if response.getheader("Content-Type", "").split(";", 1)[0].strip() != "application/json":
                raise NutBridgeError("invalid_core_response")
            return json.loads(
                payload.decode("utf-8"), object_pairs_hook=_pairs,
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
            )
        except NutBridgeError:
            raise
        except Exception:
            raise NutBridgeError("delivery_unavailable", retryable=True) from None
        finally:
            if connection is not None:
                connection.close()


def validate_upsmon_wiring(config, path):
    if type(config) is not NutBridgeConfig:
        raise NutBridgeError("invalid_configuration")
    try:
        raw, _info = _safe_file(path, maximum=256 * 1024)
        directives = []
        for line in raw.decode("utf-8").splitlines():
            tokens = shlex.split(line, comments=True, posix=True)
            if tokens:
                directives.append(tokens)
        commands = [row for row in directives if row[0].upper() == "NOTIFYCMD"]
        monitors = [row for row in directives if row[0].upper() == "MONITOR"]
        flags = {}
        for row in directives:
            if row[0].upper() != "NOTIFYFLAG":
                continue
            if len(row) != 3 or row[1].upper() in flags:
                raise ValueError()
            flags[row[1].upper()] = set(row[2].upper().split("+"))
        if (
            commands != [["NOTIFYCMD", "/usr/libexec/larenor-nut-notify"]]
            or not any(len(row) >= 2 and row[1] == config.ups_name for row in monitors)
            or any(kind not in flags or "EXEC" not in flags[kind] for kind in _NOTIFY)
        ):
            raise ValueError()
    except Exception:
        raise NutBridgeError("invalid_configuration") from None


class NutBridgeRuntime:
    def __init__(self, config, outbox, *, notify_socket=_NOTIFY_SOCKET, peer_uid=None):
        self.config, self.outbox = config, outbox
        self.worker = NutBridgeWorker(
            config, outbox, upsc=FixedUpsc(config),
            deliver=CoreHttpsDelivery(config),
        )
        key = hashlib.sha256(
            f"{config.source_id}:{config.source_revision}".encode("ascii")
        ).hexdigest()[:24]
        self.lock_path = config.state_root / f"nut-worker-{key}.lock"
        self.notify_socket = Path(notify_socket)
        self.peer_uid = peer_uid
        self._listener = self._notify_thread = None
        try:
            descriptor = os.open(
                self.lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600,
            )
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise OSError()
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self._lock = descriptor
        except Exception:
            try:
                os.close(descriptor)
            except Exception:
                pass
            raise NutBridgeError() from None

    @staticmethod
    def _system_peer(connection):
        if not hasattr(socket, "SO_PEERCRED"):
            raise OSError()
        _pid, uid, _gid = struct.unpack(
            "3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        )
        return uid

    def _bind_notify(self):
        try:
            expected_uid = (
                pwd.getpwnam(self.config.notify_user).pw_uid
                if self.peer_uid is None else self.peer_uid(None)
            )
            if type(expected_uid) is not int or expected_uid < 0:
                raise ValueError()
            parent = os.stat(self.notify_socket.parent, follow_symlinks=False)
            if (
                not self.notify_socket.is_absolute()
                or ".." in self.notify_socket.parts
                or not stat.S_ISDIR(parent.st_mode)
                or parent.st_uid != os.geteuid()
                or parent.st_gid != os.getegid()
                or stat.S_IMODE(parent.st_mode) != 0o770
            ):
                raise ValueError()
            if os.path.lexists(self.notify_socket):
                current = os.stat(self.notify_socket, follow_symlinks=False)
                if (
                    not stat.S_ISSOCK(current.st_mode)
                    or current.st_uid != os.geteuid()
                    or stat.S_IMODE(current.st_mode) != 0o660
                ):
                    raise ValueError()
                self.notify_socket.unlink()
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(self.notify_socket))
            os.chmod(self.notify_socket, 0o660)
            listener.listen(8)
            listener.settimeout(0.2)
            self._listener = listener
            return expected_uid
        except Exception:
            try:
                listener.close()
            except Exception:
                pass
            raise NutBridgeError() from None

    @staticmethod
    def _receive(connection):
        connection.settimeout(3)
        header = connection.recv(4)
        if len(header) != 4:
            raise ValueError()
        length = struct.unpack("!I", header)[0]
        if not 1 <= length <= _MAX_NOTIFY_FRAME:
            raise ValueError()
        raw = bytearray()
        while len(raw) < length:
            part = connection.recv(length - len(raw))
            if not part:
                raise ValueError()
            raw.extend(part)
        value = json.loads(
            bytes(raw).decode("ascii"), object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        if (
            type(value) is not dict
            or set(value) != {"protocolVersion", "upsName", "notifyType"}
            or value["protocolVersion"] != 1
        ):
            raise ValueError()
        return {"UPSNAME": value["upsName"], "NOTIFYTYPE": value["notifyType"]}

    @staticmethod
    def _receive_response(connection):
        header = connection.recv(4)
        if len(header) != 4:
            raise ValueError()
        length = struct.unpack("!I", header)[0]
        if not 1 <= length <= _MAX_NOTIFY_FRAME:
            raise ValueError()
        raw = bytearray()
        while len(raw) < length:
            part = connection.recv(length - len(raw))
            if not part:
                raise ValueError()
            raw.extend(part)
        return json.loads(
            bytes(raw).decode("ascii"), object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )

    def _notify_loop(self, stopped, expected_uid):
        peer = self.peer_uid or self._system_peer
        while not stopped.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                try:
                    if peer(connection) != expected_uid:
                        raise ValueError()
                    notice_id = self.outbox.enqueue(self._receive(connection))
                    response = _canonical({"accepted": True, "noticeId": notice_id})
                except Exception:
                    response = _canonical({"accepted": False})
                try:
                    connection.sendall(struct.pack("!I", len(response)) + response)
                except OSError:
                    pass

    def close(self):
        listener, self._listener = self._listener, None
        if listener is not None:
            listener.close()
        thread, self._notify_thread = self._notify_thread, None
        if thread is not None:
            thread.join(timeout=2)
        try:
            current = os.stat(self.notify_socket, follow_symlinks=False)
            if stat.S_ISSOCK(current.st_mode) and current.st_uid == os.geteuid():
                self.notify_socket.unlink()
        except OSError:
            pass
        descriptor, self._lock = getattr(self, "_lock", -1), -1
        if descriptor >= 0:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

    def serve(self, stopped):
        expected_uid = self._bind_notify()
        self._notify_thread = threading.Thread(
            target=self._notify_loop, args=(stopped, expected_uid),
            name="larenor-nut-notify", daemon=True,
        )
        self._notify_thread.start()
        while not stopped.is_set():
            result = self.worker.run_once()
            delay = self.config.retry_seconds if result in {"idle", "retry"} else 0
            if result == "blocked":
                delay = max(30, self.config.retry_seconds)
            stopped.wait(delay)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


def send_notification(
    path, environ, *, expected_uid=_NOTIFY_WORKER_UID,
    expected_gid=_NOTIFY_WORKER_GID, timeout=3, peer_uid=None,
):
    try:
        selected = Path(path)
        if (
            not selected.is_absolute() or ".." in selected.parts
            or type(expected_uid) is not int or expected_uid < 1
            or type(expected_gid) is not int or expected_gid < 1
            or type(timeout) not in (int, float) or isinstance(timeout, bool)
            or not 0 < timeout <= 5
            or peer_uid is not None and not callable(peer_uid)
        ):
            raise ValueError()
        info = os.stat(selected, follow_symlinks=False)
        if (
            not stat.S_ISSOCK(info.st_mode) or info.st_uid != expected_uid
            or info.st_gid != expected_gid
            or stat.S_IMODE(info.st_mode) != 0o660
        ):
            raise ValueError()
        value = {
            "protocolVersion": 1,
            "upsName": environ.get("UPSNAME"),
            "notifyType": environ.get("NOTIFYTYPE"),
        }
        raw = _canonical(value)
        if len(raw) > _MAX_NOTIFY_FRAME:
            raise ValueError()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout)
            connection.connect(str(selected))
            if (peer_uid or NutBridgeRuntime._system_peer)(connection) != expected_uid:
                raise ValueError()
            connection.sendall(struct.pack("!I", len(raw)) + raw)
            response = NutBridgeRuntime._receive_response(connection)
        if (
            type(response) is not dict or set(response) != {"accepted", "noticeId"}
            or response["accepted"] is not True
            or type(response["noticeId"]) is not str
            or re.fullmatch(r"[0-9a-f]{32}", response["noticeId"]) is None
        ):
            raise ValueError()
        return response["noticeId"]
    except Exception:
        raise NutBridgeError("bridge_unavailable") from None

class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise NutBridgeError("invalid_configuration")


def main(argv=None):
    parser = _Parser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--upsmon-config", type=Path, default=Path("/etc/nut/upsmon.conf"))
    parser.add_argument("action", choices=("notify", "worker", "check-config", "status"))
    stopped = threading.Event()
    previous = {}
    try:
        args = parser.parse_args(argv)
        if args.action == "notify":
            send_notification(_NOTIFY_SOCKET, os.environ)
            return 0
        if args.config is None:
            raise NutBridgeError("invalid_configuration")
        config = NutBridgeConfig.load(args.config)
        outbox = NutBridgeOutbox(config)
        if args.action == "status":
            print(json.dumps(outbox.status(), sort_keys=True, separators=(",", ":")))
            return 0
        validate_upsmon_wiring(config, args.upsmon_config)
        ssl.create_default_context(cafile=str(config.ca_file))
        if args.action == "check-config":
            return 0
        for number in (signal.SIGTERM, signal.SIGINT):
            previous[number] = signal.signal(number, lambda *_args: stopped.set())
        with NutBridgeRuntime(config, outbox) as runtime:
            runtime.serve(stopped)
        return 0
    except NutBridgeError as error:
        print(error.code, file=__import__("sys").stderr)
        return 1
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
