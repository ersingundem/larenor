"""Authenticated CAS store for the selected Home Assistant comfort source."""

import hashlib
import hmac
import json
import sqlite3

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .source_models import (
    HomeAssistantComfortSource,
    HomeAssistantComfortSourceInput,
)
from .models import ComfortPolicy, RoomComfortScope


class RoomComfortSourceStore:
    def __init__(
        self, db, auth, key, context, connection_resolver, resource_resolver,
        preflight=None,
    ):
        self._db, self._auth, self._key = db, auth, key
        self._scope = HomeScope.model_validate(context.model_dump())
        self._connection_resolver = connection_resolver
        self._resource_resolver = resource_resolver
        self._preflight = preflight
        if (
            not callable(connection_resolver)
            or not callable(resource_resolver)
            or (preflight is not None and not callable(preflight))
        ):
            raise ValueError("invalid_comfort_source_resolver")

    def _tag(self, revision, payload):
        raw = json.dumps(
            [self._scope.coreId, self._scope.homeId, revision, payload],
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode()
        return hmac.new(
            self._key, b"larenor-room-comfort-source-v1\0" + raw,
            hashlib.sha256,
        ).hexdigest()

    def _decode(self, row):
        if row is None:
            raise ApiError("comfort_source_not_configured", 409)
        if (
            type(row["revision"]) is not int
            or not 1 <= row["revision"] <= 2**63 - 1
            or not isinstance(row["payload_json"], str)
            or len(row["payload_json"].encode()) > 65_536
            or not hmac.compare_digest(
                row["envelope_tag"],
                self._tag(row["revision"], row["payload_json"]),
            )
        ):
            raise ValueError("invalid_comfort_source")
        value = HomeAssistantComfortSource.model_validate_json(
            row["payload_json"]
        )
        if value.revision != row["revision"] or value.model_dump_json() != row[
            "payload_json"
        ]:
            raise ValueError("invalid_comfort_source")
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
        return row

    def validate_storage(self):
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                rows = connection.execute(
                    "SELECT * FROM room_comfort_source LIMIT 2"
                ).fetchall()
                if len(rows) > 1:
                    raise ValueError
                if rows:
                    self._decode(rows[0])
        except (sqlite3.Error, ValueError, TypeError):
            raise StartupError("invalid_room_comfort_source_storage") from None

    def get(self, actor=None):
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                if actor is not None:
                    self._actor(connection, actor)
                return self._decode(connection.execute(
                    "SELECT * FROM room_comfort_source WHERE singleton=1"
                ).fetchone())
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("comfort_source_unavailable", 503) from None

    def resolve(self, source):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            current = self._decode(connection.execute(
                "SELECT * FROM room_comfort_source WHERE singleton=1"
            ).fetchone())
            if current != source:
                raise ApiError("revision_conflict", 409)
            service = self._connection_resolver(
                connection, source.serviceId, source.serviceRevision
            )
            self._resource_resolver(connection, source.rooms)
            return service

    def reserve_effect(self, actor, expected_source):
        """Reserve current initiating-session authority without retaining a DB lock."""
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            actor_row = self._actor(connection, actor)
            source = self._decode(connection.execute(
                "SELECT * FROM room_comfort_source WHERE singleton=1"
            ).fetchone())
            if source != expected_source:
                raise ApiError("revision_conflict", 409)
            service = self._connection_resolver(
                connection, source.serviceId, source.serviceRevision
            )
            self._resource_resolver(connection, source.rooms)
            return (
                source, service, actor.id, actor_row["revision"],
                actor.family_id, actor.token_id,
            )

    def assert_effect_current(self, actor, expected):
        current = self.reserve_effect(actor, expected[0])
        if current != expected:
            raise ApiError("revision_conflict", 409)

    def _policy(self, source, home_revision):
        from .home_assistant import HomeAssistantComfortExecutor
        rooms = [
            RoomComfortScope(
                schemaVersion=1,
                coreId=self._scope.coreId,
                homeId=self._scope.homeId,
                roomId=item.roomId,
                roomRevision=item.roomRevision,
                areaId=item.areaId,
                areaRevision=item.areaRevision,
                hvac=HomeAssistantComfortExecutor.device(source, item, "hvac"),
                window=HomeAssistantComfortExecutor.device(
                    source, item, "window"
                ),
            )
            for item in source.rooms
        ]
        policy_id = hashlib.sha256(
            ("room-comfort-policy\0" + self._scope.homeId).encode()
        ).hexdigest()[:32]
        return ComfortPolicy(
            schemaVersion=1,
            coreId=self._scope.coreId,
            homeId=self._scope.homeId,
            policyId=policy_id,
            policyRevision=source.revision,
            rooms=rooms,
            targetTemperatureMilliC=source.targetTemperatureMilliC,
            temperatureToleranceMilliC=source.temperatureToleranceMilliC,
            humidityHighPermille=source.humidityHighPermille,
            co2HighPpm=source.co2HighPpm,
            vocHighPpb=source.vocHighPpb,
            outdoorAqiLimit=source.outdoorAqiLimit,
            freezeThresholdMilliC=source.freezeThresholdMilliC,
            indoorMaxAgeMs=source.indoorMaxAgeMs,
            outdoorMaxAgeMs=source.outdoorMaxAgeMs,
            occupancyMaxAgeMs=source.occupancyMaxAgeMs,
            previewTtlMs=source.previewTtlMs,
            active=True,
        )

    def policy(self):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            source = self._decode(connection.execute(
                "SELECT * FROM room_comfort_source WHERE singleton=1"
            ).fetchone())
            self._connection_resolver(
                connection, source.serviceId, source.serviceRevision
            )
            home_revision = self._resource_resolver(connection, source.rooms)
        return home_revision, self._policy(source, home_revision)

    def assert_policy(self, connection, home_revision, policy):
        source = self._decode(connection.execute(
            "SELECT * FROM room_comfort_source WHERE singleton=1"
        ).fetchone())
        self._connection_resolver(
            connection, source.serviceId, source.serviceRevision
        )
        current_home = self._resource_resolver(connection, source.rooms)
        if (
            current_home != home_revision
            or self._policy(source, current_home) != policy
        ):
            raise ApiError("revision_conflict", 409)

    def put(self, actor, raw):
        try:
            body = HomeAssistantComfortSourceInput.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                self._actor(connection, actor)
                row = connection.execute(
                    "SELECT * FROM room_comfort_source WHERE singleton=1"
                ).fetchone()
                old = None if row is None else self._decode(row)
                if (old is None) != (body.expectedRevision is None) or (
                    old is not None and old.revision != body.expectedRevision
                ):
                    raise ApiError("revision_conflict", 409)
                self._connection_resolver(
                    connection, body.serviceId, body.expectedServiceRevision
                )
                self._resource_resolver(connection, body.rooms)
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("comfort_source_unavailable", 503) from None
        if self._preflight is not None:
            self._preflight(body)
        try:
            with self._db.transaction() as connection:
                self._actor(connection, actor)
                row = connection.execute(
                    "SELECT * FROM room_comfort_source WHERE singleton=1"
                ).fetchone()
                old = None if row is None else self._decode(row)
                if (old is None) != (body.expectedRevision is None) or (
                    old is not None and old.revision != body.expectedRevision
                ):
                    raise ApiError("revision_conflict", 409)
                revision = 1 if old is None else old.revision + 1
                if revision > 2**63 - 1:
                    raise ApiError("revision_conflict", 409)
                self._connection_resolver(
                    connection, body.serviceId, body.expectedServiceRevision
                )
                self._resource_resolver(connection, body.rooms)
                value = HomeAssistantComfortSource.from_input(body, revision)
                payload = value.model_dump_json()
                connection.execute(
                    "INSERT INTO room_comfort_source VALUES(1,?,?,?) "
                    "ON CONFLICT(singleton) DO UPDATE SET "
                    "revision=excluded.revision,payload_json=excluded.payload_json,"
                    "envelope_tag=excluded.envelope_tag",
                    (revision, payload, self._tag(revision, payload)),
                )
                return value
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("comfort_source_unavailable", 503) from None
