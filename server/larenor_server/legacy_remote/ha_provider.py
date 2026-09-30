"""Normal Home Assistant Broadlink provider for bounded legacy remotes.

Home Assistant's Broadlink adapter deliberately owns learned signal bytes.  This
provider stores only exact learned device/command names and never accepts a raw
``b64:`` code.  Broadlink swallows some hardware send failures, so a completed
HA service call is treated as an unknown acknowledgement and is never promoted
to a delivery receipt.
"""

from __future__ import annotations

from datetime import datetime
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import sqlite3
import threading
from typing import Literal

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import Field, model_validator

from ..errors import ApiError, StartupError
from ..home_assistant.read_only_websocket import (
    HomeAssistantReadOnlyWebSocket,
    HomeAssistantWebSocketError,
)
from ..home_resources.models import FrozenModel, Identity, Revision
from ..services.transport import ProbeResponse, ProbeTransportError, ServiceTransport
from ..vault import validate_json_bounds
from .models import (
    RemoteAuthority,
    RemoteCatalog,
    RemoteCatalogItem,
    RemoteCommandDefinition,
    RemoteCommandProfile,
    RemoteDevice,
)
from .schema import source_aad, source_tag


MAX_SOURCES = 16
MAX_BYTES = 65_536
TIMEOUT_SECONDS = 5.0
_ENTITY = re.compile(r"remote\.[a-z0-9_]{1,249}\Z")
_HA_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
_NAME = re.compile(r"[^\x00-\x1f\x7f]{1,128}\Z")


class HomeAssistantRemoteCommand(FrozenModel):
    key: str = Field(pattern=(
        r"^(power_toggle|power_on|power_off|volume_up|volume_down|mute|"
        r"channel_up|channel_down|input_next|menu|back|up|down|left|right|"
        r"select|play|pause|stop)$"
    ))
    commandName: str = Field(min_length=1, max_length=128,
                             pattern=r"^[^\x00-\x1f\x7f]+$")
    maxRepeats: int = Field(ge=1, le=3)

    @model_validator(mode="after")
    def no_raw_signal(self):
        if self.commandName.casefold().startswith("b64:"):
            raise ValueError("raw_remote_code_forbidden")
        return self


class HomeAssistantRemoteSourceRequest(FrozenModel):
    schemaVersion: int = Field(ge=1, le=1)
    expectedRevision: int = Field(ge=0, le=2**63 - 2)
    serviceId: Identity
    expectedServiceRevision: Revision
    name: str = Field(min_length=1, max_length=128,
                      pattern=r"^[^\x00-\x1f\x7f]+$")
    entityId: str = Field(pattern=r"^remote\.[a-z0-9_]{1,249}$")
    learnedDeviceName: str = Field(min_length=1, max_length=128,
                                   pattern=r"^[^\x00-\x1f\x7f]+$")
    protocol: Literal["ir"]
    commands: list[HomeAssistantRemoteCommand] = Field(min_length=1, max_length=32)

    @model_validator(mode="after")
    def unique_commands(self):
        keys = [item.key for item in self.commands]
        names = [item.commandName for item in self.commands]
        if len(keys) != len(set(keys)) or len(names) != len(set(names)):
            raise ValueError("duplicate_remote_command")
        return self


class _SourceStore:
    def __init__(self, database, key, context):
        self._db, self._key = database, key
        self._cipher = AESGCM(key)
        self._core_id, self._home_id = context.coreId, context.homeId

    def _decode(self, row):
        try:
            if (
                row is None
                or re.fullmatch(r"[0-9a-f]{32}", row["source_id"]) is None
                or type(row["revision"]) is not int
                or not 1 <= row["revision"] < 2**63
                or not isinstance(row["nonce"], bytes)
                or len(row["nonce"]) != 12
                or not isinstance(row["ciphertext"], bytes)
                or not 1 <= len(row["ciphertext"]) <= MAX_BYTES
                or not secrets.compare_digest(
                    row["authentication_tag"],
                    source_tag(
                        self._key, self._core_id, self._home_id,
                        row["source_id"], row["revision"], row["nonce"],
                        row["ciphertext"],
                    ),
                )
            ):
                raise ValueError
            raw = self._cipher.decrypt(
                row["nonce"], row["ciphertext"],
                source_aad(
                    self._core_id, self._home_id,
                    row["source_id"], row["revision"],
                ),
            )
            value = json.loads(raw)
            validate_json_bounds(value)
            expected = {
                "schemaVersion", "serviceId", "serviceRevision", "name",
                "entityId", "learnedDeviceName", "protocol", "commands",
                "provenance",
            }
            if type(value) is not dict or set(value) != expected:
                raise ValueError
            request = HomeAssistantRemoteSourceRequest.model_validate({
                "schemaVersion": value["schemaVersion"],
                "expectedRevision": row["revision"] - 1,
                "serviceId": value["serviceId"],
                "expectedServiceRevision": value["serviceRevision"],
                "name": value["name"],
                "entityId": value["entityId"],
                "learnedDeviceName": value["learnedDeviceName"],
                "protocol": value["protocol"],
                "commands": value["commands"],
            })
            provenance = value["provenance"]
            if not isinstance(provenance, str) or re.fullmatch(
                r"[0-9a-f]{64}", provenance
            ) is None:
                raise ValueError
            return {
                "sourceId": row["source_id"],
                "revision": row["revision"],
                "request": request,
                "provenance": provenance,
            }
        except (
            ApiError, InvalidTag, json.JSONDecodeError, TypeError, ValueError,
            UnicodeError, OverflowError,
        ):
            raise ApiError("remote_command_integrity_failed", 503) from None

    def list(self, connection=None):
        owns = connection is None
        if owns:
            manager = self._db.connection()
            connection = manager.__enter__()
        try:
            rows = connection.execute(
                "SELECT * FROM legacy_remote_ha_sources ORDER BY source_id LIMIT ?",
                (MAX_SOURCES + 1,),
            ).fetchall()
            if len(rows) > MAX_SOURCES:
                raise ApiError("remote_command_integrity_failed", 503)
            return [self._decode(row) for row in rows]
        finally:
            if owns:
                manager.__exit__(None, None, None)

    def get(self, source_id, connection=None):
        records = self.list(connection)
        return next((item for item in records if item["sourceId"] == source_id), None)

    def put(self, source_id, revision, request, provenance, connection):
        value = {
            "schemaVersion": 1,
            "serviceId": request.serviceId,
            "serviceRevision": request.expectedServiceRevision,
            "name": request.name,
            "entityId": request.entityId,
            "learnedDeviceName": request.learnedDeviceName,
            "protocol": request.protocol,
            "commands": [item.model_dump(mode="json") for item in request.commands],
            "provenance": provenance,
        }
        plain = json.dumps(
            value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        ).encode("ascii")
        nonce = os.urandom(12)
        ciphertext = self._cipher.encrypt(
            nonce, plain,
            source_aad(self._core_id, self._home_id, source_id, revision),
        )
        tag = source_tag(
            self._key, self._core_id, self._home_id, source_id, revision,
            nonce, ciphertext,
        )
        connection.execute(
            "INSERT INTO legacy_remote_ha_sources VALUES(?,?,?,?,?) "
            "ON CONFLICT(source_id) DO UPDATE SET revision=excluded.revision,"
            "nonce=excluded.nonce,ciphertext=excluded.ciphertext,"
            "authentication_tag=excluded.authentication_tag",
            (source_id, revision, nonce, ciphertext, tag),
        )

    def projection_tag(self, record):
        request = record["request"]
        private_projection = {
            "sourceId": record["sourceId"],
            "revision": record["revision"],
            "serviceId": request.serviceId,
            "serviceRevision": request.expectedServiceRevision,
            "name": request.name,
            "entityId": request.entityId,
            "learnedDeviceName": request.learnedDeviceName,
            "protocol": request.protocol,
            "commands": [
                command.model_dump(mode="json") for command in request.commands
            ],
            "provenance": record["provenance"],
        }
        return hmac.new(
            self._key,
            b"larenor:legacy-remote-ha-source-projection:v1\0"
            + json.dumps(
                private_projection,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=True,
            ).encode("ascii"),
            hashlib.sha256,
        ).hexdigest()

    def validate_storage(self):
        try:
            self.list()
        except (sqlite3.Error, ApiError):
            raise StartupError("legacy_remote_source_storage_invalid") from None


def _identity(*values):
    return hashlib.sha256(json.dumps(values, separators=(",", ":")).encode()).hexdigest()[:32]


def _revision(*values):
    return int(hashlib.sha256(
        json.dumps(values, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()[:13], 16) + 1


class HomeAssistantLegacyRemoteProvider:
    def __init__(
        self, database, auth, settings, key, context, services,
        connection_resolver, home_resources, *, transport_factory=None,
        websocket_factory=None,
    ):
        self._db, self._auth, self._settings = database, auth, settings
        self._context, self._services = context, services
        self._resolve_connection = connection_resolver
        self._home_resources = home_resources
        self._transport_factory = transport_factory or ServiceTransport
        self._websocket_factory = websocket_factory or HomeAssistantReadOnlyWebSocket
        self._store = _SourceStore(database, key, context)
        self._store.validate_storage()
        self._authorities = {}
        self._lock = threading.RLock()

    def _authority(self, account_id, family_id):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            row = connection.execute(
                "SELECT revision,role,disabled,must_change_password FROM users "
                "WHERE id=?", (account_id,),
            ).fetchone()
            family = connection.execute(
                "SELECT revoked_at,expires_at FROM session_families "
                "WHERE id=? AND user_id=?", (family_id, account_id),
            ).fetchone()
            now = self._settings.clock()
            if (
                row is None or family is None or row["disabled"]
                or row["must_change_password"] or row["role"] != "admin"
                or family["revoked_at"] is not None or now >= family["expires_at"]
            ):
                raise ApiError("forbidden", 403)
            self._home_resources._check_context(
                connection, self._context.coreId, self._context.homeId
            )
            home_revision = self._home_resources._state(connection)["revision"]
        return RemoteAuthority(
            schemaVersion=1, coreId=self._context.coreId,
            homeId=self._context.homeId, homeRevision=home_revision,
            accountId=account_id, accountRevision=row["revision"],
            memberRevision=row["revision"], sessionFamilyId=family_id,
            active=True, canControlLegacyRemote=True,
        )

    def resolve_authority(self, account_id):
        with self._lock:
            expected = self._authorities.get(account_id)
        if expected is None:
            return None
        try:
            return self._authority(account_id, expected.sessionFamilyId)
        except ApiError:
            return None

    @staticmethod
    def _headers(service, body=False):
        try:
            token = service.credentials["token"]
            token.encode("latin-1")
        except (KeyError, AttributeError, UnicodeError):
            raise ApiError("remote_provider_unavailable", 503) from None
        headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
        if body:
            headers["Content-Type"] = "application/json"
        return headers

    def _request(self, service, method, path, *, body=None, guard=None):
        transport = None
        try:
            transport = self._transport_factory(
                service.base_url, timeout=TIMEOUT_SECONDS, max_bytes=MAX_BYTES
            )
            response = transport.request(
                method, path, headers=self._headers(service, body is not None),
                body=body, before_send=guard,
            )
            if (
                not isinstance(response, ProbeResponse) or response.status != 200
                or not isinstance(response.body, bytes)
                or len(response.body) > MAX_BYTES
            ):
                raise ValueError
            types = [
                value.split(";", 1)[0].strip().lower()
                for name, value in response.headers
                if name.lower() == "content-type"
            ]
            if types != ["application/json"]:
                raise ValueError
            return response.body
        except (ProbeTransportError, OSError, TypeError, ValueError):
            raise ApiError("remote_provider_unavailable", 503) from None
        finally:
            if transport is not None:
                transport.close()

    @staticmethod
    def _json(raw):
        def pairs(items):
            result = {}
            for key, value in items:
                if key in result:
                    raise ValueError
                result[key] = value
            return result
        try:
            value = json.loads(
                raw.decode("utf-8"), object_pairs_hook=pairs,
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
            )
            validate_json_bounds(value)
            return value
        except (ApiError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
            raise ApiError("remote_provider_unavailable", 503) from None

    def _state(self, service, entity_id, guard=None):
        value = self._json(self._request(
            service, "GET", "/api/states/" + entity_id, guard=guard
        ))
        try:
            updated = value["last_updated"]
            parsed = datetime.fromisoformat(updated.replace("Z", "+00:00"))
            if (
                type(value) is not dict or value["entity_id"] != entity_id
                or value["state"] not in {"on", "off", "unavailable"}
                or type(value["attributes"]) is not dict
                or not isinstance(updated, str) or len(updated) > 40
                or parsed.tzinfo is None or parsed.utcoffset() is None
                or not math.isfinite(parsed.timestamp())
            ):
                raise ValueError
            return value
        except (AttributeError, KeyError, TypeError, ValueError):
            raise ApiError("remote_provider_unavailable", 503) from None

    def _provenance(self, service, entity_id, guard=None):
        try:
            client = self._websocket_factory(service)
            with client.session(
                timeout=TIMEOUT_SECONDS, before_io=guard, after_io=guard
            ) as session:
                entities = session.list_entity_registry()
                devices = session.list_device_registry()
        except (HomeAssistantWebSocketError, OSError, TypeError, ValueError):
            raise ApiError("remote_provider_unavailable", 503) from None
        matches = [item for item in entities if item.get("entity_id") == entity_id]
        if len(matches) != 1:
            raise ApiError("remote_provider_unverified", 409)
        entity = matches[0]
        try:
            config_entry = entity["config_entry_id"]
            device_id = entity["device_id"]
            unique_id = entity["unique_id"]
            found = [item for item in devices if item.get("id") == device_id]
            device = found[0] if len(found) == 1 else None
            manufacturer = None if device is None else device.get("manufacturer")
            model = None if device is None else device.get("model")
            if (
                entity.get("platform") != "broadlink"
                or entity.get("disabled_by") is not None
                or _HA_ID.fullmatch(config_entry) is None
                or _HA_ID.fullmatch(device_id) is None
                or not isinstance(unique_id, str) or not 1 <= len(unique_id) <= 256
                or device is None or config_entry not in device.get("config_entries", [])
                or not isinstance(manufacturer, str)
                or "broadlink" not in manufacturer.casefold()
                or not isinstance(model, str) or not _NAME.fullmatch(model)
            ):
                raise ValueError
            record = {
                "entityId": entity_id, "configEntryId": config_entry,
                "deviceId": device_id, "uniqueId": unique_id,
                "manufacturer": manufacturer, "model": model,
            }
            digest = hashlib.sha256(json.dumps(
                record, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
            ).encode("ascii")).hexdigest()
            return digest
        except (KeyError, TypeError, ValueError):
            raise ApiError("remote_provider_unverified", 409) from None

    def configure(self, actor, core_id, home_id, source_id, raw):
        if (core_id, home_id) != (self._context.coreId, self._context.homeId):
            raise ApiError("not_found", 404)
        if re.fullmatch(r"[0-9a-f]{32}", source_id or "") is None:
            raise ApiError("invalid_request")
        request = HomeAssistantRemoteSourceRequest.model_validate(raw)
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            self._services._assert_admin(connection, actor)
            current = self._store.get(source_id, connection)
            revision = 0 if current is None else current["revision"]
            if revision != request.expectedRevision:
                raise ApiError("revision_conflict", 409)
            service = self._resolve_connection(
                connection, request.serviceId, request.expectedServiceRevision
            )
        provenance = self._provenance(service, request.entityId)
        state = self._state(service, request.entityId)
        if state["state"] != "on":
            raise ApiError("remote_provider_unverified", 409)
        with self._db.transaction() as connection:
            self._services._assert_admin(connection, actor)
            service = self._resolve_connection(
                connection, request.serviceId, request.expectedServiceRevision
            )
            current = self._store.get(source_id, connection)
            revision = 0 if current is None else current["revision"]
            if revision != request.expectedRevision:
                raise ApiError("revision_conflict", 409)
            next_revision = revision + 1
            if current is None and len(self._store.list(connection)) >= MAX_SOURCES:
                raise ApiError("service_limit_reached", 409)
            self._store.put(
                source_id, next_revision, request, provenance, connection
            )
        accepted = self._store.get(source_id)
        if accepted is None or accepted["revision"] != next_revision:
            raise ApiError("remote_command_integrity_failed", 503)
        return {
            "schemaVersion": 1,
            "sourceId": source_id,
            "revision": next_revision,
            "configurationTag": self._store.projection_tag(accepted),
        }

    def sources(self, actor, core_id, home_id):
        if (core_id, home_id) != (self._context.coreId, self._context.homeId):
            raise ApiError("not_found", 404)
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            self._services._assert_admin(connection, actor)
            records = self._store.list(connection)
        return {
            "schemaVersion": 1,
            "sources": [{
                "sourceId": item["sourceId"], "revision": item["revision"],
                "serviceId": item["request"].serviceId,
                "serviceRevision": item["request"].expectedServiceRevision,
                "name": item["request"].name,
                "entityId": item["request"].entityId,
                "protocol": item["request"].protocol,
                "commandKeys": [command.key for command in item["request"].commands],
                "configurationTag": self._store.projection_tag(item),
            } for item in records],
        }

    def _resolved(self, source_id):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            source = self._store.get(source_id, connection)
            if source is None:
                raise ApiError("remote_provider_unavailable", 503)
            request = source["request"]
            service = self._resolve_connection(
                connection, request.serviceId, request.expectedServiceRevision
            )
        provenance = self._provenance(service, request.entityId)
        state = self._state(service, request.entityId)
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            after_source = self._store.get(source_id, connection)
            after_service = self._resolve_connection(
                connection, request.serviceId, request.expectedServiceRevision
            )
        if after_source != source or after_service != service:
            raise ApiError("revision_conflict", 409)
        if provenance != source["provenance"]:
            raise ApiError("remote_provider_unverified", 409)
        return source, service, state

    def _models(self, source):
        request, revision = source["request"], source["revision"]
        provider_id = _identity("ha-service", request.serviceId)
        bridge_id = _identity("ha-broadlink", request.serviceId, request.entityId)
        device_id = _identity("legacy-device", source["sourceId"])
        profile_id = _identity("legacy-profile", source["sourceId"])
        code_set_id = _identity("legacy-code-set", source["sourceId"])
        profile_revision = _revision(revision, source["provenance"], [
            item.model_dump(mode="json") for item in request.commands
        ])
        device = RemoteDevice(
            schemaVersion=1, coreId=self._context.coreId,
            homeId=self._context.homeId, deviceId=device_id, revision=revision,
            providerType="home_assistant", providerId=provider_id,
            providerRevision=request.expectedServiceRevision,
            bridgeId=bridge_id, bridgeRevision=revision,
            protocol=request.protocol,
            stored=True, reachable=True, providerVerified=True,
        )
        profile = RemoteCommandProfile(
            schemaVersion=1, coreId=self._context.coreId,
            homeId=self._context.homeId, profileId=profile_id,
            revision=profile_revision, deviceId=device_id,
            expectedDeviceRevision=revision, providerId=provider_id,
            expectedProviderRevision=request.expectedServiceRevision,
            codeSetId=code_set_id, codeSetRevision=profile_revision,
            protocol=request.protocol, commands=[RemoteCommandDefinition(
                schemaVersion=1,
                bindingId=_identity(
                    "legacy-binding", source["sourceId"], item.key,
                    item.commandName,
                ),
                key=item.key, maxRepeats=item.maxRepeats, maxHoldMs=0,
            ) for item in request.commands],
        )
        return device, profile

    def catalog(self, actor, core_id, home_id):
        if (core_id, home_id) != (self._context.coreId, self._context.homeId):
            raise ApiError("not_found", 404)
        authority = self._authority(actor.id, actor.family_id)
        with self._lock:
            self._authorities[actor.id] = authority
        items = []
        for record in self._store.list():
            source, _service, state = self._resolved(record["sourceId"])
            device, profile = self._models(source)
            if state["state"] != "on":
                device = device.model_copy(update={"reachable": False})
            items.append(RemoteCatalogItem(
                schemaVersion=1, name=source["request"].name,
                device=device, profile=profile,
            ))
        return RemoteCatalog(schemaVersion=1, authority=authority, items=items)

    def _source_for_device(self, device_id):
        for source in self._store.list():
            device, profile = self._models(source)
            if device.deviceId == device_id:
                return source, device, profile
        return None

    def resolve_device(self, device_id):
        found = self._source_for_device(device_id)
        if found is None:
            return None
        source, device, _profile = found
        try:
            _current, _service, state = self._resolved(source["sourceId"])
        except ApiError:
            return None
        return device.model_copy(update={"reachable": state["state"] == "on"})

    def resolve_profile(self, profile_id):
        for source in self._store.list():
            _device, profile = self._models(source)
            if profile.profileId == profile_id:
                try:
                    self._resolved(source["sourceId"])
                except ApiError:
                    return None
                return profile
        return None

    def emit(self, command):
        found = self._source_for_device(command.deviceId)
        if found is None or command.holdMs != 0:
            raise ApiError("remote_provider_unverified", 409)
        source, device, profile = found
        definition = next(
            (item for item in profile.commands if item.bindingId == command.bindingId),
            None,
        )
        configured = next(
            (item for item in source["request"].commands if item.key == command.key),
            None,
        )
        if (
            definition is None or configured is None
            or definition.key != command.key
            or command.repeats > configured.maxRepeats
            or (command.providerId, command.providerRevision,
                command.bridgeId, command.bridgeRevision,
                command.deviceRevision, command.profileId,
                command.profileRevision, command.codeSetId,
                command.codeSetRevision)
            != (device.providerId, device.providerRevision,
                device.bridgeId, device.bridgeRevision, device.revision,
                profile.profileId, profile.revision, profile.codeSetId,
                profile.codeSetRevision)
        ):
            raise ApiError("revision_conflict", 409)
        expected = RemoteAuthority(
            schemaVersion=1, coreId=command.coreId, homeId=command.homeId,
            homeRevision=command.homeRevision, accountId=command.accountId,
            accountRevision=command.accountRevision,
            memberRevision=command.memberRevision,
            sessionFamilyId=command.sessionFamilyId, active=True,
            canControlLegacyRemote=True,
        )
        if self.resolve_authority(command.accountId) != expected:
            raise ApiError("revision_conflict", 409)
        current, service, before = self._resolved(source["sourceId"])
        if current != source or before["state"] != "on":
            raise ApiError("revision_conflict", 409)
        body = json.dumps({
            "entity_id": source["request"].entityId,
            "device": source["request"].learnedDeviceName,
            "command": configured.commandName,
            "num_repeats": command.repeats,
            "delay_secs": 0.4,
        }, separators=(",", ":")).encode("ascii")
        raw = self._request(
            service, "POST", "/api/services/remote/send_command", body=body,
            guard=lambda: self._guard_emit(expected, source),
        )
        if self._json(raw) != []:
            raise ApiError("remote_provider_unavailable", 503)
        after_source, _service, after = self._resolved(source["sourceId"])
        if after_source != source or after["state"] != "on":
            raise ApiError("revision_conflict", 409)
        # HA/Broadlink exposes no packet-level acknowledgement.  Raising here
        # makes the already durable manager result uncertain without replay.
        raise ApiError("remote_delivery_unverifiable", 503)

    def _guard_emit(self, authority, source):
        if self.resolve_authority(authority.accountId) != authority:
            raise ApiError("revision_conflict", 409)
        current, _service, state = self._resolved(source["sourceId"])
        if current != source or state["state"] != "on":
            raise ApiError("revision_conflict", 409)
