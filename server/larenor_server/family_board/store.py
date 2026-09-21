from contextlib import contextmanager
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import sqlite3
from typing import Callable

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from .models import (
    BOARD_ELEMENT_ADAPTER,
    BoardAuditEvent,
    BoardAuthority,
    BoardCommand,
    BoardDelta,
    BoardReceipt,
    BoardSnapshot,
    PublicBoardSnapshot,
    StoredBoard,
    StoredReceipt,
)


MAX_ELEMENTS = 512
MAX_RECEIPTS = 1024
MAX_EVENTS = 10000
ZERO_HASH = "0" * 64

BOARDS = """CREATE TABLE family_boards (
 board_id TEXT PRIMARY KEY, core_id TEXT NOT NULL, home_id TEXT NOT NULL,
 home_revision INTEGER NOT NULL, board_revision INTEGER NOT NULL,
 event_count INTEGER NOT NULL, audit_head TEXT NOT NULL,
 nonce BLOB NOT NULL, ciphertext BLOB NOT NULL, authentication_tag TEXT NOT NULL)"""
EVENTS = """CREATE TABLE family_board_events (
 board_id TEXT NOT NULL, sequence INTEGER NOT NULL, nonce BLOB NOT NULL,
 ciphertext BLOB NOT NULL, previous_hash TEXT NOT NULL, event_hash TEXT NOT NULL,
 PRIMARY KEY(board_id,sequence), FOREIGN KEY(board_id) REFERENCES family_boards(board_id))"""
METADATA = "CREATE TABLE family_board_metadata (version INTEGER NOT NULL)"


class FamilyBoardStore:
    """Encrypted, bounded F39 reducer. The caller owns authentication and supplies live authority."""

    def __init__(
        self,
        path: Path,
        key: bytes,
        authority_resolver: Callable[[str], BoardAuthority | None],
        *,
        clock: Callable[[], float] | None = None,
    ):
        if not isinstance(key, bytes) or len(key) != 32:
            raise ValueError("invalid_key")
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._key = key
        self._cipher = AESGCM(key)
        self._resolve = authority_resolver
        self._clock = clock or __import__("time").time
        try:
            self._migrate()
            os.chmod(self.path, 0o600)
            self.validate_storage()
        except StartupError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError, OSError):
            raise StartupError("family_board_storage_invalid") from None

    @contextmanager
    def _connection(self):
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        try:
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _migrate(self):
        with self._connection() as connection:
            connection.execute("CREATE TABLE IF NOT EXISTS family_board_metadata (version INTEGER NOT NULL)")
            version = connection.execute("SELECT version FROM family_board_metadata").fetchall()
            if not version:
                connection.execute(BOARDS)
                connection.execute(EVENTS)
                connection.execute("INSERT INTO family_board_metadata VALUES(1)")
            elif len(version) != 1 or version[0]["version"] != 1:
                raise ValueError("invalid_schema")
            self._validate_schema(connection)

    @staticmethod
    def _validate_schema(connection):
        def normalized(value):
            return " ".join(value.split())

        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'family_board*' OR tbl_name GLOB 'family_board*'"
        ).fetchall()
        tables = {row["name"]: row for row in rows if row["type"] == "table"}
        expected = {
            "family_board_metadata": METADATA,
            "family_boards": BOARDS,
            "family_board_events": EVENTS,
        }
        for name, sql in expected.items():
            row = tables.pop(name, None)
            if row is None or normalized(row["sql"]) != normalized(sql):
                raise ValueError("invalid_schema")
        if tables:
            raise ValueError("invalid_schema")
        allowed_indexes = {
            "sqlite_autoindex_family_boards_1",
            "sqlite_autoindex_family_board_events_1",
        }
        indexes = {row["name"] for row in rows if row["type"] == "index"}
        if indexes != allowed_indexes:
            raise ValueError("invalid_schema")

    @staticmethod
    def _canonical(value):
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                          allow_nan=False).encode("utf-8")

    def _state_aad(self, row):
        return (
            f"larenor-family-board-state-v1:{row['core_id']}:{row['home_id']}:"
            f"{row['board_id']}:{row['home_revision']}:{row['board_revision']}"
        ).encode("ascii")

    def _event_aad(self, row, sequence, previous_hash):
        return (
            f"larenor-family-board-event-v1:{row['core_id']}:{row['home_id']}:"
            f"{row['board_id']}:{sequence}:{previous_hash}"
        ).encode("ascii")

    def _state_tag(self, row):
        payload = self._canonical([
            row["core_id"], row["home_id"], row["board_id"], row["home_revision"],
            row["board_revision"], row["event_count"], row["audit_head"],
            bytes(row["nonce"]).hex(), hashlib.sha256(bytes(row["ciphertext"])).hexdigest(),
        ])
        return hmac.new(self._key, b"family-board-state-v1\0" + payload, hashlib.sha256).hexdigest()

    def _command_digest(self, command):
        return hashlib.sha256(b"family-board-command-v1\0" + self._canonical(command.model_dump(mode="json"))).hexdigest()

    @staticmethod
    def _receipt_key(authority, request_id):
        return f"{authority.accountId}:{authority.sessionFamilyId}:{request_id}"

    def _authority(self, supplied, *, write=False):
        supplied = BoardAuthority.model_validate(supplied)
        current = self._resolve(supplied.accountId)
        if current is None or not current.active:
            raise ApiError("forbidden", 403)
        if (current.coreId, current.homeId, current.boardId) != (
            supplied.coreId, supplied.homeId, supplied.boardId
        ):
            raise ApiError("not_found", 404)
        if current != supplied:
            raise ApiError("revision_conflict", 409)
        if not supplied.canRead:
            raise ApiError("not_found", 404)
        if write and not supplied.canWrite:
            raise ApiError("forbidden", 403)
        return supplied

    def _row(self, connection, authority, *, required=True):
        row = connection.execute("SELECT * FROM family_boards WHERE board_id=?", (authority.boardId,)).fetchone()
        if row is None:
            if required:
                raise ApiError("not_found", 404)
            return None
        if (row["core_id"], row["home_id"], row["home_revision"]) != (
            authority.coreId, authority.homeId, authority.homeRevision
        ):
            raise ApiError("not_found", 404)
        return row

    def _decode_state(self, row):
        if (len(row["nonce"]) != 12 or row["event_count"] < 0 or row["event_count"] > MAX_EVENTS
                or row["board_revision"] < 1 or row["event_count"] != row["board_revision"]
                or not secrets.compare_digest(row["authentication_tag"], self._state_tag(row))):
            raise ValueError("invalid_board_state")
        return StoredBoard.model_validate_json(
            self._cipher.decrypt(row["nonce"], row["ciphertext"], self._state_aad(row))
        )

    def _event_hash(self, event_without_hash):
        return hmac.new(
            self._key,
            b"family-board-event-v1\0" + self._canonical(event_without_hash),
            hashlib.sha256,
        ).hexdigest()

    def _decode_events(self, connection, row):
        rows = connection.execute(
            "SELECT * FROM family_board_events WHERE board_id=? ORDER BY sequence LIMIT ?",
            (row["board_id"], MAX_EVENTS + 1),
        ).fetchall()
        if len(rows) != row["event_count"]:
            raise ValueError("invalid_event_count")
        previous = ZERO_HASH
        events = []
        for sequence, stored in enumerate(rows, 1):
            if (stored["sequence"] != sequence or stored["previous_hash"] != previous
                    or len(stored["nonce"]) != 12):
                raise ValueError("invalid_event_chain")
            plain = self._cipher.decrypt(
                stored["nonce"], stored["ciphertext"], self._event_aad(row, sequence, previous)
            )
            event = BoardAuditEvent.model_validate_json(plain)
            unsigned = event.model_dump(mode="json", exclude={"eventHash"})
            expected = self._event_hash(unsigned)
            if (event.sequence != sequence or event.previousHash != previous
                    or event.boardRevision != sequence
                    or not secrets.compare_digest(event.eventHash, expected)
                    or not secrets.compare_digest(stored["event_hash"], expected)):
                raise ValueError("invalid_event")
            events.append(event)
            previous = expected
        if previous != row["audit_head"]:
            raise ValueError("invalid_audit_head")
        return events

    def _save_state(self, connection, values, state):
        plain = state.model_dump_json().encode("utf-8")
        if len(plain) > 2_000_000:
            raise ApiError("payload_too_large", 413)
        nonce = secrets.token_bytes(12)
        provisional = dict(values, nonce=nonce, ciphertext=b"", authentication_tag="")
        ciphertext = self._cipher.encrypt(nonce, plain, self._state_aad(provisional))
        provisional["ciphertext"] = ciphertext
        provisional["authentication_tag"] = self._state_tag(provisional)
        connection.execute(
            "INSERT INTO family_boards VALUES(?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(board_id) DO UPDATE SET home_revision=excluded.home_revision,"
            "board_revision=excluded.board_revision,event_count=excluded.event_count,"
            "audit_head=excluded.audit_head,nonce=excluded.nonce,ciphertext=excluded.ciphertext,"
            "authentication_tag=excluded.authentication_tag",
            tuple(provisional[key] for key in (
                "board_id", "core_id", "home_id", "home_revision", "board_revision",
                "event_count", "audit_head", "nonce", "ciphertext", "authentication_tag"
            )),
        )
        return provisional

    def validate_storage(self):
        try:
            with self._connection() as connection:
                rows = connection.execute("SELECT * FROM family_boards ORDER BY board_id LIMIT 1001").fetchall()
                if len(rows) > 1000:
                    raise ValueError("board_capacity")
                for row in rows:
                    self._decode_state(row)
                    self._decode_events(connection, row)
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError("family_board_storage_invalid") from None

    def apply(self, authority, command):
        authority = self._authority(authority, write=True)
        command = BoardCommand.model_validate(command)
        digest = self._command_digest(command)
        try:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                row = self._row(connection, authority, required=False)
                if row is None:
                    if command.expectedBoardRevision != 0 or command.action != "append":
                        raise ApiError("revision_conflict", 409)
                    state = StoredBoard(elements=[], receipts={})
                    revision, count, head = 0, 0, ZERO_HASH
                else:
                    state = self._decode_state(row)
                    self._decode_events(connection, row)
                    revision, count, head = row["board_revision"], row["event_count"], row["audit_head"]
                receipt_key = self._receipt_key(authority, command.requestId)
                replay = state.receipts.get(receipt_key)
                if replay is not None:
                    if not secrets.compare_digest(replay.digest, digest):
                        raise ApiError("idempotency_conflict", 409)
                    self._authority(authority, write=True)
                    return replay.receipt
                if command.expectedBoardRevision != revision:
                    raise ApiError("revision_conflict", 409)
                if len(state.receipts) >= MAX_RECEIPTS or count >= MAX_EVENTS:
                    raise ApiError("revision_conflict", 409)
                elements = {item.id: item for item in state.elements}
                target = command.element.id if command.element is not None else command.elementId
                if command.action == "append":
                    if target in elements or len(elements) >= MAX_ELEMENTS:
                        raise ApiError("revision_conflict", 409)
                    elements[target] = command.element
                elif command.action == "update":
                    if target not in elements or elements[target].kind != command.element.kind:
                        raise ApiError("not_found", 404)
                    elements[target] = command.element
                else:
                    if target not in elements:
                        raise ApiError("not_found", 404)
                    del elements[target]
                revision += 1
                count += 1
                created_at = float(self._clock())
                unsigned = {
                    "schemaVersion": 1, "sequence": count, "action": command.action,
                    "actorId": authority.accountId, "elementId": target,
                    "boardRevision": revision, "createdAt": created_at, "previousHash": head,
                }
                event_hash = self._event_hash(unsigned)
                event = BoardAuditEvent(**unsigned, eventHash=event_hash)
                receipt = BoardReceipt(
                    schemaVersion=1, requestId=command.requestId, boardId=authority.boardId,
                    boardRevision=revision, auditSequence=count, action=command.action, elementId=target,
                )
                receipts = dict(state.receipts)
                receipts[receipt_key] = StoredReceipt(digest=digest, receipt=receipt)
                new_state = StoredBoard(elements=sorted(elements.values(), key=lambda item: item.id), receipts=receipts)
                self._authority(authority, write=True)
                values = {
                    "board_id": authority.boardId, "core_id": authority.coreId,
                    "home_id": authority.homeId, "home_revision": authority.homeRevision,
                    "board_revision": revision, "event_count": count, "audit_head": event_hash,
                }
                saved = self._save_state(connection, values, new_state)
                nonce = secrets.token_bytes(12)
                ciphertext = self._cipher.encrypt(
                    nonce, event.model_dump_json().encode("utf-8"),
                    self._event_aad(saved, count, head),
                )
                connection.execute(
                    "INSERT INTO family_board_events VALUES(?,?,?,?,?,?)",
                    (authority.boardId, count, nonce, ciphertext, head, event_hash),
                )
                return receipt
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def snapshot(self, authority):
        authority = self._authority(authority)
        try:
            with self._connection() as connection:
                row = self._row(connection, authority)
                state = self._decode_state(row)
                self._decode_events(connection, row)
                self._authority(authority)
                return BoardSnapshot(
                    schemaVersion=1, authority=authority, boardRevision=row["board_revision"],
                    auditHead=row["audit_head"], elements=state.elements,
                )
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def export_snapshot(self, authority, *, limit=512):
        if type(limit) is not int or not 1 <= limit <= MAX_ELEMENTS:
            raise ValueError("invalid_limit")
        authority = self._authority(authority)
        snap = self.snapshot(authority)
        if len(snap.elements) > limit:
            raise ApiError("payload_too_large", 413)
        return PublicBoardSnapshot(
            schemaVersion=1, coreId=authority.coreId, homeId=authority.homeId,
            homeRevision=authority.homeRevision, boardId=authority.boardId,
            memberRevision=authority.memberRevision, boardRevision=snap.boardRevision,
            auditHead=snap.auditHead, elements=snap.elements,
        )

    def delta(self, authority, *, after_sequence, limit=100):
        if type(after_sequence) is not int or after_sequence < 0 or type(limit) is not int or not 1 <= limit <= 100:
            raise ValueError("invalid_page")
        authority = self._authority(authority)
        try:
            with self._connection() as connection:
                row = self._row(connection, authority)
                self._decode_state(row)
                events = self._decode_events(connection, row)
                if after_sequence > row["event_count"]:
                    raise ApiError("revision_conflict", 409)
                page = events[after_sequence:after_sequence + limit]
                next_after = page[-1].sequence if page else after_sequence
                self._authority(authority)
                return BoardDelta(
                    schemaVersion=1, coreId=authority.coreId, homeId=authority.homeId,
                    boardId=authority.boardId, boardRevision=row["board_revision"],
                    afterSequence=after_sequence, nextAfter=next_after,
                    auditHead=row["audit_head"], events=page,
                )
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None
