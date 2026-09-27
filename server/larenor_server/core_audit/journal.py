"""Tamper-evident journal over the existing bounded Core audit tables.

The journal binds each retained legacy audit row into one ordered hash chain.
Its HMAC-authenticated head detects local alteration. A checkpoint retained
outside the Core database is still required to detect a complete rollback to
an older, internally valid database snapshot.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import math
import re
import secrets
import sqlite3
from collections.abc import Iterable

from ..errors import ApiError, StartupError
from . import schema


_HEX_32 = re.compile(r"[0-9a-f]{32}")
_HEX_64 = re.compile(r"[0-9a-f]{64}")
_CHECKPOINT = re.compile(r"[A-Za-z0-9_-]{1,400}\.[0-9a-f]{64}")

_SOURCE_COLUMNS = {
    "admin": (
        "SELECT id,event,action,object,status,timestamp,actor_id,target_id "
        "FROM admin_audit ORDER BY id"
    ),
    "home_resource": (
        "SELECT sequence,action,status,actor_id,target_id,created_at "
        "FROM home_resource_audit ORDER BY sequence"
    ),
    "service": (
        "SELECT id,event,action,status,timestamp,actor_id,target_id "
        "FROM service_audit ORDER BY id"
    ),
}


def _json(value) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        allow_nan=False,
        separators=(",", ":"),
    ).encode("ascii")


def _signed(key: bytes, domain: bytes, value) -> str:
    return hmac.new(key, domain + _json(value), hashlib.sha256).hexdigest()


def _scope(scope) -> tuple[str, str]:
    core_id = getattr(scope, "coreId", None)
    home_id = getattr(scope, "homeId", None)
    if (
        not isinstance(core_id, str)
        or _HEX_32.fullmatch(core_id) is None
        or not isinstance(home_id, str)
        or _HEX_32.fullmatch(home_id) is None
    ):
        raise ValueError("invalid_core_audit_scope")
    return core_id, home_id


def _key(key: bytes) -> bytes:
    if not isinstance(key, bytes) or len(key) != 32:
        raise ValueError("invalid_core_audit_key")
    return key


def _transaction(connection: sqlite3.Connection) -> None:
    if not isinstance(connection, sqlite3.Connection) or not connection.in_transaction:
        raise ValueError("core_audit_transaction_required")


def _state_tag(key: bytes, scope, chain_id: str, sequence: int, head: str) -> str:
    core_id, home_id = _scope(scope)
    return _signed(
        _key(key),
        b"larenor-core-audit-head-v1\0",
        [1, core_id, home_id, chain_id, sequence, head],
    )


def _state(connection: sqlite3.Connection, key: bytes, scope):
    good = (
        "singleton=1 AND typeof(sequence)='integer' AND sequence BETWEEN 0 AND ? "
        "AND typeof(chain_id)='text' AND length(CAST(chain_id AS BLOB))=32 "
        "AND chain_id NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(head_hash)='text' AND length(CAST(head_hash AS BLOB))=64 "
        "AND head_hash NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(authentication_tag)='text' "
        "AND length(CAST(authentication_tag AS BLOB))=64 "
        "AND authentication_tag NOT GLOB '*[^0-9a-f]*'"
    )
    count, bad = connection.execute(
        "SELECT COUNT(*),COALESCE(SUM(CASE WHEN " + good
        + " THEN 0 ELSE 1 END),0) FROM core_audit_state",
        (schema.MAX_ENTRIES,),
    ).fetchone()
    if count != 1 or bad:
        raise ValueError("invalid_core_audit_state")
    state = connection.execute("SELECT * FROM core_audit_state").fetchone()
    if not hmac.compare_digest(
        state["authentication_tag"],
        _state_tag(
            key,
            scope,
            state["chain_id"],
            state["sequence"],
            state["head_hash"],
        ),
    ):
        raise ValueError("invalid_core_audit_state")
    return state


def _chain_rows(connection: sqlite3.Connection):
    good = (
        "typeof(sequence)='integer' AND sequence BETWEEN 1 AND ? "
        "AND kind IN ('baseline','append') "
        "AND source IN ('admin','home_resource','service') "
        "AND typeof(source_id)='integer' AND source_id BETWEEN 1 AND 9223372036854775807 "
        "AND typeof(payload_hash)='text' AND length(CAST(payload_hash AS BLOB))=64 "
        "AND payload_hash NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(previous_hash)='text' AND length(CAST(previous_hash AS BLOB))=64 "
        "AND previous_hash NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(entry_hash)='text' AND length(CAST(entry_hash AS BLOB))=64 "
        "AND entry_hash NOT GLOB '*[^0-9a-f]*'"
    )
    count, bad = connection.execute(
        "SELECT COUNT(*),COALESCE(SUM(CASE WHEN " + good
        + " THEN 0 ELSE 1 END),0) FROM core_audit_chain",
        (schema.MAX_ENTRIES,),
    ).fetchone()
    if count > schema.MAX_ENTRIES or bad:
        raise ValueError("invalid_core_audit_chain")
    return connection.execute(
        "SELECT * FROM core_audit_chain ORDER BY sequence LIMIT ?",
        (schema.MAX_ENTRIES + 1,),
    ).fetchall()


def _bounded_text(value, *, maximum: int, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if (
        not isinstance(value, str)
        or not 1 <= len(value.encode("utf-8")) <= maximum
        or any(ord(char) < 0x20 or ord(char) == 0x7F for char in value)
    ):
        raise ValueError("invalid_core_audit_source")
    return value


def _identity(value, *, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or _HEX_32.fullmatch(value) is None:
        raise ValueError("invalid_core_audit_source")
    return value


def _number(value) -> str:
    if type(value) not in (int, float):
        raise ValueError("invalid_core_audit_source")
    converted = float(value)
    if not math.isfinite(converted) or converted < 0:
        raise ValueError("invalid_core_audit_source")
    return converted.hex()


def _source_id(source: str, row) -> int:
    value = row["sequence" if source == "home_resource" else "id"]
    if type(value) is not int or not 1 <= value <= 2**63 - 1:
        raise ValueError("invalid_core_audit_source")
    return value


def _payload(source: str, row):
    source_id = _source_id(source, row)
    if source == "admin":
        event = _bounded_text(row["event"], maximum=128)
        action = _bounded_text(row["action"], maximum=64)
        object_type = _bounded_text(row["object"], maximum=32)
        status = _bounded_text(row["status"], maximum=16)
        if (
            (event, action, object_type)
            not in {
                ("admin.user.created", "create", "user"),
                ("admin.user.updated", "update", "user"),
                ("admin.user.password_reset", "reset_password", "user"),
                ("admin.session.revoked", "revoke", "session"),
            }
            or status not in {"success", "denied"}
        ):
            raise ValueError("invalid_core_audit_source")
        return [
            1,
            source_id,
            event,
            action,
            object_type,
            status,
            _number(row["timestamp"]),
            _identity(row["actor_id"]),
            _identity(row["target_id"], nullable=True),
        ]
    if source == "home_resource":
        action = _bounded_text(row["action"], maximum=32)
        status = _bounded_text(row["status"], maximum=16)
        if action not in {"create", "update", "delete", "grant"} or status not in {
            "success",
            "denied",
        }:
            raise ValueError("invalid_core_audit_source")
        return [
            1,
            source_id,
            action,
            status,
            _identity(row["actor_id"]),
            _identity(row["target_id"]),
            _number(row["created_at"]),
        ]
    if source == "service":
        action = _bounded_text(row["action"], maximum=32)
        status = _bounded_text(row["status"], maximum=16)
        if action not in {"create", "update", "delete", "check"} or status not in {
            "success",
            "denied",
        }:
            raise ValueError("invalid_core_audit_source")
        return [
            1,
            source_id,
            _bounded_text(row["event"], maximum=128),
            action,
            status,
            _number(row["timestamp"]),
            _identity(row["actor_id"]),
            _identity(row["target_id"]),
        ]
    raise ValueError("invalid_core_audit_source")


def _payload_hash(source: str, row) -> str:
    return hashlib.sha256(
        b"larenor-core-audit-payload-v1\0" + _json([source, _payload(source, row)])
    ).hexdigest()


def _preflight_source(connection: sqlite3.Connection, source: str) -> None:
    if source == "admin":
        text_fields = ("event", "action", "object", "status", "actor_id")
        nullable_fields = ("target_id",)
        table = "admin_audit"
    elif source == "home_resource":
        text_fields = ("action", "status", "actor_id", "target_id")
        nullable_fields = ()
        table = "home_resource_audit"
    elif source == "service":
        text_fields = ("event", "action", "status", "actor_id", "target_id")
        nullable_fields = ()
        table = "service_audit"
    else:
        raise ValueError("invalid_core_audit_source")
    checks = [
        f"typeof({field})='text' AND length(CAST({field} AS BLOB)) BETWEEN 1 AND 128"
        for field in text_fields
    ]
    checks.extend(
        f"({field} IS NULL OR (typeof({field})='text' AND "
        f"length(CAST({field} AS BLOB)) BETWEEN 1 AND 128))"
        for field in nullable_fields
    )
    count, bad = connection.execute(
        "SELECT COUNT(*),COALESCE(SUM(CASE WHEN "
        + " AND ".join(checks)
        + f" THEN 0 ELSE 1 END),0) FROM {table}"
    ).fetchone()
    if count > schema.MAX_SOURCE_ROWS or bad:
        raise ValueError("invalid_core_audit_source")


def _source_rows(connection: sqlite3.Connection, source: str):
    _preflight_source(connection, source)
    rows = connection.execute(_SOURCE_COLUMNS[source]).fetchall()
    if len(rows) > schema.MAX_SOURCE_ROWS:
        raise ValueError("invalid_core_audit_source")
    return rows


def _sources(connection: sqlite3.Connection) -> dict[tuple[str, int], str]:
    result: dict[tuple[str, int], str] = {}
    for source in schema.SOURCES:
        for row in _source_rows(connection, source):
            identity = (source, _source_id(source, row))
            if identity in result:
                raise ValueError("invalid_core_audit_source")
            result[identity] = _payload_hash(source, row)
    if len(result) > schema.MAX_ENTRIES:
        raise ValueError("invalid_core_audit_source")
    return result


def _entry_hash(
    scope,
    chain_id: str,
    sequence: int,
    kind: str,
    source: str,
    source_id: int,
    payload_hash: str,
    previous: str,
) -> str:
    core_id, home_id = _scope(scope)
    return hashlib.sha256(
        b"larenor-core-audit-entry-v1\0"
        + _json(
            [
                1,
                core_id,
                home_id,
                chain_id,
                sequence,
                kind,
                source,
                source_id,
                payload_hash,
                previous,
            ]
        )
    ).hexdigest()


def verify(connection: sqlite3.Connection, key: bytes, scope):
    """Verify schema, chain, authenticated head, and every retained source row."""

    _transaction(connection)
    _key(key)
    _scope(scope)
    schema.validate_schema(connection)
    state = _state(connection, key, scope)
    source_rows = _sources(connection)
    chain_rows = _chain_rows(connection)
    if len(source_rows) != len(chain_rows):
        raise ValueError("invalid_core_audit_chain")
    previous = schema.ZERO_HASH
    seen: set[tuple[str, int]] = set()
    saw_append = False
    for sequence, row in enumerate(chain_rows, 1):
        identity = (row["source"], row["source_id"])
        saw_append = saw_append or row["kind"] == "append"
        if (
            row["sequence"] != sequence
            or (saw_append and row["kind"] == "baseline")
            or identity in seen
            or source_rows.get(identity) != row["payload_hash"]
            or row["previous_hash"] != previous
            or row["entry_hash"]
            != _entry_hash(
                scope,
                state["chain_id"],
                sequence,
                row["kind"],
                row["source"],
                row["source_id"],
                row["payload_hash"],
                previous,
            )
        ):
            raise ValueError("invalid_core_audit_chain")
        seen.add(identity)
        previous = row["entry_hash"]
    if seen != set(source_rows) or (state["sequence"], state["head_hash"]) != (
        len(chain_rows),
        previous,
    ):
        raise ValueError("invalid_core_audit_chain")
    return state


def _append_row(
    connection: sqlite3.Connection,
    key: bytes,
    scope,
    row,
    source: str,
    *,
    kind: str,
) -> tuple[int, str]:
    state = _state(connection, key, scope)
    sequence = state["sequence"] + 1
    if sequence > schema.MAX_ENTRIES:
        raise ApiError("audit_limit_reached", 429)
    source_id = _source_id(source, row)
    payload_hash = _payload_hash(source, row)
    head = _entry_hash(
        scope,
        state["chain_id"],
        sequence,
        kind,
        source,
        source_id,
        payload_hash,
        state["head_hash"],
    )
    connection.execute(
        "INSERT INTO core_audit_chain VALUES(?,?,?,?,?,?,?)",
        (
            sequence,
            kind,
            source,
            source_id,
            payload_hash,
            state["head_hash"],
            head,
        ),
    )
    connection.execute(
        "UPDATE core_audit_state SET sequence=?,head_hash=?,authentication_tag=? "
        "WHERE singleton=1",
        (
            sequence,
            head,
            _state_tag(key, scope, state["chain_id"], sequence, head),
        ),
    )
    return sequence, head


def _record(
    connection: sqlite3.Connection,
    key: bytes,
    scope,
    source: str,
    statement: str,
    values: Iterable,
) -> int:
    """Insert one legacy audit row and its chain entry in the caller's TX."""

    try:
        _transaction(connection)
        verify(connection, key, scope)
        table = {
            "admin": "admin_audit",
            "home_resource": "home_resource_audit",
            "service": "service_audit",
        }.get(source)
        if table is None:
            raise ValueError("invalid_core_audit_source")
        count = connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        if count >= schema.MAX_SOURCE_ROWS:
            raise ApiError("audit_limit_reached", 429)
        cursor = connection.execute(statement, tuple(values))
        source_id = cursor.lastrowid
        id_column = "sequence" if source == "home_resource" else "id"
        row = connection.execute(
            _SOURCE_COLUMNS[source].replace(
                f" ORDER BY {id_column}", f" WHERE {id_column}=?"
            ),
            (source_id,),
        ).fetchone()
        if row is None:
            raise ValueError("invalid_core_audit_source")
        _append_row(connection, key, scope, row, source, kind="append")
        return source_id
    except ApiError:
        raise
    except (OverflowError, TypeError, ValueError, sqlite3.Error):
        raise ApiError("core_audit_integrity_failed", 503) from None


def append_admin(
    connection: sqlite3.Connection,
    key: bytes,
    scope,
    *,
    event: str,
    action: str,
    object_type: str,
    status: str,
    timestamp: float,
    actor_id: str,
    target_id: str | None,
) -> int:
    return _record(
        connection,
        key,
        scope,
        "admin",
        "INSERT INTO admin_audit(event,action,object,status,timestamp,actor_id,target_id) "
        "VALUES(?,?,?,?,?,?,?)",
        (event, action, object_type, status, timestamp, actor_id, target_id),
    )


def append_home_resource(
    connection: sqlite3.Connection,
    key: bytes,
    scope,
    *,
    action: str,
    status: str,
    actor_id: str,
    target_id: str,
    created_at: float,
) -> int:
    return _record(
        connection,
        key,
        scope,
        "home_resource",
        "INSERT INTO home_resource_audit(action,status,actor_id,target_id,created_at) "
        "VALUES(?,?,?,?,?)",
        (action, status, actor_id, target_id, created_at),
    )


def append_service(
    connection: sqlite3.Connection,
    key: bytes,
    scope,
    *,
    event: str,
    action: str,
    status: str,
    timestamp: float,
    actor_id: str,
    target_id: str,
) -> int:
    return _record(
        connection,
        key,
        scope,
        "service",
        "INSERT INTO service_audit(event,action,status,timestamp,actor_id,target_id) "
        "VALUES(?,?,?,?,?,?)",
        (event, action, status, timestamp, actor_id, target_id),
    )


def migrate(connection: sqlite3.Connection, key: bytes, scope) -> None:
    """Install or validate v1 under the existing Core initialization lock."""

    try:
        _transaction(connection)
        _key(key)
        _scope(scope)
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key=?", (schema.MARKER_KEY,)
        ).fetchone()
        if marker is None:
            if schema.objects(connection):
                raise ValueError("invalid_core_audit_schema")
            for statement in schema.TABLES.values():
                connection.execute(statement)
            chain_id = secrets.token_hex(16)
            connection.execute(
                "INSERT INTO core_audit_state VALUES(1,?,0,?,?)",
                (
                    chain_id,
                    schema.ZERO_HASH,
                    _state_tag(key, scope, chain_id, 0, schema.ZERO_HASH),
                ),
            )
            connection.execute(
                "INSERT INTO metadata(key,value) VALUES(?,?)",
                (schema.MARKER_KEY, schema.SCHEMA_VERSION),
            )
            # The old tables have no authenticated common chronology. Preserve
            # them in a deterministic source/id order without inventing one.
            for source in schema.SOURCES:
                for row in _source_rows(connection, source):
                    _append_row(connection, key, scope, row, source, kind="baseline")
        elif marker["value"] != schema.SCHEMA_VERSION:
            raise ValueError("invalid_core_audit_schema")
        verify(connection, key, scope)
    except (ApiError, OverflowError, TypeError, ValueError, sqlite3.Error):
        raise StartupError("core_audit_storage_invalid") from None


def checkpoint(
    connection: sqlite3.Connection,
    key: bytes,
    scope,
    expected: str | None = None,
) -> dict:
    """Verify the journal and optionally compare a caller-retained prefix."""

    state = verify(connection, key, scope)
    core_id, home_id = _scope(scope)
    payload = [
        1,
        core_id,
        home_id,
        state["chain_id"],
        state["sequence"],
        state["head_hash"],
    ]
    if expected is not None:
        if not isinstance(expected, str) or len(expected) > 512 or _CHECKPOINT.fullmatch(expected) is None:
            raise ApiError("invalid_request")
        encoded, signature = expected.split(".")
        try:
            decoded = base64.b64decode(
                encoded + "=" * (-len(encoded) % 4),
                altchars=b"-_",
                validate=True,
            )
            previous = json.loads(decoded)
            if (
                type(previous) is not list
                or len(previous) != 6
                or previous[0] != 1
                or any(
                    not isinstance(previous[index], str)
                    or _HEX_32.fullmatch(previous[index]) is None
                    for index in (1, 2, 3)
                )
                or type(previous[4]) is not int
                or not 0 <= previous[4] <= schema.MAX_ENTRIES
                or not isinstance(previous[5], str)
                or _HEX_64.fullmatch(previous[5]) is None
                or _json(previous) != decoded
            ):
                raise ValueError("invalid_checkpoint")
        except (UnicodeError, ValueError, TypeError):
            raise ApiError("invalid_request") from None
        if not hmac.compare_digest(
            signature,
            _signed(key, b"larenor-core-audit-checkpoint-v1\0", previous),
        ):
            raise ApiError("revision_conflict", 409)
        prefix = connection.execute(
            "SELECT entry_hash FROM core_audit_chain WHERE sequence=?",
            (previous[4],),
        ).fetchone()
        prefix_hash = (
            schema.ZERO_HASH
            if previous[4] == 0
            else None if prefix is None else prefix[0]
        )
        if (
            previous[1:4] != payload[1:4]
            or previous[4] > payload[4]
            or previous[5] != prefix_hash
        ):
            raise ApiError("revision_conflict", 409)
    token = base64.urlsafe_b64encode(_json(payload)).decode("ascii").rstrip("=")
    token += "." + _signed(key, b"larenor-core-audit-checkpoint-v1\0", payload)
    return {
        "schemaVersion": 1,
        "scope": scope.model_dump(),
        "chainId": state["chain_id"],
        "sequence": state["sequence"],
        "headHash": state["head_hash"],
        "checkpoint": token,
        "verified": True,
        "comparedCheckpoint": expected is not None,
        "causalityVerified": False,
    }
