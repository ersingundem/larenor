"""Verified Home Assistant Fronius minimum-reserve control.

The official integration exposes battery setpoints as percentages.  It does
not expose an absolute watt command, so this adapter deliberately implements
only the minimum-reserve control.  A command is durable before the one allowed
``number.set_value`` call and an unknown acknowledgement is never replayed.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import hashlib
import hmac
import json
import math
import re
import secrets
import sqlite3
import threading
import time

from ..errors import ApiError, StartupError
from ..home_assistant.read_only_websocket import (
    HomeAssistantReadOnlyWebSocket,
    HomeAssistantWebSocketError,
)
from ..services.transport import ProbeResponse, ProbeTransportError, ServiceTransport
from ..vault import validate_json_bounds


MAX_BINDINGS = 16
MAX_EFFECTS = 1_000
MAX_BYTES = 65_536
TIMEOUT_SECONDS = 5.0
_IDENTITY = re.compile(r"[0-9a-f]{32}\Z")
_ENTITY = re.compile(r"number\.[a-z0-9_]{1,249}\Z")
_HA_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
_RESERVE_SUFFIX = "-modbus-battery_minimum_reserve"

TABLES = {
    "fronius_reserve_bindings": """CREATE TABLE fronius_reserve_bindings (
        service_id TEXT PRIMARY KEY,
        service_revision INTEGER NOT NULL CHECK(service_revision > 0),
        binding_revision INTEGER NOT NULL CHECK(binding_revision > 0),
        battery_id TEXT NOT NULL,
        battery_provider_revision INTEGER NOT NULL CHECK(battery_provider_revision > 0),
        entity_id TEXT NOT NULL,
        config_entry_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        unique_id TEXT NOT NULL,
        manufacturer TEXT NOT NULL,
        model TEXT NOT NULL,
        accepted_at REAL NOT NULL,
        record_hash TEXT NOT NULL)""",
    "fronius_reserve_effects": """CREATE TABLE fronius_reserve_effects (
        request_id TEXT PRIMARY KEY,
        command_digest TEXT NOT NULL,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        home_revision INTEGER NOT NULL CHECK(home_revision > 0),
        account_id TEXT NOT NULL,
        account_revision INTEGER NOT NULL CHECK(account_revision > 0),
        member_revision INTEGER NOT NULL CHECK(member_revision > 0),
        session_family_id TEXT NOT NULL,
        inverter_id TEXT NOT NULL,
        inverter_revision INTEGER NOT NULL CHECK(inverter_revision > 0),
        service_id TEXT NOT NULL,
        service_revision INTEGER NOT NULL CHECK(service_revision > 0),
        binding_revision INTEGER NOT NULL CHECK(binding_revision > 0),
        battery_id TEXT NOT NULL,
        battery_revision INTEGER NOT NULL CHECK(battery_revision > 0),
        battery_provider_revision INTEGER NOT NULL CHECK(battery_provider_revision > 0),
        input_digest TEXT NOT NULL,
        target_reserve_percent INTEGER NOT NULL CHECK(target_reserve_percent BETWEEN 0 AND 100),
        before_reserve_percent INTEGER NOT NULL CHECK(before_reserve_percent BETWEEN 0 AND 100),
        before_updated_at TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('reserved','uncertain','verified','mismatch')),
        observed_reserve_percent INTEGER,
        observed_updated_at TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        record_hash TEXT NOT NULL)""",
}


def migrate_fronius_reserve_control(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='fronius_reserve_control_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE name IN (?,?)",
            tuple(TABLES),
        ).fetchall()
        actual = {row["name"]: row for row in rows}
        if marker is None:
            if actual:
                raise ValueError
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('fronius_reserve_control_schema','1')"
            )
            return
        if (
            marker["value"] != "1"
            or set(actual) != set(TABLES)
            or any(
                row["type"] != "table"
                or " ".join(row["sql"].split()) != " ".join(TABLES[name].split())
                for name, row in actual.items()
            )
        ):
            raise ValueError
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("fronius_reserve_storage_invalid") from None


@dataclass(frozen=True)
class FroniusReserveBinding:
    service_id: str
    service_revision: int
    binding_revision: int
    battery_id: str
    battery_provider_revision: int
    entity_id: str
    config_entry_id: str
    device_id: str
    unique_id: str
    manufacturer: str
    model: str


@dataclass(frozen=True)
class FroniusReserveState:
    percent: int
    updated_at: str


@dataclass(frozen=True)
class FroniusReserveReceipt:
    request_id: str
    status: str
    target_reserve_percent: int
    observed_reserve_percent: int | None
    binding_revision: int


class FroniusReserveControl:
    def __init__(
        self,
        database,
        *,
        audit_key: bytes,
        clock,
        services,
        connection_resolver,
        transport_factory=None,
        websocket_factory=None,
    ):
        if (
            not isinstance(audit_key, bytes)
            or len(audit_key) < 32
            or not callable(clock)
            or not callable(connection_resolver)
        ):
            raise ValueError("invalid_fronius_reserve_control")
        self.database = database
        self._key = audit_key
        self._clock = clock
        self._services = services
        self._connection_resolver = connection_resolver
        self._transport_factory = transport_factory or ServiceTransport
        self._websocket_factory = websocket_factory or HomeAssistantReadOnlyWebSocket
        self._lock = threading.RLock()

    def _hash(self, domain: bytes, values) -> str:
        raw = json.dumps(
            values, separators=(",", ":"), ensure_ascii=True, allow_nan=False
        ).encode("ascii")
        return hmac.new(
            self._key, b"larenor:fronius-reserve:v1:" + domain + b"\0" + raw,
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _binding_fields(row):
        return tuple(
            row[name]
            for name in (
                "service_id", "service_revision", "binding_revision", "battery_id",
                "battery_provider_revision", "entity_id", "config_entry_id",
                "device_id", "unique_id", "manufacturer", "model", "accepted_at",
            )
        )

    @staticmethod
    def _effect_fields(row, **changes):
        names = (
            "request_id", "command_digest", "core_id", "home_id", "home_revision",
            "account_id", "account_revision", "member_revision", "session_family_id",
            "inverter_id", "inverter_revision", "service_id", "service_revision",
            "binding_revision", "battery_id", "battery_revision",
            "battery_provider_revision", "input_digest", "target_reserve_percent",
            "before_reserve_percent", "before_updated_at", "status",
            "observed_reserve_percent", "observed_updated_at", "created_at", "updated_at",
        )
        return tuple(changes.get(name, row[name]) for name in names)

    def _decode_binding(self, row) -> FroniusReserveBinding:
        try:
            fields = self._binding_fields(row)
            if not secrets.compare_digest(
                row["record_hash"], self._hash(b"binding", fields)
            ):
                raise ValueError
            value = FroniusReserveBinding(*fields[:-1])
            if (
                _IDENTITY.fullmatch(value.service_id) is None
                or _IDENTITY.fullmatch(value.battery_id) is None
                or _ENTITY.fullmatch(value.entity_id) is None
                or _HA_ID.fullmatch(value.config_entry_id) is None
                or _HA_ID.fullmatch(value.device_id) is None
                or not value.unique_id.endswith(_RESERVE_SUFFIX)
                or not 1 <= len(value.unique_id) <= 256
                or not 1 <= len(value.manufacturer) <= 128
                or "fronius" not in value.manufacturer.casefold()
                or not 1 <= len(value.model) <= 128
                or any(
                    type(item) is not int or not 1 <= item < 2**63
                    for item in (
                        value.service_revision, value.binding_revision,
                        value.battery_provider_revision,
                    )
                )
                or type(row["accepted_at"]) not in (int, float)
                or not math.isfinite(row["accepted_at"])
                or row["accepted_at"] < 0
            ):
                raise ValueError
            return value
        except (KeyError, TypeError, ValueError):
            raise StartupError("fronius_reserve_storage_invalid") from None

    def _verify_effect(self, row) -> None:
        try:
            fields = self._effect_fields(row)
            observed = row["observed_reserve_percent"]
            observed_at = row["observed_updated_at"]
            if (
                _IDENTITY.fullmatch(row["request_id"]) is None
                or not re.fullmatch(r"[0-9a-f]{64}", row["command_digest"])
                or any(
                    _IDENTITY.fullmatch(row[name]) is None
                    for name in (
                        "core_id", "home_id", "account_id", "session_family_id",
                        "inverter_id", "service_id", "battery_id",
                    )
                )
                or not re.fullmatch(r"[0-9a-f]{64}", row["input_digest"])
                or row["status"] in {"reserved", "uncertain"}
                and (observed is not None or observed_at is not None)
                or row["status"] in {"verified", "mismatch"}
                and (
                    type(observed) is not int or not 0 <= observed <= 100
                    or not isinstance(observed_at, str)
                )
                or row["status"] == "verified"
                and observed != row["target_reserve_percent"]
                or not secrets.compare_digest(
                    row["record_hash"], self._hash(b"effect", fields)
                )
            ):
                raise ValueError
        except (KeyError, TypeError, ValueError):
            raise StartupError("fronius_reserve_storage_invalid") from None

    def validate_storage(self) -> None:
        try:
            with self.database.connection() as connection:
                bindings = connection.execute(
                    "SELECT * FROM fronius_reserve_bindings ORDER BY service_id LIMIT ?",
                    (MAX_BINDINGS + 1,),
                ).fetchall()
                effects = connection.execute(
                    "SELECT * FROM fronius_reserve_effects ORDER BY request_id LIMIT ?",
                    (MAX_EFFECTS + 1,),
                ).fetchall()
            if len(bindings) > MAX_BINDINGS or len(effects) > MAX_EFFECTS:
                raise ValueError
            for row in bindings:
                self._decode_binding(row)
            for row in effects:
                self._verify_effect(row)
        except (sqlite3.Error, StartupError, ValueError):
            raise StartupError("fronius_reserve_storage_invalid") from None

    @staticmethod
    def _headers(service, *, body=False):
        try:
            token = service.credentials["token"]
            token.encode("latin-1")
        except (KeyError, AttributeError, UnicodeError):
            raise ApiError("energy_provider_unavailable", 503) from None
        result = {"Authorization": "Bearer " + token, "Accept": "application/json"}
        if body:
            result["Content-Type"] = "application/json"
        return result

    @staticmethod
    def _json(response, *, collection=False):
        if (
            not isinstance(response, ProbeResponse)
            or response.status != 200
            or not isinstance(response.body, bytes)
            or len(response.body) > MAX_BYTES
        ):
            raise ApiError("energy_provider_unavailable", 503)
        types = [
            value.split(";", 1)[0].strip().lower()
            for name, value in response.headers
            if name.lower() == "content-type"
        ]
        if types != ["application/json"]:
            raise ApiError("energy_provider_unavailable", 503)
        try:
            value = json.loads(
                response.body.decode("utf-8"),
                object_pairs_hook=lambda pairs: FroniusReserveControl._unique(pairs),
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
            )
            validate_json_bounds(value)
            expected = list if collection else dict
            if type(value) is not expected:
                raise ValueError
            return value
        except (ValueError, TypeError, UnicodeError, json.JSONDecodeError):
            raise ApiError("energy_provider_unavailable", 503) from None

    @staticmethod
    def _unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError
            result[key] = value
        return result

    def _request(self, service, method, path, *, body=None, before_send=None):
        transport = None
        try:
            transport = self._transport_factory(
                service.base_url, timeout=TIMEOUT_SECONDS, max_bytes=MAX_BYTES
            )
            return transport.request(
                method,
                path,
                headers=self._headers(service, body=body is not None),
                body=body,
                before_send=before_send,
            )
        except ApiError:
            raise
        except (ProbeTransportError, OSError, TypeError, ValueError):
            raise ApiError("energy_provider_unavailable", 503) from None
        finally:
            if transport is not None:
                transport.close()

    @staticmethod
    def _instant(value):
        if not isinstance(value, str) or not 1 <= len(value) <= 40:
            raise ApiError("energy_provider_unavailable", 503)
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            raise ApiError("energy_provider_unavailable", 503) from None
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ApiError("energy_provider_unavailable", 503)
        return parsed

    def _state(self, service, entity_id) -> FroniusReserveState:
        value = self._json(self._request(service, "GET", "/api/states/" + entity_id))
        try:
            attrs = value["attributes"]
            percent = int(value["state"])
            updated = value["last_updated"]
            if (
                value["entity_id"] != entity_id
                or str(percent) != value["state"]
                or not 0 <= percent <= 100
                or type(attrs) is not dict
                or attrs.get("min") != 0
                or attrs.get("max") != 100
                or attrs.get("step") != 1
                or attrs.get("unit_of_measurement") != "%"
            ):
                raise ValueError
            self._instant(updated)
            return FroniusReserveState(percent, updated)
        except (KeyError, TypeError, ValueError):
            raise ApiError("energy_provider_unavailable", 503) from None

    def _registries(self, service):
        try:
            client = self._websocket_factory(service)
            with client.session(timeout=TIMEOUT_SECONDS) as session:
                entities = session.list_entity_registry()
                devices = session.list_device_registry()
            return entities, devices
        except (HomeAssistantWebSocketError, OSError, TypeError, ValueError):
            raise ApiError("energy_provider_unavailable", 503) from None

    @staticmethod
    def _provenance(entities, devices, entity_id):
        matches = [item for item in entities if item.get("entity_id") == entity_id]
        if len(matches) != 1:
            raise ApiError("revision_conflict", 409)
        entity = matches[0]
        try:
            config_entry_id = entity["config_entry_id"]
            device_id = entity["device_id"]
            unique_id = entity["unique_id"]
            if (
                entity.get("platform") != "fronius"
                or entity.get("disabled_by") is not None
                or _HA_ID.fullmatch(config_entry_id) is None
                or _HA_ID.fullmatch(device_id) is None
                or not isinstance(unique_id, str)
                or not unique_id.endswith(_RESERVE_SUFFIX)
                or len(unique_id) > 256
            ):
                raise ValueError
            found = [item for item in devices if item.get("id") == device_id]
            if len(found) != 1:
                raise ValueError
            device = found[0]
            entries = device.get("config_entries")
            manufacturer, model = device.get("manufacturer"), device.get("model")
            if (
                not isinstance(entries, list)
                or config_entry_id not in entries
                or not isinstance(manufacturer, str)
                or "fronius" not in manufacturer.casefold()
                or not isinstance(model, str)
                or not 1 <= len(manufacturer) <= 128
                or not 1 <= len(model) <= 128
            ):
                raise ValueError
            return config_entry_id, device_id, unique_id, manufacturer, model
        except (KeyError, TypeError, ValueError):
            raise ApiError("revision_conflict", 409) from None

    def accept_binding(
        self,
        actor,
        *,
        service_id,
        service_revision,
        expected_binding_revision,
        battery_id,
        battery_provider_revision,
        entity_id,
    ) -> int:
        if (
            _IDENTITY.fullmatch(service_id or "") is None
            or _IDENTITY.fullmatch(battery_id or "") is None
            or _ENTITY.fullmatch(entity_id or "") is None
            or type(service_revision) is not int
            or type(expected_binding_revision) is not int
            or not 0 <= expected_binding_revision < 2**63 - 1
            or type(battery_provider_revision) is not int
            or not 1 <= service_revision < 2**63
            or not 1 <= battery_provider_revision < 2**63
        ):
            raise ApiError("invalid_request")
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            self._services._assert_admin(connection, actor)
            service = self._connection_resolver(
                connection, service_id, service_revision
            )
        entities, devices = self._registries(service)
        provenance = self._provenance(entities, devices, entity_id)
        self._state(service, entity_id)
        now = self._clock()
        with self.database.transaction() as connection:
            self._services._assert_admin(connection, actor)
            self._connection_resolver(connection, service_id, service_revision)
            row = connection.execute(
                "SELECT * FROM fronius_reserve_bindings WHERE service_id=?",
                (service_id,),
            ).fetchone()
            try:
                current = 0 if row is None else self._decode_binding(row).binding_revision
            except StartupError:
                raise ApiError("energy_provider_unavailable", 503) from None
            if current != expected_binding_revision:
                raise ApiError("revision_conflict", 409)
            if row is None and connection.execute(
                "SELECT COUNT(*) FROM fronius_reserve_bindings"
            ).fetchone()[0] >= MAX_BINDINGS:
                raise ApiError("service_limit_reached", 409)
            revision = current + 1
            fields = (
                service_id, service_revision, revision, battery_id,
                battery_provider_revision, entity_id, *provenance, now,
            )
            connection.execute(
                "INSERT INTO fronius_reserve_bindings VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(service_id) DO UPDATE SET "
                "service_revision=excluded.service_revision,"
                "binding_revision=excluded.binding_revision,battery_id=excluded.battery_id,"
                "battery_provider_revision=excluded.battery_provider_revision,"
                "entity_id=excluded.entity_id,config_entry_id=excluded.config_entry_id,"
                "device_id=excluded.device_id,unique_id=excluded.unique_id,"
                "manufacturer=excluded.manufacturer,model=excluded.model,"
                "accepted_at=excluded.accepted_at,record_hash=excluded.record_hash",
                fields + (self._hash(b"binding", fields),),
            )
        return revision

    def _binding(self, *, battery_id, battery_provider_revision):
        with self.database.connection() as connection:
            rows = connection.execute(
                "SELECT * FROM fronius_reserve_bindings ORDER BY service_id LIMIT 2"
            ).fetchall()
            if len(rows) != 1:
                raise ApiError("energy_provider_unavailable", 503)
            binding = self._decode_binding(rows[0])
            if (
                binding.battery_id != battery_id
                or binding.battery_provider_revision != battery_provider_revision
            ):
                raise ApiError("revision_conflict", 409)
            service = self._connection_resolver(
                connection, binding.service_id, binding.service_revision
            )
        return binding, service

    def _check_registry(self, binding, service):
        entities, devices = self._registries(service)
        if self._provenance(entities, devices, binding.entity_id) != (
            binding.config_entry_id, binding.device_id, binding.unique_id,
            binding.manufacturer, binding.model,
        ):
            raise ApiError("revision_conflict", 409)

    def capability(self, inputs, base):
        try:
            binding, service = self._binding(
                battery_id=inputs.battery.resourceId,
                battery_provider_revision=inputs.battery.providerRevision,
            )
            self._check_registry(binding, service)
        except (ApiError, StartupError):
            return base.model_copy(
                update={
                    "writable": False,
                    "canSetReserve": False,
                    "controlSemantics": "none",
                }
            )
        inverter_id = hashlib.sha256(
            (binding.service_id + ":" + binding.device_id).encode("ascii")
        ).hexdigest()[:32]
        revision = int(hashlib.sha256(
            json.dumps(
                [base.revision, binding.binding_revision],
                separators=(",", ":"),
            ).encode("ascii")
        ).hexdigest()[:15], 16) + 1
        return base.model_copy(
            update={
                "inverterId": inverter_id,
                "revision": revision,
                "canCharge": False,
                "canDischarge": False,
                "writable": True,
                "canSetReserve": True,
                "controlSemantics": "reserve_percent",
            }
        )

    @staticmethod
    def _command_values(
        authority, inputs, capability, request_id, input_digest, target
    ):
        return [
            request_id, authority.coreId, authority.homeId, authority.accountId,
            authority.sessionFamilyId, capability.inverterId, capability.revision,
            inputs.battery.resourceId, inputs.battery.revision,
            inputs.battery.providerRevision, input_digest, target,
        ]

    def _digest(self, values):
        return self._hash(b"command", values)

    @staticmethod
    def _stored_command_values(row):
        return [
            row["request_id"], row["core_id"], row["home_id"],
            row["account_id"], row["session_family_id"], row["inverter_id"],
            row["inverter_revision"], row["battery_id"], row["battery_revision"],
            row["battery_provider_revision"], row["input_digest"],
            row["target_reserve_percent"],
        ]

    def _assert_current_effect(self, row, guard):
        authority, inputs, _digest, capability = guard()
        if (
            row["command_digest"]
            != self._digest(self._stored_command_values(row))
            or row["core_id"] != authority.coreId
            or row["home_id"] != authority.homeId
            or row["home_revision"] != authority.homeRevision
            or row["account_id"] != authority.accountId
            or row["account_revision"] != authority.accountRevision
            or row["member_revision"] != authority.memberRevision
            or row["session_family_id"] != authority.sessionFamilyId
            or row["inverter_id"] != capability.inverterId
            or row["inverter_revision"] != capability.revision
            or row["battery_id"] != inputs.battery.resourceId
            or row["battery_provider_revision"]
            != inputs.battery.providerRevision
            or row["target_reserve_percent"]
            != inputs.reserve.backupReservePercent
            or not capability.writable
            or not capability.canSetReserve
            or capability.controlSemantics != "reserve_percent"
        ):
            raise ApiError("revision_conflict", 409)

    def apply(
        self,
        authority,
        inputs,
        capability,
        *,
        request_id,
        input_digest,
        target_reserve_percent,
        guard,
    ):
        if (
            _IDENTITY.fullmatch(request_id or "") is None
            or type(target_reserve_percent) is not int
            or not 0 <= target_reserve_percent <= 100
            or target_reserve_percent != inputs.reserve.backupReservePercent
            or not capability.writable
            or not capability.canSetReserve
            or capability.controlSemantics != "reserve_percent"
        ):
            raise ApiError("invalid_request")
        values = self._command_values(
            authority, inputs, capability, request_id, input_digest,
            target_reserve_percent,
        )
        digest = self._digest(values)
        binding, service = self._binding(
            battery_id=inputs.battery.resourceId,
            battery_provider_revision=inputs.battery.providerRevision,
        )
        with self._lock:
            def current_guard():
                current_authority, current_inputs, current_digest, current_capability = guard()
                if (
                    current_authority != authority
                    or current_inputs.battery.resourceId != inputs.battery.resourceId
                    or current_inputs.battery.providerRevision != inputs.battery.providerRevision
                    or current_inputs.reserve != inputs.reserve
                    or current_digest != input_digest
                    or current_capability != capability
                ):
                    raise ApiError("revision_conflict", 409)
                current_binding, current_service = self._binding(
                    battery_id=current_inputs.battery.resourceId,
                    battery_provider_revision=current_inputs.battery.providerRevision,
                )
                if current_binding != binding:
                    raise ApiError("revision_conflict", 409)
                self._check_registry(current_binding, current_service)

            current_guard()
            with self.database.connection() as connection:
                row = connection.execute(
                    "SELECT * FROM fronius_reserve_effects WHERE request_id=?",
                    (request_id,),
                ).fetchone()
            if row is not None:
                self._verify_effect(row)
                if row["command_digest"] != digest:
                    raise ApiError("idempotency_conflict", 409)
                return self._reconcile(row, binding, service, guard)
            before = self._state(service, binding.entity_id)
            current_guard()
            if before.percent == target_reserve_percent:
                status, observed, observed_at = "verified", before.percent, before.updated_at
            else:
                status, observed, observed_at = "reserved", None, None
            now = self._clock()
            fields = (
                request_id, digest, authority.coreId, authority.homeId,
                authority.homeRevision, authority.accountId,
                authority.accountRevision, authority.memberRevision,
                authority.sessionFamilyId, capability.inverterId,
                capability.revision, binding.service_id,
                binding.service_revision, binding.binding_revision,
                inputs.battery.resourceId, inputs.battery.revision,
                inputs.battery.providerRevision, input_digest,
                target_reserve_percent, before.percent, before.updated_at, status,
                observed, observed_at, now, now,
            )
            with self.database.transaction() as connection:
                if connection.execute(
                    "SELECT COUNT(*) FROM fronius_reserve_effects"
                ).fetchone()[0] >= MAX_EFFECTS:
                    raise ApiError("rate_limited", 429)
                connection.execute(
                    "INSERT INTO fronius_reserve_effects VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    fields + (self._hash(b"effect", fields),),
                )
            if status == "verified":
                return FroniusReserveReceipt(
                    request_id, status, target_reserve_percent, observed,
                    binding.binding_revision,
                )
            current_authority, current_inputs, current_digest, current_capability = guard()
            if (
                current_authority != authority
                or current_inputs.battery.resourceId != inputs.battery.resourceId
                or current_inputs.battery.providerRevision
                != inputs.battery.providerRevision
                or current_inputs.reserve != inputs.reserve
                or current_digest != input_digest
                or current_capability != capability
            ):
                raise ApiError("revision_conflict", 409)
            current_binding, service = self._binding(
                battery_id=current_inputs.battery.resourceId,
                battery_provider_revision=current_inputs.battery.providerRevision,
            )
            if current_binding != binding:
                raise ApiError("revision_conflict", 409)
            body = json.dumps(
                {"entity_id": binding.entity_id, "value": target_reserve_percent},
                separators=(",", ":"),
            ).encode("ascii")
            try:
                response = self._request(
                    service, "POST", "/api/services/number/set_value", body=body,
                    before_send=current_guard,
                )
                self._json(response, collection=True)
                deadline = time.monotonic() + 4.0
                while True:
                    after = self._state(service, binding.entity_id)
                    if (
                        after.percent == target_reserve_percent
                        and self._instant(after.updated_at) > self._instant(before.updated_at)
                    ):
                        break
                    if time.monotonic() >= deadline:
                        raise ApiError("energy_provider_unavailable", 503)
                    time.sleep(0.1)
                current_authority, current_inputs, current_digest, current_capability = guard()
                if (
                    current_authority != authority
                    or current_inputs.battery.resourceId != inputs.battery.resourceId
                    or current_inputs.battery.providerRevision
                    != inputs.battery.providerRevision
                    or current_inputs.reserve != inputs.reserve
                    or current_capability != capability
                ):
                    raise ApiError("revision_conflict", 409)
                self._finish(request_id, "verified", after)
                return FroniusReserveReceipt(
                    request_id, "verified", target_reserve_percent,
                    after.percent, binding.binding_revision,
                )
            except Exception:
                self._mark_uncertain(request_id)
                raise ApiError("energy_provider_unavailable", 503) from None

    def _finish(self, request_id, status, state):
        now = self._clock()
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM fronius_reserve_effects WHERE request_id=?",
                (request_id,),
            ).fetchone()
            self._verify_effect(row)
            fields = self._effect_fields(
                row,
                status=status,
                observed_reserve_percent=state.percent,
                observed_updated_at=state.updated_at,
                updated_at=now,
            )
            connection.execute(
                "UPDATE fronius_reserve_effects SET status=?,"
                "observed_reserve_percent=?,observed_updated_at=?,updated_at=?,record_hash=? "
                "WHERE request_id=?",
                (status, state.percent, state.updated_at, now,
                 self._hash(b"effect", fields), request_id),
            )

    def _mark_uncertain(self, request_id):
        now = self._clock()
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM fronius_reserve_effects WHERE request_id=?",
                (request_id,),
            ).fetchone()
            if row is None:
                return
            self._verify_effect(row)
            if row["status"] != "reserved":
                return
            fields = self._effect_fields(row, status="uncertain", updated_at=now)
            connection.execute(
                "UPDATE fronius_reserve_effects SET status='uncertain',updated_at=?,"
                "record_hash=? WHERE request_id=?",
                (now, self._hash(b"effect", fields), request_id),
            )

    def _reconcile(self, row, binding, service, guard):
        self._assert_current_effect(row, guard)
        self._check_registry(binding, service)
        if (
            row["binding_revision"] != binding.binding_revision
            or row["service_revision"] != binding.service_revision
        ):
            raise ApiError("revision_conflict", 409)
        if row["status"] in {"verified", "mismatch"}:
            return FroniusReserveReceipt(
                row["request_id"], row["status"], row["target_reserve_percent"],
                row["observed_reserve_percent"], binding.binding_revision,
            )
        self._assert_current_effect(row, guard)
        current = self._state(service, binding.entity_id)
        self._check_registry(binding, service)
        self._assert_current_effect(row, guard)
        if (
            current.percent == row["target_reserve_percent"]
            and self._instant(current.updated_at) > self._instant(row["before_updated_at"])
        ):
            status = "verified"
        elif current.updated_at != row["before_updated_at"]:
            status = "mismatch"
        else:
            return FroniusReserveReceipt(
                row["request_id"], "uncertain", row["target_reserve_percent"],
                None, binding.binding_revision,
            )
        self._finish(row["request_id"], status, current)
        return FroniusReserveReceipt(
            row["request_id"], status, row["target_reserve_percent"],
            current.percent, binding.binding_revision,
        )

    def result(self, authority, inputs, capability, *, request_id, input_digest, guard):
        if _IDENTITY.fullmatch(request_id or "") is None:
            raise ApiError("invalid_request")
        with self._lock:
            with self.database.connection() as connection:
                row = connection.execute(
                    "SELECT * FROM fronius_reserve_effects WHERE request_id=?",
                    (request_id,),
                ).fetchone()
            if row is None:
                raise ApiError("not_found", 404)
            self._verify_effect(row)
            if (
                row["command_digest"]
                != self._digest(self._stored_command_values(row))
                or row["core_id"] != authority.coreId
                or row["home_id"] != authority.homeId
                or row["home_revision"] != authority.homeRevision
                or row["account_id"] != authority.accountId
                or row["account_revision"] != authority.accountRevision
                or row["member_revision"] != authority.memberRevision
                or row["session_family_id"] != authority.sessionFamilyId
                or row["inverter_id"] != capability.inverterId
                or row["inverter_revision"] != capability.revision
                or row["battery_id"] != inputs.battery.resourceId
                or row["battery_provider_revision"] != inputs.battery.providerRevision
                or row["target_reserve_percent"]
                != inputs.reserve.backupReservePercent
            ):
                raise ApiError("revision_conflict", 409)
            binding, service = self._binding(
                battery_id=inputs.battery.resourceId,
                battery_provider_revision=inputs.battery.providerRevision,
            )
            return self._reconcile(row, binding, service, guard)

    def metadata(self, actor, service_id):
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            self._services._assert_admin(connection, actor)
            row = connection.execute(
                "SELECT * FROM fronius_reserve_bindings WHERE service_id=?",
                (service_id,),
            ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        value = self._decode_binding(row)
        return {
            "serviceId": value.service_id,
            "serviceRevision": value.service_revision,
            "bindingRevision": value.binding_revision,
            "batteryId": value.battery_id,
            "batteryProviderRevision": value.battery_provider_revision,
            "controlSemantics": "reserve_percent",
            "integration": "fronius",
            "model": value.model,
        }
