"""Authenticated, revision-bound irrigation source settings."""

import hashlib
import hmac
import json
import sqlite3

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .source_models import (
    HomeAssistantIrrigationSource,
    HomeAssistantIrrigationSourceInput,
)


class IrrigationSourceStore:
    def __init__(
        self, db, auth, key, context, connection_resolver, room_resolver
    ):
        self._db, self._auth, self._key = db, auth, key
        self._scope = HomeScope.model_validate(context.model_dump())
        if not callable(connection_resolver):
            raise ValueError("invalid_irrigation_connection_resolver")
        if not callable(room_resolver):
            raise ValueError("invalid_irrigation_room_resolver")
        self._connection_resolver = connection_resolver
        self._room_resolver = room_resolver

    def _tag(self, revision, payload):
        raw = json.dumps(
            [self._scope.coreId, self._scope.homeId, revision, payload],
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        return hmac.new(
            self._key, b"larenor-irrigation-source-v1\0" + raw, hashlib.sha256
        ).hexdigest()

    def _decode(self, row):
        if row is None:
            raise ApiError("irrigation_source_not_configured", 409)
        if (
            type(row["revision"]) is not int
            or not 1 <= row["revision"] <= 2**63 - 1
            or not isinstance(row["payload_json"], str)
            or len(row["payload_json"].encode("utf-8")) > 65_536
            or not isinstance(row["envelope_tag"], str)
            or not hmac.compare_digest(
                row["envelope_tag"],
                self._tag(row["revision"], row["payload_json"]),
            )
        ):
            raise ValueError("invalid_irrigation_source")
        value = HomeAssistantIrrigationSource.model_validate_json(
            row["payload_json"]
        )
        if (
            value.revision != row["revision"]
            or value.model_dump_json() != row["payload_json"]
        ):
            raise ValueError("invalid_irrigation_source")
        return value

    def _actor(self, connection, actor):
        self._auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if (
            row is None or row["disabled"] or row["must_change_password"]
            or row["role"] != "admin" or actor.role != "admin"
        ):
            raise ApiError("forbidden", 403)
        return row["revision"]

    def validate_storage(self):
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                rows = connection.execute(
                    "SELECT * FROM irrigation_source LIMIT 2"
                ).fetchall()
                if len(rows) > 1:
                    raise ValueError("invalid_irrigation_source")
                if rows:
                    self._decode(rows[0])
        except (sqlite3.Error, ValueError, TypeError):
            raise StartupError("invalid_irrigation_source_storage") from None

    def get(self):
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                return self._decode(connection.execute(
                    "SELECT * FROM irrigation_source WHERE singleton=1"
                ).fetchone())
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("irrigation_source_unavailable", 503) from None

    def for_actor(self, actor):
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                self._actor(connection, actor)
                return self._decode(connection.execute(
                    "SELECT * FROM irrigation_source WHERE singleton=1"
                ).fetchone())
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("irrigation_source_unavailable", 503) from None

    def put(self, actor, raw):
        try:
            body = HomeAssistantIrrigationSourceInput.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            with self._db.transaction() as connection:
                self._actor(connection, actor)
                row = connection.execute(
                    "SELECT * FROM irrigation_source WHERE singleton=1"
                ).fetchone()
                old = None if row is None else self._decode(row)
                if (old is None) != (body.expectedRevision is None):
                    raise ApiError("revision_conflict", 409)
                if old is not None and body.expectedRevision != old.revision:
                    raise ApiError("revision_conflict", 409)
                revision = 1 if old is None else old.revision + 1
                if revision > 2**63 - 1:
                    raise ApiError("revision_conflict", 409)
                # Resolve the exact encrypted service row inside this same CAS
                # transaction. Credentials never enter this store or response.
                self._connection_resolver(
                    connection, body.serviceId, body.expectedServiceRevision
                )
                self._room_resolver(connection, body.zones)
                value = HomeAssistantIrrigationSource.from_input(body, revision)
                payload = value.model_dump_json()
                tag = self._tag(revision, payload)
                connection.execute(
                    "INSERT INTO irrigation_source VALUES(1,?,?,?) "
                    "ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision,"
                    "payload_json=excluded.payload_json,envelope_tag=excluded.envelope_tag",
                    (revision, payload, tag),
                )
                return value
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("irrigation_source_unavailable", 503) from None
