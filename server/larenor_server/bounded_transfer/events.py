"""Authenticated append-only transfer events with caller-scoped cursors."""

import hashlib
import hmac
import json
import math
import re
import secrets
import sqlite3

from ..errors import ApiError, StartupError
from . import schema


MAX_EVENTS = schema.MAX_RECEIPTS * 2
ZERO = "0" * 64
_IDENTITY = re.compile(r"^[0-9a-f]{32}$")
_DIGEST = re.compile(r"^[0-9a-f]{64}$")
_CONTENT_TYPE = re.compile(r"^[A-Za-z0-9!#$&^_.+\-/;= ]{1,128}$")
EVENT_TABLE = """CREATE TABLE bounded_transfer_events (
    sequence INTEGER PRIMARY KEY CHECK(sequence>0),
    kind TEXT NOT NULL CHECK(kind IN ('baseline','accepted','result')),
    request_id TEXT NOT NULL, actor_id TEXT NOT NULL,
    core_id TEXT NOT NULL, home_id TEXT NOT NULL, resource_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('accepted','completed','interrupted')),
    trace_id TEXT NOT NULL, content_length INTEGER NOT NULL,
    sha256 TEXT NOT NULL, content_type TEXT NOT NULL,
    service_revision INTEGER NOT NULL,
    created_at REAL NOT NULL, updated_at REAL NOT NULL,
    previous_hash TEXT NOT NULL, entry_hash TEXT NOT NULL
)"""
STATE_TABLE = """CREATE TABLE bounded_transfer_event_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    chain_id TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence>=0),
    head_hash TEXT NOT NULL, authentication_tag TEXT NOT NULL
)"""


def _json(value):
    return json.dumps(
        value, ensure_ascii=True, separators=(",", ":"), allow_nan=False
    ).encode("ascii")


def _signed(key, domain, value):
    return hmac.new(key, domain + _json(value), hashlib.sha256).hexdigest()


def _state_tag(key, chain_id, sequence, head):
    return _signed(
        key,
        b"larenor-bounded-transfer-event-head-v1\0",
        [chain_id, sequence, head],
    )


def _entry_hash(key, chain_id, sequence, kind, row, previous):
    values = [
        sequence,
        kind,
        *[
            row[field]
            for field in (
                "request_id",
                "actor_id",
                "core_id",
                "home_id",
                "resource_id",
                "state",
                "trace_id",
                "content_length",
                "sha256",
                "content_type",
                "service_revision",
                "created_at",
                "updated_at",
            )
        ],
        previous,
    ]
    return _signed(key, b"larenor-bounded-transfer-event-v1\0", [chain_id, *values])


def _objects(connection):
    names = {"bounded_transfer_events", "bounded_transfer_event_state"}
    rows = connection.execute(
        "SELECT name,type,sql FROM sqlite_master WHERE name IN (?,?)",
        tuple(names),
    ).fetchall()
    if len(rows) > 2 or any(
        len(row["name"]) > 128 or len(row["sql"] or "") > 4096 for row in rows
    ):
        raise ValueError("invalid_event_storage")
    return {row["name"]: row for row in rows}


def _exact_schema(connection):
    objects = _objects(connection)
    expected = {
        "bounded_transfer_events": EVENT_TABLE,
        "bounded_transfer_event_state": STATE_TABLE,
    }
    if set(objects) != set(expected) or any(
        row["type"] != "table"
        or " ".join(row["sql"].split()) != " ".join(expected[name].split())
        for name, row in objects.items()
    ):
        raise ValueError("invalid_event_storage")


def _state(connection, key):
    rows = connection.execute("SELECT * FROM bounded_transfer_event_state").fetchall()
    if len(rows) != 1:
        raise ValueError("invalid_event_storage")
    row = rows[0]
    if (
        type(row["singleton"]) is not int
        or row["singleton"] != 1
        or type(row["chain_id"]) is not str
        or _IDENTITY.fullmatch(row["chain_id"]) is None
        or type(row["sequence"]) is not int
        or not 0 <= row["sequence"] <= MAX_EVENTS
        or type(row["head_hash"]) is not str
        or _DIGEST.fullmatch(row["head_hash"]) is None
        or type(row["authentication_tag"]) is not str
        or _DIGEST.fullmatch(row["authentication_tag"]) is None
        or not hmac.compare_digest(
            row["authentication_tag"],
            _state_tag(key, row["chain_id"], row["sequence"], row["head_hash"]),
        )
    ):
        raise ValueError("invalid_event_storage")
    return row


def _valid_event(row):
    identities = [
        row[field]
        for field in (
            "request_id",
            "actor_id",
            "core_id",
            "home_id",
            "resource_id",
            "trace_id",
        )
    ]
    return (
        type(row["sequence"]) is int
        and 1 <= row["sequence"] <= MAX_EVENTS
        and row["kind"] in {"baseline", "accepted", "result"}
        and all(type(value) is str and _IDENTITY.fullmatch(value) for value in identities)
        and row["request_id"] == row["trace_id"]
        and row["state"] in {"accepted", "completed", "interrupted"}
        and (row["kind"] == "baseline"
             or row["kind"] == "accepted" and row["state"] == "accepted"
             or row["kind"] == "result" and row["state"] in {"completed", "interrupted"})
        and type(row["content_length"]) is int
        and 0 <= row["content_length"] <= 256 * 1024
        and type(row["sha256"]) is str
        and _DIGEST.fullmatch(row["sha256"])
        and type(row["content_type"]) is str
        and _CONTENT_TYPE.fullmatch(row["content_type"])
        and "\r" not in row["content_type"]
        and "\n" not in row["content_type"]
        and type(row["service_revision"]) is int
        and 1 <= row["service_revision"] <= 2**63 - 1
        and type(row["created_at"]) is float
        and type(row["updated_at"]) is float
        and math.isfinite(row["created_at"])
        and math.isfinite(row["updated_at"])
        and 0 <= row["created_at"] <= row["updated_at"]
        and type(row["previous_hash"]) is str
        and _DIGEST.fullmatch(row["previous_hash"])
        and type(row["entry_hash"]) is str
        and _DIGEST.fullmatch(row["entry_hash"])
    )


def _snapshot(row):
    return tuple(
        row[field]
        for field in (
            "actor_id",
            "core_id",
            "home_id",
            "resource_id",
            "state",
            "trace_id",
            "content_length",
            "sha256",
            "content_type",
            "service_revision",
            "created_at",
            "updated_at",
        )
    )


def _receipt_tag(key, row):
    values = [
        row[field]
        for field in (
            "request_id",
            "actor_id",
            "core_id",
            "home_id",
            "resource_id",
            "envelope_hash",
            "state",
            "trace_id",
            "content_length",
            "sha256",
            "content_type",
            "service_revision",
            "created_at",
            "updated_at",
        )
    ]
    return _signed(key, b"larenor-bounded-transfer-receipt-v1\0", values)


def _verified_receipts(connection, key):
    receipts = connection.execute(
        "SELECT * FROM bounded_transfer_receipts ORDER BY request_id LIMIT ?",
        (schema.MAX_RECEIPTS + 1,),
    ).fetchall()
    for row in receipts:
        if (
            type(row["envelope_hash"]) is not str
            or _DIGEST.fullmatch(row["envelope_hash"]) is None
            or type(row["authentication_tag"]) is not str
            or _DIGEST.fullmatch(row["authentication_tag"]) is None
            or not hmac.compare_digest(
                row["authentication_tag"], _receipt_tag(key, row)
            )
        ):
            raise ValueError("invalid_event_storage")
    return receipts


def _chain(connection, key):
    _exact_schema(connection)
    state = _state(connection, key)
    rows = connection.execute(
        "SELECT * FROM bounded_transfer_events ORDER BY sequence LIMIT ?",
        (MAX_EVENTS + 1,),
    ).fetchall()
    if len(rows) > MAX_EVENTS:
        raise ValueError("invalid_event_storage")
    previous = ZERO
    latest = {}
    phases = {}
    nonbaseline = False
    for sequence, row in enumerate(rows, 1):
        if not _valid_event(row) or row["sequence"] != sequence:
            raise ValueError("invalid_event_storage")
        expected = _entry_hash(key, state["chain_id"], sequence, row["kind"], row, previous)
        if row["previous_hash"] != previous or not hmac.compare_digest(row["entry_hash"], expected):
            raise ValueError("invalid_event_storage")
        request_id = row["request_id"]
        phase = phases.get(request_id)
        if row["kind"] == "baseline":
            if nonbaseline or phase is not None:
                raise ValueError("invalid_event_storage")
            phases[request_id] = "final" if row["state"] != "accepted" else "accepted"
        elif row["kind"] == "accepted":
            nonbaseline = True
            if phase is not None:
                raise ValueError("invalid_event_storage")
            phases[request_id] = "accepted"
        else:
            nonbaseline = True
            if phase != "accepted":
                raise ValueError("invalid_event_storage")
            phases[request_id] = "final"
        latest[request_id] = _snapshot(row)
        previous = row["entry_hash"]
    if (state["sequence"], state["head_hash"]) != (len(rows), previous):
        raise ValueError("invalid_event_storage")
    return state, rows, latest


def validate(connection, key):
    state, rows, latest = _chain(connection, key)
    receipts = _verified_receipts(connection, key)
    if len(receipts) > schema.MAX_RECEIPTS or {
        row["request_id"]: _snapshot(row) for row in receipts
    } != latest:
        raise ValueError("invalid_event_storage")
    return state, rows


def append(connection, key, receipt, *, kind):
    state, _, _ = _chain(connection, key)
    sequence = state["sequence"] + 1
    if sequence > MAX_EVENTS:
        raise ApiError("bounded_transfer_limit_reached", 429)
    row = dict(receipt)
    entry_hash = _entry_hash(
        key, state["chain_id"], sequence, kind, row, state["head_hash"]
    )
    connection.execute(
        "INSERT INTO bounded_transfer_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            sequence,
            kind,
            *[
                row[field]
                for field in (
                    "request_id",
                    "actor_id",
                    "core_id",
                    "home_id",
                    "resource_id",
                    "state",
                    "trace_id",
                    "content_length",
                    "sha256",
                    "content_type",
                    "service_revision",
                    "created_at",
                    "updated_at",
                )
            ],
            state["head_hash"],
            entry_hash,
        ),
    )
    connection.execute(
        "UPDATE bounded_transfer_event_state SET sequence=?,head_hash=?,authentication_tag=? WHERE singleton=1",
        (
            sequence,
            entry_hash,
            _state_tag(key, state["chain_id"], sequence, entry_hash),
        ),
    )
    # Verify the newly appended transition before the caller can commit it.
    _chain(connection, key)


def _public(row):
    return {
        "sequence": row["sequence"],
        "kind": row["kind"],
        "actorId": row["actor_id"],
        "receipt": {
            "requestId": row["request_id"],
            "traceId": row["trace_id"],
            "state": row["state"],
            "contentLength": row["content_length"],
            "sha256": row["sha256"],
            "contentType": row["content_type"],
            "serviceRevision": row["service_revision"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        },
    }


def history(connection, key, actor, resource_id, ref, *, after, limit):
    state, rows = validate(connection, key)
    visible = [
        row
        for row in rows
        if row["resource_id"] == resource_id
        and (actor.role == "admin" or row["actor_id"] == actor.id)
    ]
    events = []
    for sequence, row in enumerate(visible, 1):
        value = _public(row)
        value["sequence"] = sequence
        events.append(value)
    head = len(events)
    if after is not None:
        if after > head:
            raise ApiError("not_found", 404)
        events = events[after:]
    page = events[:limit]
    view = [state["chain_id"], resource_id, "admin" if actor.role == "admin" else actor.id]
    chain_id = _signed(key, b"larenor-bounded-transfer-view-v1\0", view)[:32]
    return {
        "schemaVersion": 1,
        "ref": ref,
        "chainId": chain_id,
        "headSequence": head,
        "events": page,
        "nextAfter": page[-1]["sequence"] if len(events) > limit else None,
        "verified": True,
    }


def migrate(connection, key):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='bounded_transfer_event_schema'"
        ).fetchone()
        objects = _objects(connection)
        if marker is None:
            if objects:
                raise ValueError("partial_event_schema")
            connection.execute(EVENT_TABLE)
            connection.execute(STATE_TABLE)
            chain_id = secrets.token_hex(16)
            connection.execute(
                "INSERT INTO bounded_transfer_event_state VALUES(1,?,0,?,?)",
                (chain_id, ZERO, _state_tag(key, chain_id, 0, ZERO)),
            )
            connection.execute(
                "INSERT INTO metadata VALUES('bounded_transfer_event_schema','1')"
            )
            receipts = sorted(
                _verified_receipts(connection, key),
                key=lambda row: (row["created_at"], row["request_id"]),
            )
            for receipt in receipts:
                append(connection, key, receipt, kind="baseline")
        elif marker["value"] != "1" or set(objects) != {
            "bounded_transfer_events",
            "bounded_transfer_event_state",
        }:
            raise ValueError("invalid_event_schema")
        validate(connection, key)
    except (ApiError, sqlite3.Error, ValueError, TypeError, OverflowError):
        raise StartupError("bounded_transfer_storage_invalid") from None
