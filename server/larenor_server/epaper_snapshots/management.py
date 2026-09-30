"""Authenticated, persistent F58 e-paper management and delivery boundary."""

import hashlib
import hmac
import json
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from .models import (
    EpaperAuthority,
    EpaperDataSnapshot,
    EpaperDeliveryAck,
    EpaperDevice,
    EpaperLayout,
    EpaperPolicy,
    EpaperRenderSnapshot,
)
from .service import FRAME_BYTES, EpaperSnapshotService
from .open_epaper_link import OpenEpaperLinkProvider

MAX_DEVICES = 100
MAX_POLLS = 2_000
PREVIEW_TTL_SECONDS = 60


class EpaperManagement:
    """Owns mappings and receipts; bridge credentials never enter public records."""

    def __init__(self, db, auth, settings, key, context,
                 services_provider=None, home_resources=None, provider=None):
        self.db, self.auth, self.settings = db, auth, settings
        self._key, self.context = key, context
        self._services_provider = services_provider
        self._home_resources = home_resources
        self._provider = provider or OpenEpaperLinkProvider()

    @staticmethod
    def _canonical(value) -> str:
        return json.dumps(
            value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
            allow_nan=False,
        )

    def _tag(self, kind: str, values) -> str:
        encoded = self._canonical(values).encode("utf-8")
        return hmac.new(
            self._key, f"larenor-epaper-{kind}-v1\0".encode("ascii") + encoded,
            hashlib.sha256,
        ).hexdigest()

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)

    def _facts(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        return row

    def authority(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            account = self._facts(connection, actor)
            home_revision = (
                1 if self._home_resources is None
                else self._home_resources._state(connection)["revision"]
            )
        session_revision = int.from_bytes(
            hmac.new(
                self._key, b"larenor-epaper-session-v1\0" +
                (actor.family_id + ":" + actor.token_id).encode("ascii"),
                hashlib.sha256,
            ).digest()[:6], "big",
        ) + 1
        return {
            "schemaVersion": 1,
            "coreId": self.context.coreId,
            "homeId": self.context.homeId,
            "accountId": actor.id,
            "sessionFamilyId": actor.family_id,
            "homeRevision": home_revision,
            "accountRevision": account["revision"],
            "sessionRevision": session_revision,
            "canManage": actor.role == "admin",
        }

    def _expected(self, actor, core_id, home_id, body, *, admin=False):
        current = self.authority(actor, core_id, home_id)
        expected = body.authority_fields()
        actual = {name: current[name] for name in expected}
        if expected != actual:
            raise ApiError("authority_changed", 409)
        if admin and actor.role != "admin":
            raise ApiError("forbidden", 403)
        return current

    def _device_tag(self, row):
        return self._tag("device", [
            row["device_id"], row["core_id"], row["home_id"], row["owner_id"],
            row["revision"], row["active"], row["name"], row["configuration"],
            row["snapshot"], row["verified_digest"], row["updated_at"],
        ])

    def _preview_tag(self, row):
        return self._tag("preview", [
            row["request_id"], row["device_id"], row["actor_id"],
            row["session_family_id"], row["action"], row["device_revision"],
            row["layout_revision"], row["expires_at"], row["state"],
            row["command_digest"],
        ])

    def _command_digest(
        self, authority_fields, device_id, mapping_revision,
        device_revision, layout_revision, action,
    ):
        command = {
            "authority": authority_fields,
            "deviceId": device_id,
            "mappingRevision": mapping_revision,
            "deviceRevision": device_revision,
            "layoutRevision": layout_revision,
            "action": action,
        }
        return hashlib.sha256(
            b"larenor-epaper-command-v2\0" + self._canonical(command).encode("utf-8")
        ).hexdigest()

    def _poll_tag(self, row):
        return self._tag("poll", [
            row["request_id"], row["device_id"], row["device_revision"],
            row["render_digest"], row["byte_length"], row["frame_count"],
            row["status"], row["received_frames"],
        ])

    def _configuration(self, row):
        if row is None or not hmac.compare_digest(
            row["authentication_tag"], self._device_tag(row)
        ):
            raise StartupError("epaper_snapshot_storage_invalid")
        try:
            raw = json.loads(row["configuration"])
            configuration = {
                "device": EpaperDevice.model_validate(raw["device"]),
                "layout": EpaperLayout.model_validate(raw["layout"]),
                "data": EpaperDataSnapshot.model_validate(raw["data"]),
                "policy": EpaperPolicy.model_validate(raw["policy"]),
                "ttlSeconds": raw["ttlSeconds"],
            }
            binding = raw.get("binding")
            literal = raw.get("literal")
            if binding is not None or literal is not None:
                if (
                    type(binding) is not dict or set(binding) != {
                        "serviceId", "serviceRevision", "sourceRevision",
                        "imageEntityId", "pendingUpdates", "updateCount",
                    }
                    or type(literal) is not dict or set(literal) != {"title", "value"}
                    or not isinstance(binding["serviceId"], str)
                    or len(binding["serviceId"]) != 32
                    or any(character not in "0123456789abcdef" for character in binding["serviceId"])
                    or not isinstance(binding["imageEntityId"], str)
                    or not binding["imageEntityId"].startswith("image.")
                    or len(binding["imageEntityId"]) > 128
                    or not all(type(binding[name]) is int and 1 <= binding[name] <= 2**63 - 1
                               for name in ("serviceRevision", "sourceRevision"))
                    or binding["pendingUpdates"] is not None and type(binding["pendingUpdates"]) is not int
                    or binding["updateCount"] is not None and type(binding["updateCount"]) is not int
                    or not all(isinstance(literal[name], str) for name in ("title", "value"))
                ):
                    raise ValueError("invalid_provider_binding")
                configuration["binding"], configuration["literal"] = binding, literal
            if row["snapshot"] is not None:
                configuration["snapshot"] = EpaperRenderSnapshot.model_validate_json(
                    row["snapshot"]
                )
        except (ValidationError, ValueError, TypeError, KeyError, json.JSONDecodeError):
            raise StartupError("epaper_snapshot_storage_invalid") from None
        return configuration

    def _provider_tag(self, row):
        return self._tag("provider-command", [
            row["request_id"], row["device_id"], row["command_json"],
            row["state"], row["artifact_digest"], row["observed_digest"],
        ])

    def _provider_row(self, connection, request_id, *, required=True):
        row = connection.execute(
            "SELECT * FROM epaper_provider_commands WHERE request_id=?", (request_id,)
        ).fetchone()
        if row is None:
            if required:
                raise ApiError("not_found", 404)
            return None
        if (not hmac.compare_digest(row["authentication_tag"], self._provider_tag(row))
                or not hmac.compare_digest(
                    hashlib.sha256(row["artifact"]).hexdigest(), row["artifact_digest"]
                )):
            raise StartupError("epaper_snapshot_storage_invalid")
        return row

    def _service(self, actor, expected, service_id, service_revision):
        if self._services_provider is None:
            raise ApiError("epaper_source_unavailable", 503)
        services = self._services_provider()
        with self.db.connection() as connection:
            current = self.authority(actor, self.context.coreId, self.context.homeId)
            if expected is not None and any(current[name] != expected[name] for name in expected):
                raise ApiError("authority_changed", 409)
            return services._authenticated_home_assistant_connection(
                connection, service_id, service_revision
            )

    def _guard(self, actor, expected, service_id, service_revision,
               device_id=None, mapping_revision=None):
        def current():
            service = self._service(
                actor, expected, service_id, service_revision
            )
            if device_id is not None:
                with self.db.connection() as connection:
                    row = self._row(connection, device_id)
                    if mapping_revision is not None and row["revision"] != mapping_revision:
                        raise ApiError("revision_conflict", 409)
            return service
        return current

    def _row(self, connection, device_id, *, required=True):
        row = connection.execute(
            "SELECT * FROM epaper_devices WHERE device_id=?", (device_id,)
        ).fetchone()
        if row is None:
            if required:
                raise ApiError("not_found", 404)
            return None
        if (row["core_id"], row["home_id"]) != (
            self.context.coreId, self.context.homeId,
        ):
            raise ApiError("not_found", 404)
        self._configuration(row)
        return row

    def _compose(self, authority, configuration):
        device, layout, data, policy = (
            configuration[name] for name in ("device", "layout", "data", "policy")
        )
        low_authority = EpaperAuthority(
            schemaVersion=1,
            coreId=authority["coreId"],
            homeId=authority["homeId"],
            homeRevision=authority["homeRevision"],
            accountId=authority["accountId"],
            accountRevision=authority["accountRevision"],
            memberRevision=authority["accountRevision"],
            sessionFamilyId=authority["sessionFamilyId"],
            active=True,
            canPublishEpaper=authority["canManage"],
        )
        service = EpaperSnapshotService(
            authorityResolver=lambda account_id: low_authority if account_id == low_authority.accountId else None,
            deviceResolver=lambda device_id: device if device_id == device.deviceId else None,
            layoutResolver=lambda layout_id: layout if layout_id == layout.layoutId else None,
            dataResolver=lambda data_id: data if data_id == data.dataId else None,
            policyResolver=lambda policy_id: policy if policy_id == policy.policyId else None,
            clockMs=lambda: int(self.settings.clock() * 1000),
        )
        return service.compose(
            low_authority, device, layout, data, policy,
            ttlSeconds=configuration["ttlSeconds"],
        )

    @staticmethod
    def _local_id(domain, *values):
        raw = json.dumps(values, separators=(",", ":"), ensure_ascii=False).encode()
        return hashlib.sha256(domain.encode("ascii") + b"\0" + raw).hexdigest()[:32]

    def discover_sources(self, actor, core_id, home_id, body):
        authority = self._expected(actor, core_id, home_id, body, admin=True)
        if self._services_provider is None:
            raise ApiError("epaper_source_unavailable", 503)
        values = []
        services = self._services_provider()
        for candidate in services.configured_connections():
            if candidate.kind != "home_assistant":
                continue
            try:
                service = self._service(
                    actor, body.authority_fields(), candidate.id, candidate.revision
                )
                guard = self._guard(
                    actor, body.authority_fields(), service.id, service.revision
                )
                values.extend(item.public() for item in self._provider.discover(service, guard))
            except ApiError as error:
                if error.code in {"ha_binding_changed", "not_found"}:
                    continue
                raise
        if len(values) > 100:
            raise ApiError("epaper_device_limit", 409)
        return {"schemaVersion": 1, "authority": authority, "devices": values}

    def map_source(self, actor, core_id, home_id, device_id, body):
        authority = self._expected(actor, core_id, home_id, body, admin=True)
        service = self._service(
            actor, body.authority_fields(), body.serviceId, body.serviceRevision
        )
        guard = self._guard(
            actor, body.authority_fields(), service.id, service.revision
        )
        matches = [item for item in self._provider.discover(service, guard)
                   if item.device_id == device_id]
        if len(matches) != 1:
            raise ApiError("revision_conflict", 409)
        observed = matches[0]
        if observed.source_revision != body.expectedSourceRevision:
            raise ApiError("revision_conflict", 409)
        self._provider.literal_payload(
            body.title, body.value, observed.width, observed.height
        )
        mapping_revision = body.expectedMappingRevision + 1
        layout_id = self._local_id("layout", service.id, device_id)
        data_id = self._local_id("data", service.id, device_id)
        policy_id = self._local_id("policy", service.id, device_id)
        slot_id = self._local_id("slot", service.id, device_id)
        content_revision = int.from_bytes(hashlib.sha256(
            (body.title + "\0" + body.value).encode("utf-8")
        ).digest()[:6], "big") + 1
        device = EpaperDevice(
            schemaVersion=1, coreId=core_id, homeId=home_id,
            deviceId=device_id, revision=observed.source_revision,
            bridgeRevision=service.revision, width=observed.width,
            height=observed.height, supportedColors=["black", "white"],
            active=True, connectivity="online" if observed.reachable else "offline",
            batteryPercent=observed.battery_percent,
            lastSeenAtMs=observed.last_seen_at_ms,
        )
        layout = EpaperLayout(
            schemaVersion=1, coreId=core_id, homeId=home_id,
            layoutId=layout_id, revision=mapping_revision,
            width=observed.width, height=observed.height,
            colors=["black", "white"], slots=[{
                "schemaVersion": 1, "slotId": slot_id, "kind": "clock",
                "column": 0, "row": 0, "columnSpan": 8, "rowSpan": 8,
            }],
        )
        data = EpaperDataSnapshot(
            schemaVersion=1, coreId=core_id, homeId=home_id,
            dataId=data_id, revision=content_revision,
            providerRevision=observed.source_revision,
            capturedAtMs=int(self.settings.clock() * 1000), classification="shared",
            cards=[{
                "schemaVersion": 1, "slotId": slot_id, "kind": "clock",
                "label": body.title, "value": body.value, "unit": None,
                "status": "normal" if observed.reachable else "offline",
                "accent": "black",
            }],
        )
        policy = EpaperPolicy(
            schemaVersion=1, coreId=core_id, homeId=home_id,
            policyId=policy_id, revision=mapping_revision,
            allowedKinds=["clock"], allowedColors=["black", "white"],
            maxCards=1, maxTtlSeconds=body.ttlSeconds, sharedContentOnly=True,
        )
        configuration = {
            "device": device, "layout": layout, "data": data, "policy": policy,
            "ttlSeconds": body.ttlSeconds,
            "binding": {
                "serviceId": service.id, "serviceRevision": service.revision,
                "sourceRevision": observed.source_revision,
                "imageEntityId": observed.image_entity_id,
                "pendingUpdates": observed.pending_updates,
                "updateCount": observed.update_count,
            },
            "literal": {"title": body.title, "value": body.value},
        }
        snapshot = self._compose(authority, configuration)
        raw_configuration = self._canonical({
            key: value.model_dump(mode="json") if hasattr(value, "model_dump") else value
            for key, value in configuration.items()
        })
        guard()
        now = self.settings.clock()
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            old = self._row(connection, device_id, required=False)
            actual = 0 if old is None else old["revision"]
            if actual != body.expectedMappingRevision:
                raise ApiError("revision_conflict", 409)
            if old is None and connection.execute(
                "SELECT COUNT(*) FROM epaper_devices"
            ).fetchone()[0] >= MAX_DEVICES:
                raise ApiError("epaper_device_limit", 409)
            row = {
                "device_id": device_id, "core_id": core_id, "home_id": home_id,
                "owner_id": actor.id, "revision": mapping_revision, "active": 1,
                "name": body.name, "configuration": raw_configuration,
                "snapshot": snapshot.model_dump_json(), "verified_digest": None,
                "updated_at": now,
            }
            row["authentication_tag"] = self._device_tag(row)
            connection.execute(
                "INSERT INTO epaper_devices VALUES(?,?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(device_id) DO UPDATE SET owner_id=excluded.owner_id,"
                "revision=excluded.revision,active=excluded.active,name=excluded.name,"
                "configuration=excluded.configuration,snapshot=excluded.snapshot,"
                "verified_digest=NULL,updated_at=excluded.updated_at,"
                "authentication_tag=excluded.authentication_tag",
                tuple(row.values()),
            )
        return self._public(authority, row)

    def map_device(self, actor, core_id, home_id, body):
        authority = self._expected(actor, core_id, home_id, body, admin=True)
        try:
            device = EpaperDevice.model_validate(body.device)
            layout = EpaperLayout.model_validate(body.layout)
            data = EpaperDataSnapshot.model_validate(body.data)
            policy = EpaperPolicy.model_validate(body.policy)
        except (ValidationError, ValueError, TypeError):
            raise ApiError("epaper_content_rejected", 400) from None
        if any((item.coreId, item.homeId) != (core_id, home_id)
               for item in (device, layout, data, policy)):
            raise ApiError("authority_changed", 409)
        configuration = {
            "device": device, "layout": layout, "data": data, "policy": policy,
            "ttlSeconds": body.ttlSeconds,
        }
        snapshot = self._compose(authority, configuration)
        raw_configuration = self._canonical({
            key: value.model_dump(mode="json") if hasattr(value, "model_dump") else value
            for key, value in configuration.items()
        })
        now = self.settings.clock()
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            old = self._row(connection, device.deviceId, required=False)
            actual_revision = 0 if old is None else old["revision"]
            if actual_revision != body.expectedMappingRevision:
                raise ApiError("revision_conflict", 409)
            if old is None and connection.execute(
                "SELECT COUNT(*) FROM epaper_devices"
            ).fetchone()[0] >= MAX_DEVICES:
                raise ApiError("epaper_device_limit", 409)
            row = {
                "device_id": device.deviceId, "core_id": core_id, "home_id": home_id,
                "owner_id": actor.id, "revision": actual_revision + 1, "active": 1,
                "name": body.name, "configuration": raw_configuration,
                "snapshot": snapshot.model_dump_json(), "verified_digest": None,
                "updated_at": now,
            }
            row["authentication_tag"] = self._device_tag(row)
            connection.execute(
                "INSERT INTO epaper_devices VALUES(?,?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(device_id) DO UPDATE SET owner_id=excluded.owner_id,"
                "revision=excluded.revision,active=excluded.active,name=excluded.name,"
                "configuration=excluded.configuration,snapshot=excluded.snapshot,"
                "verified_digest=NULL,updated_at=excluded.updated_at,"
                "authentication_tag=excluded.authentication_tag",
                tuple(row.values()),
            )
        return self._public(authority, row)

    def _public(self, authority, row):
        configuration = self._configuration(row)
        device = configuration["device"]
        layout, data, policy = (
            configuration[name] for name in ("layout", "data", "policy")
        )
        snapshot = configuration.get("snapshot")
        now_ms = int(self.settings.clock() * 1000)
        if snapshot is None:
            trust = "empty"
        elif now_ms >= snapshot.expiresAtMs:
            trust = "stale"
        else:
            poll = None
            with self.db.connection() as connection:
                poll = connection.execute(
                    "SELECT * FROM epaper_polls WHERE device_id=? AND render_digest=? "
                    "ORDER BY rowid DESC LIMIT 1", (device.deviceId, snapshot.renderDigest),
                ).fetchone()
            if poll is not None and not hmac.compare_digest(
                poll["authentication_tag"], self._poll_tag(poll)
            ):
                raise StartupError("epaper_snapshot_storage_invalid")
            # Historical `verified` rows only record an account-supplied ACK.
            # No paired bridge can attest physical delivery yet.
            trust = (
                "acknowledged" if poll is not None and poll["status"] == "verified"
                else "partial" if poll is not None and poll["status"] == "partial"
                else "pending"
            )
        return {
            "schemaVersion": 1,
            "authority": {key: authority[key] for key in (
                "coreId", "homeId", "accountId", "sessionFamilyId",
                "homeRevision", "accountRevision", "sessionRevision", "canManage",
            )},
            "deviceId": device.deviceId,
            "name": row["name"],
            "deviceRevision": str(device.revision),
            "mappingRevision": row["revision"],
            "bridgeRevision": str(device.bridgeRevision),
            "layoutRevision": str(layout.revision),
            "dataRevision": str(data.revision),
            "policyRevision": str(policy.revision),
            "stored": bool(row["active"]),
            "reachable": device.active and device.connectivity == "online",
            "connectivity": device.connectivity,
            "capabilityVerified": device.connectivity != "unknown",
            "batteryPercent": device.batteryPercent,
            "lastSeenAtMs": device.lastSeenAtMs,
            "width": device.width,
            "height": device.height,
            "supportedColors": device.supportedColors,
            "retainsLastImageOffline": True,
            "snapshotTrust": trust,
            "snapshotDigest": None if snapshot is None else snapshot.renderDigest,
            "verifiedDigest": None,
            "expiresAtMs": 0 if snapshot is None else snapshot.expiresAtMs,
        }

    def list_devices(self, actor, core_id, home_id, body):
        authority = self._expected(actor, core_id, home_id, body)
        with self.db.connection() as connection:
            self._facts(connection, actor)
            rows = connection.execute(
                "SELECT * FROM epaper_devices WHERE core_id=? AND home_id=? AND active=1 "
                "ORDER BY name,device_id LIMIT ?", (core_id, home_id, MAX_DEVICES + 1),
            ).fetchall()
        if len(rows) > MAX_DEVICES:
            raise ApiError("epaper_device_limit", 409)
        return {"schemaVersion": 1, "devices": [self._public(authority, row) for row in rows]}

    def readback(self, actor, core_id, home_id, device_id, body):
        authority = self._expected(actor, core_id, home_id, body)
        with self.db.connection() as connection:
            self._facts(connection, actor)
            row = self._row(connection, device_id)
        return self._public(authority, row)

    def preview(self, actor, core_id, home_id, device_id, body):
        authority = self._expected(actor, core_id, home_id, body, admin=True)
        if body.action != "refresh":
            raise ApiError("invalid_request", 400)
        with self.db.connection() as connection:
            bound_row = self._row(connection, device_id)
            bound_configuration = self._configuration(bound_row)
        if "binding" in bound_configuration:
            return self._provider_preview(
                actor, authority, body, bound_row, bound_configuration
            )
        now = self.settings.clock()
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            device_row = self._row(connection, device_id)
            config = self._configuration(device_row)
            device, layout = config["device"], config["layout"]
            if body.expectedDeviceRevision != str(device.revision):
                raise ApiError("revision_conflict", 409)
            request_id = uuid.uuid4().hex
            row = {
                "request_id": request_id, "device_id": device_id,
                "actor_id": actor.id, "session_family_id": actor.family_id,
                "action": body.action, "device_revision": device.revision,
                "layout_revision": layout.revision,
                "expires_at": now + PREVIEW_TTL_SECONDS, "state": "pending",
                "command_digest": self._command_digest(
                    body.authority_fields(), device_id, device_row["revision"],
                    device.revision, layout.revision, body.action,
                ),
            }
            row["authentication_tag"] = self._preview_tag(row)
            connection.execute(
                "INSERT INTO epaper_previews VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
        return {
            "schemaVersion": 1, "authority": authority,
            "requestId": request_id, "deviceId": device_id,
            "deviceRevision": str(device.revision), "action": body.action,
            "expectedLayoutRevision": str(layout.revision),
            "expiresAtMs": int(row["expires_at"] * 1000),
        }

    def _bound_observation(self, actor, expected, row, configuration):
        binding = configuration["binding"]
        service = self._service(
            actor, expected, binding["serviceId"], binding["serviceRevision"]
        )
        guard = self._guard(
            actor, expected, service.id, service.revision,
            row["device_id"], row["revision"],
        )
        matches = [item for item in self._provider.discover(service, guard)
                   if item.device_id == row["device_id"]]
        if (len(matches) != 1
                or matches[0].source_revision != binding["sourceRevision"]
                or matches[0].image_entity_id != binding["imageEntityId"]):
            raise ApiError("revision_conflict", 409)
        return service, matches[0], guard

    def _provider_preview(self, actor, authority, body, row, configuration):
        with self.db.connection() as connection:
            if (connection.execute(
                    "SELECT COUNT(*) FROM epaper_provider_commands"
                ).fetchone()[0] >= MAX_POLLS or connection.execute(
                    "SELECT COUNT(*) FROM epaper_previews"
                ).fetchone()[0] >= MAX_POLLS):
                raise ApiError("epaper_poll_limit", 409)
        device, layout = configuration["device"], configuration["layout"]
        if body.expectedDeviceRevision != str(device.revision):
            raise ApiError("revision_conflict", 409)
        expected = body.authority_fields()
        service, observed, guard = self._bound_observation(
            actor, expected, row, configuration
        )
        literal = configuration["literal"]
        payload = self._provider.literal_payload(
            literal["title"], literal["value"], observed.width, observed.height
        )
        if self._provider.draw(
            service, observed, payload, configuration["ttlSeconds"],
            dry_run=True, guard=guard,
        ) is not True:
            raise ApiError("epaper_source_unavailable", 503)
        artifact = self._provider.image(service, observed, guard)
        artifact_digest = hashlib.sha256(artifact).hexdigest()
        request_id = uuid.uuid4().hex
        expires_at = self.settings.clock() + PREVIEW_TTL_SECONDS
        command = {
            "schemaVersion": 1, "authority": expected,
            "mappingRevision": row["revision"], "deviceId": row["device_id"],
            "deviceRevision": device.revision, "layoutRevision": layout.revision,
            "serviceId": service.id, "serviceRevision": service.revision,
            "sourceRevision": observed.source_revision,
            "imageEntityId": observed.image_entity_id,
            "width": observed.width, "height": observed.height,
            "pendingUpdates": observed.pending_updates,
            "updateCount": observed.update_count,
            "payload": payload, "ttlSeconds": configuration["ttlSeconds"],
        }
        command_json = self._canonical(command)
        preview = {
            "request_id": request_id, "device_id": row["device_id"],
            "actor_id": actor.id, "session_family_id": actor.family_id,
            "action": body.action, "device_revision": device.revision,
            "layout_revision": layout.revision, "expires_at": expires_at,
            "state": "pending", "command_digest": hashlib.sha256(
                b"larenor-epaper-oepl-command-v1\0" + command_json.encode()
            ).hexdigest(),
        }
        preview["authentication_tag"] = self._preview_tag(preview)
        provider_row = {
            "request_id": request_id, "device_id": row["device_id"],
            "command_json": command_json, "state": "prepared",
            "artifact_digest": artifact_digest, "artifact": artifact,
            "observed_digest": None,
        }
        provider_row["authentication_tag"] = self._provider_tag(provider_row)
        guard()
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            current = self._row(connection, row["device_id"])
            if current["revision"] != row["revision"]:
                raise ApiError("revision_conflict", 409)
            if connection.execute(
                "SELECT COUNT(*) FROM epaper_provider_commands"
            ).fetchone()[0] >= MAX_POLLS or connection.execute(
                "SELECT COUNT(*) FROM epaper_previews"
            ).fetchone()[0] >= MAX_POLLS:
                raise ApiError("epaper_poll_limit", 409)
            connection.execute(
                "INSERT INTO epaper_previews VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                tuple(preview.values()),
            )
            connection.execute(
                "INSERT INTO epaper_provider_commands VALUES(?,?,?,?,?,?,?,?)",
                tuple(provider_row.values()),
            )
        return {
            "schemaVersion": 1, "authority": authority,
            "requestId": request_id, "deviceId": row["device_id"],
            "deviceRevision": str(device.revision), "action": body.action,
            "expectedLayoutRevision": str(layout.revision),
            "expiresAtMs": int(expires_at * 1000),
            "artifactDigest": artifact_digest,
            "artifactPath": f"/admin/epaper/{self.context.coreId}/{self.context.homeId}/previews/{request_id}/artifact",
            "physicalDeliveryVerified": False,
        }

    def cancel_preview(self, actor, core_id, home_id, request_id, body):
        self._expected(actor, core_id, home_id, body, admin=True)
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            row = connection.execute(
                "SELECT * FROM epaper_previews WHERE request_id=?", (request_id,)
            ).fetchone()
            if row is None:
                raise ApiError("not_found", 404)
            if not hmac.compare_digest(row["authentication_tag"], self._preview_tag(row)):
                raise StartupError("epaper_snapshot_storage_invalid")
            if (row["actor_id"], row["session_family_id"], row["state"]) != (
                actor.id, actor.family_id, "pending",
            ):
                raise ApiError("revision_conflict", 409)
            updated = dict(row)
            updated["state"] = "cancelled"
            updated["authentication_tag"] = self._preview_tag(updated)
            connection.execute(
                "UPDATE epaper_previews SET state=?,authentication_tag=? WHERE request_id=?",
                ("cancelled", updated["authentication_tag"], request_id),
            )
            provider = self._provider_row(connection, request_id, required=False)
            if provider is not None:
                if provider["state"] != "prepared":
                    raise ApiError("revision_conflict", 409)
                changed_provider = dict(provider)
                changed_provider["state"] = "cancelled"
                changed_provider["authentication_tag"] = self._provider_tag(changed_provider)
                connection.execute(
                    "UPDATE epaper_provider_commands SET state='cancelled',authentication_tag=? "
                    "WHERE request_id=?",
                    (changed_provider["authentication_tag"], request_id),
                )

    def confirm(self, actor, core_id, home_id, request_id, body):
        authority = self._expected(actor, core_id, home_id, body, admin=True)
        with self.db.connection() as connection:
            provider = self._provider_row(connection, request_id, required=False)
        if provider is not None:
            return self._provider_confirm(
                actor, authority, request_id, body.authority_fields()
            )
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            preview = connection.execute(
                "SELECT * FROM epaper_previews WHERE request_id=?", (request_id,)
            ).fetchone()
            if preview is None or not hmac.compare_digest(
                preview["authentication_tag"], self._preview_tag(preview)
            ):
                raise ApiError("not_found", 404)
            if (
                preview["actor_id"] != actor.id
                or preview["session_family_id"] != actor.family_id
                or preview["state"] != "pending"
                or self.settings.clock() >= preview["expires_at"]
            ):
                raise ApiError("revision_conflict", 409)
            row = self._row(connection, preview["device_id"])
            config = self._configuration(row)
            if (
                config["device"].revision != preview["device_revision"]
                or config["layout"].revision != preview["layout_revision"]
                or not hmac.compare_digest(
                    preview["command_digest"],
                    self._command_digest(
                        body.authority_fields(), preview["device_id"],
                        row["revision"], config["device"].revision,
                        config["layout"].revision, preview["action"],
                    ),
                )
            ):
                raise ApiError("revision_conflict", 409)
            snapshot = self._compose(authority, config)
            updated = dict(row)
            updated["snapshot"] = snapshot.model_dump_json()
            updated["verified_digest"] = None
            updated["updated_at"] = self.settings.clock()
            updated["authentication_tag"] = self._device_tag(updated)
            connection.execute(
                "UPDATE epaper_devices SET snapshot=?,verified_digest=NULL,updated_at=?,"
                "authentication_tag=? WHERE device_id=?",
                (updated["snapshot"], updated["updated_at"], updated["authentication_tag"], row["device_id"]),
            )
            changed = dict(preview)
            changed["state"] = "published"
            changed["authentication_tag"] = self._preview_tag(changed)
            connection.execute(
                "UPDATE epaper_previews SET state='published',authentication_tag=? WHERE request_id=?",
                (changed["authentication_tag"], request_id),
            )
        # Publication is not delivery. The Client must wait for bridge readback.
        return {
            "schemaVersion": 1, "authority": authority,
            "requestId": request_id, "deviceId": preview["device_id"],
            "deviceRevision": str(preview["device_revision"]),
            "action": preview["action"], "status": "uncertain",
            "observedLayoutRevision": None, "observedSnapshotDigest": None,
        }

    @staticmethod
    def _provider_receipt(authority, preview, provider):
        state = provider["state"]
        status = "rejected" if state in {"rejected", "cancelled"} else "uncertain"
        return {
            "schemaVersion": 1, "authority": authority,
            "requestId": preview["request_id"], "deviceId": preview["device_id"],
            "deviceRevision": str(preview["device_revision"]),
            "action": preview["action"], "status": status,
            "observedLayoutRevision": (
                str(preview["layout_revision"]) if state == "readback_observed" else None
            ),
            "observedSnapshotDigest": provider["observed_digest"],
            "physicalDeliveryVerified": False,
        }

    def _provider_confirm(self, actor, authority, request_id, expected):
        with self.db.connection() as connection:
            preview = connection.execute(
                "SELECT * FROM epaper_previews WHERE request_id=?", (request_id,)
            ).fetchone()
            provider = self._provider_row(connection, request_id)
            if preview is None or not hmac.compare_digest(
                preview["authentication_tag"], self._preview_tag(preview)
            ):
                raise ApiError("not_found", 404)
            if (preview["actor_id"] != actor.id
                    or preview["session_family_id"] != actor.family_id):
                raise ApiError("revision_conflict", 409)
            row = self._row(connection, preview["device_id"])
            configuration = self._configuration(row)
            command = json.loads(provider["command_json"])
        if provider["state"] == "prepared":
            service, observed, _guard = self._bound_observation(
                actor, expected, row, configuration
            )
            if (observed.source_revision != command["sourceRevision"]
                    or observed.image_entity_id != command["imageEntityId"]
                    or service.id != command["serviceId"]
                    or service.revision != command["serviceRevision"]):
                raise ApiError("revision_conflict", 409)
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            preview = connection.execute(
                "SELECT * FROM epaper_previews WHERE request_id=?", (request_id,)
            ).fetchone()
            provider = self._provider_row(connection, request_id)
            if preview is None or not hmac.compare_digest(
                preview["authentication_tag"], self._preview_tag(preview)
            ):
                raise ApiError("not_found", 404)
            if (preview["actor_id"] != actor.id
                    or preview["session_family_id"] != actor.family_id):
                raise ApiError("revision_conflict", 409)
            if provider["state"] in {
                "accepted", "rejected", "uncertain", "readback_observed",
            }:
                return self._provider_receipt(authority, preview, provider)
            if provider["state"] == "dispatching":
                changed = dict(provider)
                changed["state"] = "uncertain"
                changed["authentication_tag"] = self._provider_tag(changed)
                connection.execute(
                    "UPDATE epaper_provider_commands SET state='uncertain',authentication_tag=? "
                    "WHERE request_id=?", (changed["authentication_tag"], request_id),
                )
                return self._provider_receipt(authority, preview, changed)
            if (provider["state"] != "prepared" or preview["state"] != "pending"
                    or preview["actor_id"] != actor.id
                    or preview["session_family_id"] != actor.family_id
                    or self.settings.clock() >= preview["expires_at"]):
                raise ApiError("revision_conflict", 409)
            command = json.loads(provider["command_json"])
            row = self._row(connection, preview["device_id"])
            if (row["revision"] != command["mappingRevision"]
                    or command["authority"] != expected):
                raise ApiError("revision_conflict", 409)
            changed = dict(provider)
            changed["state"] = "dispatching"
            changed["authentication_tag"] = self._provider_tag(changed)
            changed_preview = dict(preview)
            changed_preview["state"] = "published"
            changed_preview["authentication_tag"] = self._preview_tag(changed_preview)
            connection.execute(
                "UPDATE epaper_provider_commands SET state='dispatching',authentication_tag=? "
                "WHERE request_id=?", (changed["authentication_tag"], request_id),
            )
            connection.execute(
                "UPDATE epaper_previews SET state='published',authentication_tag=? WHERE request_id=?",
                (changed_preview["authentication_tag"], request_id),
            )
        with self.db.connection() as connection:
            current_row = self._row(connection, command["deviceId"])
            current_configuration = self._configuration(current_row)
        service, device, guard = self._bound_observation(
            actor, expected, current_row, current_configuration
        )
        if (device.source_revision != command["sourceRevision"]
                or device.image_entity_id != command["imageEntityId"]):
            raise ApiError("revision_conflict", 409)
        result = self._provider.draw(
            service, device, command["payload"], command["ttlSeconds"],
            dry_run=False, guard=guard,
        )
        state = "accepted" if result is True else "rejected" if result is False else "uncertain"
        observed_digest = None
        if result is True:
            try:
                observed = self._provider.image(service, device, guard)
                observed_digest = hashlib.sha256(observed).hexdigest()
                if hmac.compare_digest(observed_digest, provider["artifact_digest"]):
                    state = "readback_observed"
            except ApiError:
                pass
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            current = self._provider_row(connection, request_id)
            if current["state"] != "dispatching":
                raise ApiError("revision_conflict", 409)
            finished = dict(current)
            finished["state"], finished["observed_digest"] = state, observed_digest
            finished["authentication_tag"] = self._provider_tag(finished)
            connection.execute(
                "UPDATE epaper_provider_commands SET state=?,observed_digest=?,authentication_tag=? "
                "WHERE request_id=?",
                (state, observed_digest, finished["authentication_tag"], request_id),
            )
            preview = connection.execute(
                "SELECT * FROM epaper_previews WHERE request_id=?", (request_id,)
            ).fetchone()
        return self._provider_receipt(authority, preview, finished)

    def artifact(self, actor, core_id, home_id, request_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            self._facts(connection, actor)
            preview = connection.execute(
                "SELECT * FROM epaper_previews WHERE request_id=?", (request_id,)
            ).fetchone()
            provider = self._provider_row(connection, request_id)
        if (preview is None
                or not hmac.compare_digest(preview["authentication_tag"], self._preview_tag(preview))
                or preview["actor_id"] != actor.id
                or preview["session_family_id"] != actor.family_id
                or preview["state"] == "cancelled"):
            raise ApiError("not_found", 404)
        command = json.loads(provider["command_json"])
        self._guard(actor, command["authority"], command["serviceId"],
                    command["serviceRevision"], command["deviceId"],
                    command["mappingRevision"])()
        return provider["artifact"], provider["artifact_digest"]

    def poll(self, actor, core_id, home_id, device_id, body):
        self._expected(actor, core_id, home_id, body)
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            device_row = self._row(connection, device_id)
            config = self._configuration(device_row)
            snapshot = config.get("snapshot")
            device = config["device"]
            if snapshot is None:
                raise ApiError("not_found", 404)
            if body.expectedDeviceRevision != device.revision:
                raise ApiError("revision_conflict", 409)
            if int(self.settings.clock() * 1000) >= snapshot.expiresAtMs:
                raise ApiError("epaper_snapshot_stale", 409)
            raw = snapshot.model_dump_json().encode("utf-8")
            byte_length = len(raw)
            frames = (byte_length + FRAME_BYTES - 1) // FRAME_BYTES
            if byte_length > 256 * 1024 or frames > 64:
                raise ApiError("epaper_content_rejected", 413)
            row = {
                "request_id": body.requestId, "device_id": device_id,
                "device_revision": device.revision,
                "render_digest": snapshot.renderDigest,
                "byte_length": byte_length, "frame_count": frames,
                "status": "pending", "received_frames": 0,
            }
            row["authentication_tag"] = self._poll_tag(row)
            prior = connection.execute(
                "SELECT * FROM epaper_polls WHERE request_id=?", (body.requestId,)
            ).fetchone()
            if prior is not None:
                if not hmac.compare_digest(prior["authentication_tag"], self._poll_tag(prior)):
                    raise StartupError("epaper_snapshot_storage_invalid")
                if any(prior[key] != row[key] for key in row):
                    raise ApiError("revision_conflict", 409)
            else:
                if connection.execute("SELECT COUNT(*) FROM epaper_polls").fetchone()[0] >= MAX_POLLS:
                    raise ApiError("epaper_poll_limit", 409)
                connection.execute(
                    "INSERT INTO epaper_polls VALUES(?,?,?,?,?,?,?,?,?)", tuple(row.values())
                )
        return {
            "schemaVersion": 1, "requestId": body.requestId,
            "deviceId": device_id, "deviceRevision": device.revision,
            "deviceConnectivity": device.connectivity,
            "snapshot": snapshot.model_dump(mode="json"),
            "byteLength": byte_length, "frameCount": frames,
        }

    def acknowledge(self, actor, core_id, home_id, device_id, body):
        self._expected(actor, core_id, home_id, body)
        try:
            ack = EpaperDeliveryAck.model_validate(body.ack)
        except (ValidationError, ValueError, TypeError):
            raise ApiError("invalid_request", 400) from None
        if (ack.coreId, ack.homeId, ack.deviceId) != (core_id, home_id, device_id):
            raise ApiError("revision_conflict", 409)
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            device_row = self._row(connection, device_id)
            config = self._configuration(device_row)
            snapshot = config.get("snapshot")
            poll = connection.execute(
                "SELECT * FROM epaper_polls WHERE request_id=?", (ack.requestId,)
            ).fetchone()
            if snapshot is None or poll is None or not hmac.compare_digest(
                poll["authentication_tag"], self._poll_tag(poll)
            ):
                raise ApiError("revision_conflict", 409)
            expected = (
                config["device"].revision, config["layout"].revision,
                config["data"].revision, config["policy"].revision,
                snapshot.renderDigest, poll["byte_length"], poll["frame_count"],
            )
            actual = (
                ack.deviceRevision, ack.layoutRevision, ack.dataRevision,
                ack.policyRevision, ack.renderDigest, ack.byteLength, ack.frameCount,
            )
            if actual != expected or (
                ack.status == "complete" and ack.receivedFrames != ack.frameCount
            ) or (ack.status == "partial" and ack.receivedFrames >= ack.frameCount):
                raise ApiError("revision_conflict", 409)
            # Keep the legacy SQLite value for backward-compatible idempotency;
            # it is never exposed as physical verification.
            status = "verified" if ack.status == "complete" else "partial"
            public_status = "acknowledged" if status == "verified" else "partial"
            if poll["status"] != "pending":
                if poll["status"] == status and poll["received_frames"] == ack.receivedFrames:
                    return {"schemaVersion": 1, "requestId": ack.requestId,
                            "status": public_status, "verified": False,
                            "snapshotDigest": snapshot.renderDigest}
                raise ApiError("revision_conflict", 409)
            changed = dict(poll)
            changed["status"], changed["received_frames"] = status, ack.receivedFrames
            changed["authentication_tag"] = self._poll_tag(changed)
            connection.execute(
                "UPDATE epaper_polls SET status=?,received_frames=?,authentication_tag=? WHERE request_id=?",
                (status, ack.receivedFrames, changed["authentication_tag"], ack.requestId),
            )
        return {"schemaVersion": 1, "requestId": ack.requestId,
                "status": public_status, "verified": False,
                "snapshotDigest": snapshot.renderDigest}

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                devices = connection.execute(
                    "SELECT * FROM epaper_devices LIMIT ?", (MAX_DEVICES + 1,)
                ).fetchall()
                if len(devices) > MAX_DEVICES:
                    raise ValueError("device_limit")
                for row in devices:
                    self._configuration(row)
                for table, tagger, limit in (
                    ("epaper_previews", self._preview_tag, MAX_POLLS),
                    ("epaper_polls", self._poll_tag, MAX_POLLS),
                ):
                    rows = connection.execute(f"SELECT * FROM {table} LIMIT ?", (limit + 1,)).fetchall()
                    if len(rows) > limit or any(
                        not hmac.compare_digest(row["authentication_tag"], tagger(row))
                        for row in rows
                    ):
                        raise ValueError("invalid_epaper_records")
                provider_rows = connection.execute(
                    "SELECT * FROM epaper_provider_commands LIMIT ?", (MAX_POLLS + 1,)
                ).fetchall()
                if len(provider_rows) > MAX_POLLS:
                    raise ValueError("invalid_epaper_records")
                for row in provider_rows:
                    self._provider_row(connection, row["request_id"])
        except (ValueError, TypeError, json.JSONDecodeError, OverflowError):
            raise StartupError("epaper_snapshot_storage_invalid") from None
