"""Encrypted, admin-only OpenSprinkler connection and station bindings."""

import hashlib
import hmac
import secrets
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .controller_models import (
    OpenSprinklerControllerInput,
    StoredOpenSprinklerController,
)
from .opensprinkler import OpenSprinklerBinding, OpenSprinklerConnection


class OpenSprinklerControllerStore:
    def __init__(self, db, auth, key, context, source_store, policy_resolver, clock):
        self._db, self._auth, self._source_store = db, auth, source_store
        self._scope = HomeScope.model_validate(context.model_dump())
        self._policy_resolver, self._clock = policy_resolver, clock
        self._cipher = AESGCM(hmac.new(
            key, b"larenor-opensprinkler-controller-v1", hashlib.sha256
        ).digest())

    def _aad(self, controller_id, revision, source_revision):
        return (
            f"larenor-opensprinkler-controller-v1:{self._scope.coreId}:"
            f"{self._scope.homeId}:{controller_id}:{revision}:{source_revision}"
        ).encode("ascii")

    def _decode(self, row):
        if row is None:
            raise ApiError("irrigation_controller_not_configured", 409)
        if (
            not isinstance(row["controller_id"], str)
            or len(row["controller_id"]) != 32
            or any(char not in "0123456789abcdef" for char in row["controller_id"])
            or type(row["revision"]) is not int
            or not 1 <= row["revision"] <= 2**63 - 1
            or type(row["source_revision"]) is not int
            or not 1 <= row["source_revision"] <= 2**63 - 1
            or type(row["nonce"]) is not bytes or len(row["nonce"]) != 12
            or type(row["ciphertext"]) is not bytes
            or not 16 <= len(row["ciphertext"]) <= 65_536
        ):
            raise ValueError("invalid_irrigation_controller")
        value = StoredOpenSprinklerController.model_validate_json(
            self._cipher.decrypt(
                row["nonce"], row["ciphertext"],
                self._aad(
                    row["controller_id"], row["revision"], row["source_revision"]
                ),
            )
        )
        if (
            value.controllerId != row["controller_id"]
            or value.revision != row["revision"]
            or value.sourceRevision != row["source_revision"]
        ):
            raise ValueError("invalid_irrigation_controller")
        return value

    def validate_storage(self):
        try:
            with self._db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM irrigation_opensprinkler_controller LIMIT 2"
                ).fetchall()
                if len(rows) > 1:
                    raise ValueError("invalid_irrigation_controller")
                if rows:
                    self._decode(rows[0])
        except (InvalidTag, sqlite3.Error, ValueError, TypeError):
            raise StartupError("invalid_irrigation_controller_storage") from None

    def _current(self, connection):
        return self._decode(connection.execute(
            "SELECT * FROM irrigation_opensprinkler_controller WHERE singleton=1"
        ).fetchone())

    @staticmethod
    def _validate_bindings(body, policy):
        zones = {item.zoneId: item for item in policy.zones}
        bound = {item.zoneId: item for item in body.stations}
        if set(bound) != set(zones) or any(
            bound[zone_id].expectedZoneRevision != zone.zoneRevision
            for zone_id, zone in zones.items()
        ):
            raise ApiError("revision_conflict", 409)

    def get_for_actor(self, actor):
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                self._source_store._actor(connection, actor)
                return self._current(connection).metadata()
        except ApiError:
            raise
        except (InvalidTag, sqlite3.Error, ValueError, TypeError):
            raise ApiError("irrigation_controller_unavailable", 503) from None

    def put(self, actor, raw):
        try:
            body = OpenSprinklerControllerInput.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            with self._db.transaction() as connection:
                self._source_store._actor(connection, actor)
                row = connection.execute(
                    "SELECT * FROM irrigation_opensprinkler_controller "
                    "WHERE singleton=1"
                ).fetchone()
                old = None if row is None else self._decode(row)
                if (old is None) != (body.expectedRevision is None):
                    raise ApiError("revision_conflict", 409)
                if old is not None and old.revision != body.expectedRevision:
                    raise ApiError("revision_conflict", 409)
                source = self._source_store._decode(connection.execute(
                    "SELECT * FROM irrigation_source WHERE singleton=1"
                ).fetchone())
                if source.revision != body.expectedSourceRevision:
                    raise ApiError("revision_conflict", 409)
                policy = self._policy_resolver(connection, source)
                self._validate_bindings(body, policy)
                revision = 1 if old is None else old.revision + 1
                if revision > 2**63 - 1:
                    raise ApiError("revision_conflict", 409)
                value = StoredOpenSprinklerController(
                    schemaVersion=1,
                    controllerId=(
                        secrets.token_hex(16) if old is None else old.controllerId
                    ),
                    revision=revision,
                    sourceRevision=source.revision,
                    baseUrl=body.baseUrl,
                    passwordMd5=body.passwordMd5,
                    stations=body.stations,
                )
                nonce = secrets.token_bytes(12)
                ciphertext = self._cipher.encrypt(
                    nonce,
                    value.model_dump_json().encode("utf-8"),
                    self._aad(value.controllerId, revision, source.revision),
                )
                now = self._clock()
                connection.execute(
                    "INSERT INTO irrigation_opensprinkler_controller "
                    "VALUES(1,?,?,?,?,?,?,?) ON CONFLICT(singleton) DO UPDATE SET "
                    "controller_id=excluded.controller_id,revision=excluded.revision,"
                    "source_revision=excluded.source_revision,nonce=excluded.nonce,"
                    "ciphertext=excluded.ciphertext,updated_at=excluded.updated_at",
                    (
                        value.controllerId, revision, source.revision, nonce,
                        ciphertext, now, now,
                    ),
                )
                return value.metadata()
        except ApiError:
            raise
        except (InvalidTag, sqlite3.Error, ValueError, TypeError):
            raise ApiError("irrigation_controller_unavailable", 503) from None

    def binding(self, zone):
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                value = self._current(connection)
                source = self._source_store._decode(connection.execute(
                    "SELECT * FROM irrigation_source WHERE singleton=1"
                ).fetchone())
                if value.sourceRevision != source.revision:
                    raise ApiError("irrigation_binding_changed", 409)
                policy = self._policy_resolver(connection, source)
                zones = {item.zoneId: item for item in policy.zones}
                expected = zones.get(zone.zoneId)
                station = next(
                    (item for item in value.stations if item.zoneId == zone.zoneId),
                    None,
                )
                if (
                    expected != zone or station is None
                    or station.expectedZoneRevision != zone.zoneRevision
                ):
                    raise ApiError("irrigation_binding_changed", 409)
                return OpenSprinklerBinding(
                    connection=OpenSprinklerConnection(
                        id=value.controllerId,
                        revision=value.revision,
                        base_url=value.baseUrl,
                        password_md5=value.passwordMd5,
                    ),
                    station_index=station.stationIndex,
                    zone=zone,
                )
        except ApiError:
            raise
        except (InvalidTag, sqlite3.Error, ValueError, TypeError):
            raise ApiError("irrigation_controller_unavailable", 503) from None
