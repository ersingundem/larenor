"""Worker-owned, durable action intents and receipts.

The effect caller holds ``locked()`` across observation and mutation. ``begin``
commits before an effect; any reopened nonterminal intent is reconciled rather
than submitted again. Digests detect damaged local state; they do not authorize
an effect or protect against the trusted worker OS identity itself.
"""

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3
import stat
import threading
from typing import Literal

from pydantic import Field, ValidationError, field_validator, model_validator

from ..models import StrictModel
from ..plugins.worker import DockerWorkerError, _safe_path
from .models import ArchiveActionWorkerReceipt, PrivateArchiveActionCommand, _digest


MAX_OPERATIONS = 1024
MAX_PAYLOAD_BYTES = 96 * 1024
MAX_DATABASE_BYTES = 256 * 1024 * 1024
MAX_REVISION = 2**63 - 2
STATES = {"prepared", "mutating", "running", "uncertain", "succeeded",
          "failed", "cancelled", "needs_attention"}
TERMINAL = {"succeeded", "failed", "cancelled"}
_TRANSITIONS = {
    "prepared": {"mutating", "cancelled", "failed"},
    "mutating": {"mutating", "running", "uncertain", "succeeded", "failed", "cancelled",
                 "needs_attention"},
    "running": {"running", "uncertain", "succeeded", "failed", "cancelled",
                "needs_attention"},
    "uncertain": {"running", "succeeded", "failed", "cancelled", "needs_attention"},
    "needs_attention": {"running", "succeeded", "failed", "cancelled", "needs_attention"},
    "succeeded": set(), "failed": set(), "cancelled": set(),
}
_SCHEMA = (
    "CREATE TABLE metadata(identity TEXT NOT NULL PRIMARY KEY,version INTEGER NOT NULL,"
    "count INTEGER NOT NULL,digest TEXT NOT NULL)",
    "CREATE TABLE operations(operation_id TEXT NOT NULL PRIMARY KEY,sequence INTEGER "
    "NOT NULL UNIQUE,command_digest TEXT NOT NULL UNIQUE,revision INTEGER NOT NULL,"
    "state TEXT NOT NULL,payload BLOB NOT NULL,digest TEXT NOT NULL)",
)


class ArchiveActionJournalError(RuntimeError):
    def __init__(self, code="action_journal_unavailable"):
        self.code = code
        super().__init__(code)


def _require(condition, code="action_journal_unavailable"):
    if not condition:
        raise ArchiveActionJournalError(code)


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False).encode("utf-8")


def _hash(value):
    return hashlib.sha256(_canonical(value)).hexdigest()


def action_command_digest(command):
    value = PrivateArchiveActionCommand.model_validate(command)
    _require(value.target.targetType != "legacy_unresolved", "evidence_changed")
    return _hash(value.model_dump(mode="json"))


class ArchiveActionEffectEvidence(StrictModel):
    """Private adapter observations, with opaque references and no credentials."""

    sourceDigest: str | None = None
    sourceBytes: int | None = Field(default=None, gt=0, le=2**63 - 1)
    retainedDigest: str | None = None
    retainedBytes: int | None = Field(default=None, gt=0, le=2**63 - 1)
    workDigest: str | None = None
    providerTaskId: int | None = Field(default=None, ge=1, le=2**63 - 1)
    providerTerminal: Literal["succeeded", "failed", "cancelled"] | None = None
    outputDigest: str | None = None
    outputBytes: int | None = Field(default=None, gt=0, le=2**63 - 1)
    outputCodec: Literal["hevc", "av1"] | None = None
    outputVerified: bool = False
    installIntent: bool = False
    outputInstalled: bool = False
    cleanupSourceProofDigest: str | None = None
    cleanupRetainedDevice: int | None = Field(
        default=None, ge=0, le=2**63 - 1)
    cleanupRetainedInode: int | None = Field(
        default=None, gt=0, le=2**63 - 1)
    cleanupRetainedDigest: str | None = None
    cleanupRetainedBytes: int | None = Field(
        default=None, gt=0, le=2**63 - 1)
    cleanupOutputDigest: str | None = None
    cleanupOutputBytes: int | None = Field(
        default=None, gt=0, le=2**63 - 1)
    cleanupDeleteIntent: bool = False
    cleanupVerified: bool = False
    cancelRequested: bool = False

    @field_validator(
        "sourceDigest", "retainedDigest", "workDigest", "outputDigest",
        "cleanupSourceProofDigest", "cleanupRetainedDigest",
        "cleanupOutputDigest",
    )
    @classmethod
    def digests(cls, value):
        return None if value is None else _digest(value)

    @model_validator(mode="after")
    def coherent(self):
        cleanup_values = (
            self.cleanupSourceProofDigest,
            self.cleanupRetainedDevice,
            self.cleanupRetainedInode,
            self.cleanupRetainedDigest,
            self.cleanupRetainedBytes,
            self.cleanupOutputDigest,
            self.cleanupOutputBytes,
        )
        if ((self.sourceDigest is None) != (self.sourceBytes is None)
                or (self.retainedDigest is None) != (self.retainedBytes is None)
                or (self.outputDigest is None) != (self.outputBytes is None)
                or self.retainedDigest is not None and (
                    self.retainedDigest != self.sourceDigest
                    or self.retainedBytes != self.sourceBytes)
                or self.workDigest is not None and self.retainedDigest is None
                or self.outputVerified and (self.outputDigest is None
                    or self.outputCodec is None or self.providerTerminal != "succeeded")
                or self.installIntent and not self.outputVerified
                or self.outputInstalled and not self.installIntent
                or any(value is not None for value in cleanup_values)
                != all(value is not None for value in cleanup_values)
                or self.cleanupDeleteIntent
                != all(value is not None for value in cleanup_values)):
            raise ValueError("invalid_media_archive_effect_evidence")
        return self


@dataclass(frozen=True, repr=False)
class ArchiveActionEffectRecord:
    sequence: int
    revision: int
    state: str
    command_digest: str
    command: PrivateArchiveActionCommand
    evidence: ArchiveActionEffectEvidence
    receipt: ArchiveActionWorkerReceipt | None

    def __repr__(self):
        return "ArchiveActionEffectRecord(<private>)"


def _validate_evidence(command, evidence, receipt, state):
    optimize = command.operation == "stage_transcode"
    retained_cleanup = command.operation == "cleanup_retained_original"
    if optimize:
        _require(evidence.sourceBytes in {None, command.target.sourceSizeBytes})
        _require(evidence.outputCodec in {None, command.target.targetCodec})
        _require(evidence.cleanupSourceProofDigest is None
                 and not evidence.cleanupDeleteIntent
                 and not evidence.cleanupVerified)
    else:
        _require(evidence.retainedDigest is None and evidence.workDigest is None
                 and evidence.providerTaskId is None and evidence.outputDigest is None
                 and not evidence.outputVerified and not evidence.installIntent
                 and not evidence.outputInstalled)
        if retained_cleanup:
            _require(evidence.sourceDigest is None
                     and evidence.cleanupVerified in {
                         False, evidence.cleanupDeleteIntent})
        else:
            _require(evidence.cleanupSourceProofDigest is None
                     and not evidence.cleanupDeleteIntent)
    if receipt is None:
        _require(state not in TERMINAL and state != "running")
        return
    _require(receipt.operationId == command.operationId
             and receipt.evidenceDigest == command.evidenceDigest
             and receipt.state == state)
    if state != "running":
        _require(receipt.retainedOriginal == (optimize and evidence.retainedDigest is not None))
    if state == "succeeded":
        _require(receipt.retainedOriginal == optimize)
        if optimize:
            _require(evidence.retainedDigest is not None and evidence.outputInstalled
                     and evidence.outputBytes < evidence.sourceBytes)
        else:
            _require(evidence.cleanupVerified)
        _require(receipt.proofDigest == _hash({
            "commandDigest": action_command_digest(command),
            "evidence": evidence.model_dump(mode="json"),
        }))
    if state == "cancelled":
        _require(evidence.cancelRequested and not evidence.outputInstalled)
        _require(evidence.providerTaskId is None or evidence.providerTerminal == "cancelled")


class MediaArchiveActionJournal:
    def __init__(self, directory):
        self.directory = Path(directory).absolute()
        self.database_path = self.directory / "media-archive-actions.sqlite"
        self.lock_path = self.directory / "media-archive-actions.lock"
        self._mutex = threading.Lock()
        self._owner = None
        self._closed = False
        self._db = None
        self._lock_fd = None
        try:
            _safe_path(self.directory, uid=os.getuid(), kind=stat.S_ISDIR, private=True)
            new_db = not os.path.lexists(self.database_path)
            new_lock = not os.path.lexists(self.lock_path)
            _require(new_db == new_lock)
            if new_db:
                for path in (self.database_path, self.lock_path):
                    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                                 | os.O_NOFOLLOW, 0o600)
                    os.close(fd)
            for path in (self.database_path, self.lock_path):
                _safe_path(path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
            self._lock_fd = os.open(self.lock_path, os.O_RDWR | os.O_NOFOLLOW)
            self._file_identity = self.database_path.stat().st_dev, self.database_path.stat().st_ino
            self._db = sqlite3.connect(self.database_path, isolation_level=None,
                                       timeout=2, check_same_thread=False)
            self._db.row_factory = sqlite3.Row
            self._db.execute("PRAGMA journal_mode=DELETE")
            self._db.execute("PRAGMA synchronous=FULL")
            with self.locked():
                if new_db:
                    self._db.execute("BEGIN IMMEDIATE")
                    for statement in _SCHEMA:
                        self._db.execute(statement)
                    identity = secrets.token_hex(32)
                    self._db.execute("INSERT INTO metadata VALUES(?,?,?,?)",
                                     (identity, 1, 0, _hash({"identity": identity, "rows": []})))
                    self._db.execute("COMMIT")
                    fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
                    try:
                        os.fsync(fd)
                    finally:
                        os.close(fd)
                self._validate_schema()
        except Exception:
            self.close()
            raise ArchiveActionJournalError() from None

    def _paths(self):
        _safe_path(self.directory, uid=os.getuid(), kind=stat.S_ISDIR, private=True)
        for path in (self.database_path, self.lock_path):
            _safe_path(path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
        current = self.database_path.stat()
        _require((current.st_dev, current.st_ino) == self._file_identity
                 and current.st_size <= MAX_DATABASE_BYTES)
        lock = self.lock_path.stat()
        opened = os.fstat(self._lock_fd)
        _require((lock.st_dev, lock.st_ino) == (opened.st_dev, opened.st_ino))

    @contextmanager
    def locked(self):
        _require(not self._closed and self._mutex.acquire(blocking=False), "action_journal_busy")
        acquired = False
        try:
            try:
                self._paths()
                fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
            except (OSError, DockerWorkerError):
                raise ArchiveActionJournalError() from None
            self._owner = threading.get_ident()
            self._validate_rows()
            yield
        finally:
            self._owner = None
            if acquired:
                fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            self._mutex.release()

    def _locked(self):
        _require(not self._closed and self._owner == threading.get_ident())
        self._paths()

    def close(self):
        if self._closed:
            return
        self._closed = True
        if self._db is not None:
            self._db.close()
        if self._lock_fd is not None:
            os.close(self._lock_fd)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()

    def _validate_schema(self):
        _require(self._db.execute("PRAGMA integrity_check").fetchone()[0] == "ok")
        rows = self._db.execute("SELECT sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' "
                                "ORDER BY name").fetchall()
        _require([" ".join(row[0].split()) for row in rows]
                 == [" ".join(statement.split()) for statement in _SCHEMA])
        self._validate_rows()

    @staticmethod
    def _row_digest(row):
        return _hash({key: (json.loads(row[key]) if key == "payload" else row[key])
                      for key in ("operation_id", "sequence", "command_digest",
                                  "revision", "state", "payload")})

    def _decode(self, row):
        try:
            _require(type(row["sequence"]) is int and 1 <= row["sequence"] <= MAX_OPERATIONS
                     and type(row["revision"]) is int and 1 <= row["revision"] <= MAX_REVISION
                     and row["state"] in STATES and type(row["payload"]) is bytes
                     and len(row["payload"]) <= MAX_PAYLOAD_BYTES
                     and row["digest"] == self._row_digest(row))
            value = json.loads(row["payload"])
            _require(type(value) is dict and set(value) == {"command", "evidence", "receipt"}
                     and _canonical(value) == row["payload"])
            command = PrivateArchiveActionCommand.model_validate(value["command"])
            evidence = ArchiveActionEffectEvidence.model_validate(value["evidence"])
            receipt = (None if value["receipt"] is None
                       else ArchiveActionWorkerReceipt.model_validate(value["receipt"]))
            _require(command.operationId == row["operation_id"]
                     and action_command_digest(command) == row["command_digest"])
            _validate_evidence(command, evidence, receipt, row["state"])
            return ArchiveActionEffectRecord(row["sequence"], row["revision"], row["state"],
                                            row["command_digest"], command, evidence, receipt)
        except (ValueError, KeyError, TypeError, ValidationError):
            raise ArchiveActionJournalError() from None

    def _validate_rows(self):
        try:
            # A brand new database is initialized by the lease holder.
            if not self._db.execute("SELECT 1 FROM sqlite_master WHERE name='metadata'").fetchone():
                _require(self.database_path.stat().st_size == 0)
                return
            rows = self._db.execute("SELECT * FROM operations ORDER BY sequence LIMIT ?",
                                    (MAX_OPERATIONS + 1,)).fetchall()
            _require(len(rows) <= MAX_OPERATIONS)
            for index, row in enumerate(rows, 1):
                self._decode(row)
                _require(row["sequence"] == index)
            metadata = self._db.execute("SELECT * FROM metadata").fetchall()
            _require(len(metadata) == 1)
            marker = metadata[0]
            _digest(marker["identity"])
            _require(marker["version"] == 1 and marker["count"] == len(rows)
                     and marker["digest"] == _hash({"identity": marker["identity"],
                                                    "rows": [row["digest"] for row in rows]}))
        except (sqlite3.Error, OSError, ValueError, KeyError, TypeError):
            raise ArchiveActionJournalError() from None

    def _update_metadata(self):
        rows = self._db.execute("SELECT digest FROM operations ORDER BY sequence").fetchall()
        identity = self._db.execute("SELECT identity FROM metadata").fetchone()[0]
        self._db.execute("UPDATE metadata SET count=?,digest=?",
                         (len(rows), _hash({"identity": identity, "rows": [row[0] for row in rows]})))

    @contextmanager
    def _transaction(self):
        self._locked()
        try:
            self._db.execute("BEGIN IMMEDIATE")
            yield
            self._update_metadata()
            self._db.execute("COMMIT")
        except Exception:
            if self._db.in_transaction:
                self._db.execute("ROLLBACK")
            raise

    def get(self, operation_id):
        self._locked()
        try:
            row = self._db.execute("SELECT * FROM operations WHERE operation_id=?",
                                   (operation_id,)).fetchone()
            return None if row is None else self._decode(row)
        except sqlite3.Error:
            raise ArchiveActionJournalError() from None

    def prepare(self, command):
        self._locked()
        command = PrivateArchiveActionCommand.model_validate(command)
        digest = action_command_digest(command)
        existing = self.get(command.operationId)
        if existing is not None:
            _require(existing.command_digest == digest, "idempotency_conflict")
            return existing
        count = self._db.execute("SELECT count(*) FROM operations").fetchone()[0]
        _require(count < MAX_OPERATIONS, "action_journal_capacity")
        payload = _canonical({"command": command.model_dump(mode="json"),
                              "evidence": ArchiveActionEffectEvidence().model_dump(mode="json"),
                              "receipt": None})
        _require(len(payload) <= MAX_PAYLOAD_BYTES)
        row = dict(operation_id=command.operationId, sequence=count + 1,
                   command_digest=digest, revision=1, state="prepared", payload=payload)
        row["digest"] = self._row_digest(row)
        try:
            with self._transaction():
                self._db.execute("INSERT INTO operations VALUES(?,?,?,?,?,?,?)", tuple(row.values()))
        except sqlite3.Error:
            raise ArchiveActionJournalError() from None
        return self.get(command.operationId)

    def transition(self, record, state, *, evidence=None, receipt=None):
        self._locked()
        _require(type(record) is ArchiveActionEffectRecord and state in STATES)
        current = self.get(record.command.operationId)
        _require(current is not None and current.revision == record.revision
                 and current.state == record.state and current.command_digest == record.command_digest,
                 "action_journal_changed")
        _require(state in _TRANSITIONS[current.state], "invalid_action_transition")
        _require(current.revision < MAX_REVISION)
        evidence = ArchiveActionEffectEvidence.model_validate(evidence or current.evidence)
        # Confirmed artifacts and an install intent cannot disappear on retry.
        previous = current.evidence.model_dump(mode="python")
        next_value = evidence.model_dump(mode="python")
        for key, value in previous.items():
            if value is not None and value is not False:
                _require(next_value[key] == value, "evidence_changed")
        if receipt is not None:
            receipt = ArchiveActionWorkerReceipt.model_validate(receipt)
        _validate_evidence(current.command, evidence, receipt, state)
        payload = _canonical({"command": current.command.model_dump(mode="json"),
                              "evidence": evidence.model_dump(mode="json"),
                              "receipt": None if receipt is None else receipt.model_dump(mode="json")})
        _require(len(payload) <= MAX_PAYLOAD_BYTES)
        row = dict(operation_id=current.command.operationId, sequence=current.sequence,
                   command_digest=current.command_digest, revision=current.revision + 1,
                   state=state, payload=payload)
        row["digest"] = self._row_digest(row)
        try:
            with self._transaction():
                changed = self._db.execute(
                    "UPDATE operations SET revision=?,state=?,payload=?,digest=? "
                    "WHERE operation_id=? AND revision=? AND state=? AND command_digest=?",
                    (row["revision"], state, payload, row["digest"], current.command.operationId,
                     current.revision, current.state, current.command_digest))
                _require(changed.rowcount == 1, "action_journal_changed")
        except sqlite3.Error:
            raise ArchiveActionJournalError() from None
        return self.get(current.command.operationId)

    def begin(self, record):
        _require(record.state == "prepared", "invalid_action_transition")
        return self.transition(record, "mutating")

    def records(self):
        self._locked()
        return tuple(self._decode(row) for row in self._db.execute(
            "SELECT * FROM operations ORDER BY sequence").fetchall())

    @staticmethod
    def proof_digest(command, evidence):
        return _hash({"commandDigest": action_command_digest(command),
                      "evidence": ArchiveActionEffectEvidence.model_validate(evidence).model_dump(mode="json")})
