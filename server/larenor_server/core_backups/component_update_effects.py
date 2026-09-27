"""Private durable journal for one-way component container replacements."""

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import threading

from ..plugins.component_updates import (
    ComponentUpdateCommand,
    verify_update_command,
)
from ..plugins.managed_container import (
    ManagedContainerBinding,
    ManagedContainerMount,
    _binding_parts,
)
from ..plugins.worker import DockerWorkerError, _canonical, _decode, _safe_path


_SCHEMA = """CREATE TABLE component_update_effects (
    update_id TEXT PRIMARY KEY CHECK(length(update_id)=32),
    sequence INTEGER NOT NULL UNIQUE CHECK(sequence>0),
    installation_id TEXT NOT NULL CHECK(length(installation_id)=32),
    service_id TEXT NOT NULL,
    command_digest TEXT NOT NULL UNIQUE CHECK(length(command_digest)=64),
    source_digest TEXT NOT NULL CHECK(length(source_digest)=64),
    target_manifest_digest TEXT NOT NULL CHECK(length(target_manifest_digest)=64),
    state TEXT NOT NULL CHECK(state IN ('prepared','mutating','committed',
        'rolled_back','needs_attention')),
    old_container_id TEXT NOT NULL CHECK(length(old_container_id)=64),
    new_container_id TEXT CHECK(new_container_id IS NULL OR length(new_container_id)=64),
    payload BLOB NOT NULL,
    digest TEXT NOT NULL CHECK(length(digest)=64))"""
_INDEX = """CREATE INDEX component_update_effects_installation
    ON component_update_effects(installation_id,sequence)"""
_STATES = {"prepared", "mutating", "committed", "rolled_back", "needs_attention"}


class ComponentUpdateEffectJournalError(RuntimeError):
    def __init__(self):
        super().__init__("component_update_effect_journal_unavailable")


def _fail():
    raise ComponentUpdateEffectJournalError()


@dataclass(frozen=True, repr=False)
class ComponentUpdateEffectRecord:
    sequence: int
    command: ComponentUpdateCommand
    state: str
    old_container_id: str
    new_container_id: str | None
    binding: ManagedContainerBinding
    source: tuple

    def __repr__(self):
        return "ComponentUpdateEffectRecord(<private>)"


def _binding(payload):
    try:
        value = payload["binding"]
        if type(value) is not dict or set(value) != {
            "name",
            "platform",
            "image_id",
            "network_id",
            "mounts",
            "specification",
            "image_configuration",
        }:
            _fail()
        mounts = value["mounts"]
        if type(mounts) is not list:
            _fail()
        result = ManagedContainerBinding(
            value["name"],
            value["platform"],
            value["image_id"],
            value["network_id"],
            tuple(ManagedContainerMount(**item) for item in mounts),
            _canonical(value["specification"]),
            _canonical(value["image_configuration"]),
        )
        _binding_parts(result)
        return result
    except ComponentUpdateEffectJournalError:
        raise
    except (KeyError, TypeError, ValueError, AttributeError, DockerWorkerError):
        _fail()


class ComponentUpdateEffectJournal:
    """Root-owned effect receipt separate from install create/start rows."""

    def __init__(self, directory):
        self.directory = Path(directory).absolute()
        self._thread_lock = threading.Lock()
        self._owner = None
        self._closed = False
        database = self.directory / "component-updates.sqlite"
        lock = self.directory / "component-updates.lock"
        try:
            _safe_path(
                self.directory,
                uid=os.getuid(),
                kind=stat.S_ISDIR,
                private=True,
            )
            created_database = not database.exists() and not database.is_symlink()
            created_lock = not lock.exists() and not lock.is_symlink()
            if created_database != created_lock:
                _fail()
            if created_database:
                for path in (database, lock):
                    descriptor = os.open(
                        path,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                        0o600,
                    )
                    os.close(descriptor)
            _safe_path(database, uid=os.getuid(), kind=stat.S_ISREG, private=True)
            _safe_path(lock, uid=os.getuid(), kind=stat.S_ISREG, private=True)
            self._lock_file = os.open(lock, os.O_RDWR | os.O_NOFOLLOW)
            self._database = sqlite3.connect(
                database,
                timeout=2,
                isolation_level=None,
                check_same_thread=False,
            )
            self._database.row_factory = sqlite3.Row
            self._database.execute("PRAGMA journal_mode=DELETE")
            self._database.execute("PRAGMA synchronous=FULL")
            with self.locked():
                if created_database:
                    self._database.execute("BEGIN IMMEDIATE")
                    self._database.execute(
                        "CREATE TABLE metadata (schema_version INTEGER NOT NULL)"
                    )
                    self._database.execute("INSERT INTO metadata VALUES(1)")
                    self._database.execute(_SCHEMA)
                    self._database.execute(_INDEX)
                    self._database.execute("COMMIT")
                    descriptor = os.open(self.directory, os.O_RDONLY)
                    try:
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                self._validate_schema()
        except ComponentUpdateEffectJournalError:
            self.close()
            raise
        except (OSError, sqlite3.Error, ValueError, TypeError, DockerWorkerError):
            self.close()
            _fail()

    def _validate_schema(self):
        try:
            if self._database.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                _fail()
            marker = self._database.execute(
                "SELECT schema_version FROM metadata"
            ).fetchall()
            if len(marker) != 1 or marker[0]["schema_version"] != 1:
                _fail()
            rows = self._database.execute(
                "SELECT name,type,sql FROM sqlite_master WHERE name IN "
                "('component_update_effects','component_update_effects_installation')"
            ).fetchall()
            actual = {row["name"]: row for row in rows}
            if (
                set(actual)
                != {"component_update_effects", "component_update_effects_installation"}
                or " ".join(actual["component_update_effects"]["sql"].split())
                != " ".join(_SCHEMA.split())
                or " ".join(
                    actual["component_update_effects_installation"]["sql"].split()
                )
                != " ".join(_INDEX.split())
            ):
                _fail()
            for row in self._database.execute(
                "SELECT * FROM component_update_effects ORDER BY sequence LIMIT 1025"
            ).fetchall():
                self._decode(row)
        except ComponentUpdateEffectJournalError:
            raise
        except (sqlite3.Error, TypeError, ValueError, KeyError):
            _fail()

    @contextmanager
    def locked(self):
        if self._closed or not self._thread_lock.acquire(blocking=False):
            _fail()
        acquired = False
        try:
            try:
                fcntl.flock(self._lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
            except OSError:
                _fail()
            self._owner = threading.get_ident()
            yield
        finally:
            self._owner = None
            if acquired:
                fcntl.flock(self._lock_file, fcntl.LOCK_UN)
            self._thread_lock.release()

    def _locked(self):
        if self._closed or self._owner != threading.get_ident():
            _fail()

    def close(self):
        if getattr(self, "_closed", True):
            return
        self._closed = True
        if hasattr(self, "_database"):
            self._database.close()
        if hasattr(self, "_lock_file"):
            os.close(self._lock_file)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()

    @staticmethod
    def _row_digest(row):
        data = [
            row[key]
            for key in (
                "update_id",
                "sequence",
                "installation_id",
                "service_id",
                "command_digest",
                "source_digest",
                "target_manifest_digest",
                "state",
                "old_container_id",
                "new_container_id",
            )
        ]
        return hashlib.sha256(
            _canonical({"row": data, "payload": _decode(row["payload"], 524288)})
        ).hexdigest()

    def _decode(self, row):
        try:
            if (
                type(row["sequence"]) is not int
                or not 1 <= row["sequence"] <= 1024
                or row["state"] not in _STATES
                or type(row["payload"]) is not bytes
                or len(row["payload"]) > 524288
                or row["digest"] != self._row_digest(row)
            ):
                _fail()
            payload = _decode(row["payload"], 524288)
            if type(payload) is not dict or set(payload) != {
                "command",
                "binding",
                "source",
            }:
                _fail()
            command = verify_update_command(
                ComponentUpdateCommand.model_validate(payload["command"])
            )
            if (
                command.updateId != row["update_id"]
                or command.installationId != row["installation_id"]
                or command.serviceId != row["service_id"]
                or command.commandDigest != row["command_digest"]
                or command.sourceDigest != row["source_digest"]
                or command.targetManifestDigest != row["target_manifest_digest"]
            ):
                _fail()
            source = payload["source"]
            if type(source) is not list or len(source) != 3:
                _fail()
            return ComponentUpdateEffectRecord(
                row["sequence"],
                command,
                row["state"],
                row["old_container_id"],
                row["new_container_id"],
                _binding(payload),
                tuple(source),
            )
        except ComponentUpdateEffectJournalError:
            raise
        except (ValueError, TypeError, AttributeError, KeyError, DockerWorkerError):
            _fail()

    def get(self, update_id):
        self._locked()
        row = self._database.execute(
            "SELECT * FROM component_update_effects WHERE update_id=?", (update_id,)
        ).fetchone()
        return None if row is None else self._decode(row)

    def prepare(self, command, old_container_id, binding, source):
        self._locked()
        try:
            command = verify_update_command(command)
            _binding_parts(binding)
            if (
                type(old_container_id) is not str
                or len(old_container_id) != 64
                or type(source) is not tuple
                or len(source) != 3
            ):
                _fail()
            payload = _canonical(
                {
                    "command": command.model_dump(mode="json"),
                    "binding": binding.payload(),
                    "source": list(source),
                }
            )
            existing = self.get(command.updateId)
            if existing is not None:
                if (
                    existing.command != command
                    or existing.old_container_id != old_container_id
                    or existing.binding != binding
                    or existing.source != source
                ):
                    _fail()
                return existing
            count = self._database.execute(
                "SELECT count(*) FROM component_update_effects"
            ).fetchone()[0]
            if count >= 1024:
                _fail()
            sequence = self._database.execute(
                "SELECT COALESCE(MAX(sequence),0)+1 FROM component_update_effects"
            ).fetchone()[0]
            row = {
                "update_id": command.updateId,
                "sequence": sequence,
                "installation_id": command.installationId,
                "service_id": command.serviceId,
                "command_digest": command.commandDigest,
                "source_digest": command.sourceDigest,
                "target_manifest_digest": command.targetManifestDigest,
                "state": "prepared",
                "old_container_id": old_container_id,
                "new_container_id": None,
                "payload": payload,
            }
            row["digest"] = self._row_digest(row)
            self._database.execute("BEGIN IMMEDIATE")
            self._database.execute(
                "INSERT INTO component_update_effects VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
            self._database.execute("COMMIT")
            return self.get(command.updateId)
        except ComponentUpdateEffectJournalError:
            if self._database.in_transaction:
                self._database.execute("ROLLBACK")
            raise
        except (sqlite3.Error, TypeError, ValueError, DockerWorkerError):
            if self._database.in_transaction:
                self._database.execute("ROLLBACK")
            _fail()

    def transition(self, update_id, expected, state, *, new_container_id=None):
        self._locked()
        try:
            if expected not in _STATES or state not in _STATES:
                _fail()
            row = self._database.execute(
                "SELECT * FROM component_update_effects WHERE update_id=?", (update_id,)
            ).fetchone()
            if row is None or row["state"] != expected:
                _fail()
            changed = dict(row)
            changed["state"] = state
            if new_container_id is not None:
                if type(new_container_id) is not str or len(new_container_id) != 64:
                    _fail()
                changed["new_container_id"] = new_container_id
            changed["digest"] = self._row_digest(changed)
            self._database.execute("BEGIN IMMEDIATE")
            self._database.execute(
                "UPDATE component_update_effects SET state=?,new_container_id=?,digest=? "
                "WHERE update_id=?",
                (
                    changed["state"],
                    changed["new_container_id"],
                    changed["digest"],
                    update_id,
                ),
            )
            self._database.execute("COMMIT")
            return self.get(update_id)
        except ComponentUpdateEffectJournalError:
            if self._database.in_transaction:
                self._database.execute("ROLLBACK")
            raise
        except (sqlite3.Error, TypeError, ValueError):
            if self._database.in_transaction:
                self._database.execute("ROLLBACK")
            _fail()

    def committed(self):
        self._locked()
        rows = self._database.execute(
            "SELECT * FROM component_update_effects WHERE state='committed' "
            "ORDER BY sequence"
        ).fetchall()
        return tuple(self._decode(row) for row in rows)
