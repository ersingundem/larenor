"""Encrypted HA MQTT-room binding with current actor/service/resource guards."""

from dataclasses import dataclass
import hashlib
import json
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .models import PresenceDevice, PresencePolicy, PresenceRoom, PresenceSource
from .provider_models import (
    MqttRoomMapping,
    MqttRoomConsentRevoke,
    MqttRoomSource,
    MqttRoomSourceInput,
    MqttRoomSourceView,
)


MAX_SOURCE_BYTES = 65_536


def _identity(*parts):
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()[:32]


@dataclass(frozen=True)
class VerifiedMqttRoomEntity:
    entity_name: str
    entity_unique_id: str
    provider_token: str
    observed_at_ms: int
    distance_milli: int


class MqttRoomSourceStore:
    def __init__(
        self, db, auth, key, context, connection_resolver, room_resolver,
        *, preflight,
    ):
        if not all(callable(value) for value in (
            connection_resolver, room_resolver, preflight
        )):
            raise ValueError("invalid_presence_provider_resolver")
        self._db, self._auth = db, auth
        self._scope = HomeScope.model_validate(context.model_dump())
        self._cipher = AESGCM(key)
        self._connection = connection_resolver
        self._room = room_resolver
        self._preflight = preflight

    def _aad(self, revision):
        return (
            f"larenor-room-presence-provider-v1:{self._scope.coreId}:"
            f"{self._scope.homeId}:{revision}"
        ).encode("ascii")

    def _decode(self, row):
        if row is None:
            raise ApiError("presence_source_not_configured", 409)
        if (
            type(row["revision"]) is not int
            or not 1 <= row["revision"] <= 2**53 - 1
            or type(row["nonce"]) is not bytes
            or len(row["nonce"]) != 12
            or type(row["ciphertext"]) is not bytes
            or not 16 <= len(row["ciphertext"]) <= MAX_SOURCE_BYTES + 16
        ):
            raise ValueError("invalid_presence_provider_source")
        raw = self._cipher.decrypt(
            row["nonce"], row["ciphertext"], self._aad(row["revision"])
        )
        if len(raw) > MAX_SOURCE_BYTES:
            raise ValueError("invalid_presence_provider_source")
        value = MqttRoomSource.model_validate_json(raw)
        if value.revision != row["revision"] or value.model_dump_json().encode() != raw:
            raise ValueError("invalid_presence_provider_source")
        return value

    def _read(self, connection):
        rows = connection.execute(
            "SELECT * FROM room_presence_provider_source LIMIT 2"
        ).fetchall()
        if len(rows) > 1:
            raise ValueError("invalid_presence_provider_source")
        return None if not rows else self._decode(rows[0])

    def _actor(self, connection, actor, *, admin):
        self._auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if (
            row is None or row["disabled"] or row["must_change_password"]
            or actor.must_change_password
            or (admin and (row["role"] != "admin" or actor.role != "admin"))
        ):
            raise ApiError("forbidden", 403)
        return row

    def _consent(self, connection, source):
        if not source.consentActive:
            raise ApiError("consent_required", 403)
        row = connection.execute(
            "SELECT revision,disabled,must_change_password FROM users WHERE id=?",
            (source.consentAccountId,),
        ).fetchone()
        if (
            row is None or row["disabled"] or row["must_change_password"]
            or row["revision"] != source.consentAccountRevision
        ):
            raise ApiError("consent_required", 403)

    def _resolve(self, connection, source):
        service = self._connection(
            connection, source.serviceId, source.serviceRevision
        )
        for mapping in source.mappings:
            self._room(connection, mapping.roomId, mapping.roomRevision)
        self._consent(connection, source)
        return service

    def validate_storage(self):
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                self._read(connection)
        except ApiError:
            raise StartupError("room_presence_provider_source_invalid") from None
        except (
            InvalidTag, UnicodeError, ValueError, TypeError, sqlite3.Error,
            json.JSONDecodeError,
        ):
            raise StartupError("room_presence_provider_source_invalid") from None

    @staticmethod
    def view(source):
        return MqttRoomSourceView(
            schemaVersion=1,
            revision=source.revision,
            serviceId=source.serviceId,
            serviceRevision=source.serviceRevision,
            entityId=source.entityId,
            entityName=source.entityName,
            consentActive=source.consentActive,
            maxSignalAgeMs=source.maxSignalAgeMs,
            rooms=[{
                "roomId": item.roomId,
                "roomRevision": item.roomRevision,
                "roomLabel": item.roomLabel,
            } for item in source.mappings],
        )

    def get(self, actor):
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                self._actor(connection, actor, admin=True)
                source = self._read(connection)
                if source is None:
                    raise ApiError("presence_source_not_configured", 409)
                return self.view(source)
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error):
            raise ApiError("presence_provider_unavailable", 503) from None

    def internal_source(self):
        """Return the encrypted binding to packaged runtime code only."""
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                return self._read(connection)
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error):
            raise ApiError("presence_provider_unavailable", 503) from None

    def _write(self, connection, source):
        raw_source = source.model_dump_json().encode()
        if len(raw_source) > MAX_SOURCE_BYTES:
            raise ApiError("presence_provider_unavailable", 503)
        import secrets
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, raw_source, self._aad(source.revision)
        )
        connection.execute(
            "INSERT INTO room_presence_provider_source VALUES(1,?,?,?) "
            "ON CONFLICT(singleton) DO UPDATE SET "
            "revision=excluded.revision,nonce=excluded.nonce,"
            "ciphertext=excluded.ciphertext",
            (source.revision, nonce, ciphertext),
        )

    def put(
        self, actor, raw, *, update_state, transaction_guard
    ):
        if not callable(update_state) or not callable(transaction_guard):
            raise ValueError("invalid_presence_provider_transaction")
        try:
            body = MqttRoomSourceInput.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                actor_row = self._actor(connection, actor, admin=True)
                old = self._read(connection)
                if (old is None) != (body.expectedRevision is None) or (
                    old is not None and old.revision != body.expectedRevision
                ):
                    raise ApiError("revision_conflict", 409)
                service = self._connection(
                    connection, body.serviceId, body.expectedServiceRevision
                )
                room_label = self._room(
                    connection, body.roomId, body.expectedRoomRevision
                )
            evidence = self._preflight(actor, service, body)
            if not isinstance(evidence, VerifiedMqttRoomEntity):
                raise ValueError("invalid_provider_evidence")
            with transaction_guard():
                with self._db.transaction() as connection:
                    current_actor = self._actor(connection, actor, admin=True)
                    if current_actor["revision"] != actor_row["revision"]:
                        raise ApiError("revision_conflict", 409)
                    old = self._read(connection)
                    if (old is None) != (body.expectedRevision is None) or (
                        old is not None and old.revision != body.expectedRevision
                    ):
                        raise ApiError("revision_conflict", 409)
                    current_service = self._connection(
                        connection, body.serviceId, body.expectedServiceRevision
                    )
                    current_label = self._room(
                        connection, body.roomId, body.expectedRoomRevision
                    )
                    if current_service != service or current_label != room_label:
                        raise ApiError("revision_conflict", 409)
                    revision = 1 if old is None else old.revision + 1
                    if revision > 2**53 - 1:
                        raise ApiError("revision_conflict", 409)
                    mapping = MqttRoomMapping(
                        roomId=body.roomId,
                        roomRevision=body.expectedRoomRevision,
                        roomLabel=room_label,
                        providerToken=evidence.provider_token,
                    )
                    same_provider = old is not None and (
                        old.serviceId == body.serviceId
                        and old.serviceRevision == body.expectedServiceRevision
                        and old.entityId == body.entityId
                        and old.entityUniqueId == evidence.entity_unique_id
                    )
                    mappings = [] if not same_provider else [
                        item for item in old.mappings
                        if item.roomId != mapping.roomId
                        and item.providerToken != mapping.providerToken
                    ]
                    mappings.append(mapping)
                    source = MqttRoomSource(
                        schemaVersion=1,
                        revision=revision,
                        serviceId=body.serviceId,
                        serviceRevision=body.expectedServiceRevision,
                        entityId=body.entityId,
                        entityUniqueId=evidence.entity_unique_id,
                        entityName=evidence.entity_name,
                        consentAccountId=actor.id,
                        consentAccountRevision=current_actor["revision"],
                        consentActive=True,
                        maxSignalAgeMs=body.maxSignalAgeMs,
                        mappings=sorted(mappings, key=lambda item: item.roomId),
                    )
                    self._write(connection, source)
                    update_state(
                        connection,
                        self.policy(source),
                        device_name=source.entityName,
                        room_names={
                            item.roomId: item.roomLabel
                            for item in source.mappings
                        },
                        provider_reachable=True,
                    )
                    return source
        except ApiError:
            raise
        except (
            InvalidTag, UnicodeError, ValueError, TypeError, sqlite3.Error,
            json.JSONDecodeError,
        ):
            raise ApiError("presence_provider_unavailable", 503) from None

    def revoke(
        self, actor, raw, *, update_state, transaction_guard
    ):
        if not callable(update_state) or not callable(transaction_guard):
            raise ValueError("invalid_presence_provider_transaction")
        try:
            body = MqttRoomConsentRevoke.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            with transaction_guard():
                with self._db.transaction() as connection:
                    current_actor = self._actor(connection, actor, admin=True)
                    old = self._read(connection)
                    if (
                        old is None
                        or old.revision != body.expectedRevision
                        or not old.consentActive
                    ):
                        raise ApiError("revision_conflict", 409)
                    revision = old.revision + 1
                    if revision > 2**53 - 1:
                        raise ApiError("revision_conflict", 409)
                    source = old.model_copy(update={
                        "revision": revision,
                        "consentAccountId": actor.id,
                        "consentAccountRevision": current_actor["revision"],
                        "consentActive": False,
                    })
                    update_state(
                        connection, self.policy(old).device.deviceId
                    )
                    self._write(connection, source)
                    return source
        except ApiError:
            raise
        except (
            InvalidTag, UnicodeError, ValueError, TypeError, sqlite3.Error,
            json.JSONDecodeError,
        ):
            raise ApiError("presence_provider_unavailable", 503) from None

    def reserve_observation(self, actor):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            actor_row = self._actor(connection, actor, admin=False)
            source = self._read(connection)
            if source is None:
                raise ApiError("presence_source_not_configured", 409)
            service = self._resolve(connection, source)
            return source, service, actor_row["revision"]

    def assert_observation_current(self, actor, expected):
        source, service, actor_revision = self.reserve_observation(actor)
        if (source, service, actor_revision) != expected:
            raise ApiError("revision_conflict", 409)

    def policy(self, source):
        rooms = [
            PresenceRoom(
                schemaVersion=1, coreId=self._scope.coreId,
                homeId=self._scope.homeId, roomId=item.roomId,
                roomRevision=item.roomRevision,
            )
            for item in source.mappings
        ]
        device_id = _identity(
            "mqtt-room-device", self._scope.coreId, self._scope.homeId
        )
        return PresencePolicy(
            schemaVersion=1,
            coreId=self._scope.coreId,
            homeId=self._scope.homeId,
            homeRevision=self._scope.schemaVersion,
            policyId=_identity("mqtt-room-policy", device_id),
            policyRevision=source.revision,
            device=PresenceDevice(
                schemaVersion=1, coreId=self._scope.coreId,
                homeId=self._scope.homeId, deviceId=device_id,
                deviceRevision=source.revision,
                modelId=_identity("mqtt-room-model", "home-assistant"),
                modelRevision=1,
                consentId=_identity("mqtt-room-consent", source.consentAccountId),
                consentRevision=source.consentAccountRevision,
                consentActive=source.consentActive,
                allowAutomationHandoff=False,
            ),
            sources=[PresenceSource(
                schemaVersion=1,
                sourceId=_identity(
                    "mqtt-room-source", source.serviceId, source.entityUniqueId
                ),
                sourceKind="ha_mqtt_room", sourceRevision=source.revision,
            )],
            rooms=rooms,
            enterConfidencePermille=900,
            exitConfidencePermille=500,
            enterObservations=2,
            exitObservations=2,
            maxSignalAgeMs=source.maxSignalAgeMs,
            active=True,
        )
