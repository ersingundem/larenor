"""Normal Core acceptance for authenticated HA MQTT-room discovery and reads."""

import base64
from datetime import datetime, timezone
import hashlib
import json
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

from fastapi.testclient import TestClient

from conftest import auth, login, ready
from larenor_server.app import create_app
from larenor_server.errors import ApiError


class MqttRoomHomeAssistant(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    observed_ms = 0
    room = "living"
    entity = "sensor.owner_room"
    unique_id = "private-ble-device-id"
    name = "Owner room"
    after_registry = None
    requests = []

    def log_message(self, *_args):
        pass

    def _send(self, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        type(self).requests.append(("GET", self.path, self.headers.get("Authorization")))
        if self.path == "/api/websocket":
            self._websocket()
            return
        assert self.headers["Authorization"] == "Bearer private-ha-token"
        if self.path != "/api/states/" + type(self).entity:
            self.send_error(404)
            return
        stamp = datetime.fromtimestamp(
            type(self).observed_ms / 1000, tz=timezone.utc
        ).isoformat()
        self._send({
            "entity_id": type(self).entity,
            "state": type(self).room,
            "attributes": {"distance": 1.25},
            "last_updated": stamp,
        })

    def _websocket(self):
        key = self.headers["Sec-WebSocket-Key"]
        accept = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
        ).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self._write({"type": "auth_required"})
        assert self._read() == {
            "type": "auth", "access_token": "private-ha-token",
        }
        self._write({"type": "auth_ok"})
        assert self._read() == {
            "id": 1, "type": "config/entity_registry/list",
        }
        self._write({
            "id": 1, "type": "result", "success": True,
            "result": [{
                "entity_id": type(self).entity,
                "unique_id": type(self).unique_id,
                "platform": "mqtt_room",
                "name": type(self).name,
                "disabled_by": None,
                "hidden_by": None,
            }, {
                "entity_id": "sensor.unrelated",
                "unique_id": "other",
                "platform": "mqtt",
                "disabled_by": None,
                "hidden_by": None,
            }],
        })
        callback = type(self).after_registry
        if callback is not None:
            callback()

    def _exact(self, count):
        value = bytearray()
        while len(value) < count:
            part = self.rfile.read(count - len(value))
            if not part:
                raise EOFError
            value.extend(part)
        return bytes(value)

    def _read(self):
        _first, second = self._exact(2)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._exact(2))[0]
        mask = self._exact(4)
        payload = self._exact(length)
        return json.loads(bytes(
            child ^ mask[index % 4]
            for index, child in enumerate(payload)
        ))

    def _write(self, value):
        payload = json.dumps(value, separators=(",", ":")).encode()
        header = (
            bytes((0x81, len(payload))) if len(payload) < 126
            else b"\x81\x7e" + struct.pack("!H", len(payload))
        )
        self.wfile.write(header + payload)
        self.wfile.flush()


def test_normal_core_discovers_calibrates_and_restarts_real_mqtt_room_source(server):
    app, client, settings, clock = server
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), MqttRoomHomeAssistant)
    thread = Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    upstream_stopped = False
    try:
        now_ms = int(clock.now * 1000)
        MqttRoomHomeAssistant.observed_ms = now_ms - 1000
        MqttRoomHomeAssistant.entity = "sensor.owner_room"
        MqttRoomHomeAssistant.unique_id = "private-ble-device-id"
        MqttRoomHomeAssistant.name = "Owner room"
        MqttRoomHomeAssistant.room = "living"
        MqttRoomHomeAssistant.after_registry = None
        MqttRoomHomeAssistant.requests = []
        pair = ready(server)
        headers = auth(pair)
        context = app.state.core.context
        resources = f"/api/v1/admin/home-resources/{context.coreId}/{context.homeId}"
        room = client.post(resources, headers=headers, json={
            "kind": "room", "label": "Living room", "order": 0,
        }).json()["record"]
        service = client.post(
            "/api/v1/admin/services", headers=headers, json={
                "name": "Home Assistant", "kind": "home_assistant",
                "baseUrl": f"http://127.0.0.1:{upstream.server_port}",
                "credentials": {"token": "private-ha-token"},
            },
        ).json()["service"]
        actor = app.state.core.auth.authenticate(pair["accessToken"])
        app.state.core.services.record_verification(
            actor, service["id"], 1,
            state="authenticated", version="2026.9",
        )
        root = f"/api/v1/room-presence/{context.coreId}/{context.homeId}"
        setup = client.get(root + "/configuration/setup", headers=headers)
        assert setup.status_code == 200, setup.text
        assert setup.json()["grantsAccess"] is False
        entities = client.get(
            root + f"/configuration/entities/{service['id']}/1",
            headers=headers,
        )
        assert entities.status_code == 200, entities.text
        entity = entities.json()["entities"][0]
        assert entity["schemaVersion"] == 1
        assert entity["entityId"] == "sensor.owner_room"
        assert entity["name"] == "Owner room"
        assert entity["platform"] == "mqtt_room"
        assert len(entity["candidateId"]) == 64
        assert "private-ble-device-id" not in entities.text
        configured = client.put(root + "/configuration", headers=headers, json={
            "schemaVersion": 1,
            "expectedRevision": None,
            "serviceId": service["id"],
            "expectedServiceRevision": 1,
            "entityId": "sensor.owner_room",
            "candidateId": entity["candidateId"],
            "roomId": room["ref"]["id"],
            "expectedRoomRevision": room["revision"],
            "maxSignalAgeMs": 30_000,
            "consent": True,
        })
        assert configured.status_code == 200, configured.text
        assert configured.json()["configuration"]["grantsAccess"] is False
        assert "private-ble-device-id" not in configured.text
        assert '"living"' not in configured.text

        authority = client.post(root + "/scope", headers=headers, json={
            "schemaVersion": 1,
            "routeId": "e" * 32,
            "routeRevision": 1,
            "clientSessionRevision": 1,
        }).json()
        first = client.post(root + "/devices/query", headers=headers, json={
            "schemaVersion": 1, "authority": authority,
        })
        assert first.status_code == 200, first.text
        assert first.json()["devices"][0]["state"] == "candidate"
        MqttRoomHomeAssistant.observed_ms = now_ms
        second = client.post(root + "/devices/query", headers=headers, json={
            "schemaVersion": 1, "authority": authority,
        })
        assert second.status_code == 200, second.text
        evidence = second.json()["devices"][0]
        assert evidence["state"] == "present"
        assert evidence["sourceKinds"] == ["ha_mqtt_room"]
        assert evidence["advisoryOnly"] is True
        assert evidence["grantsAccess"] is False
        assert "private-ble-device-id" not in second.text
        assert 1 <= evidence["lastObservationAtMs"] <= 2**53 - 1

        MqttRoomHomeAssistant.entity = "sensor.guest_room"
        MqttRoomHomeAssistant.unique_id = "private-guest-ble-id"
        MqttRoomHomeAssistant.name = "Guest room"
        MqttRoomHomeAssistant.room = "bedroom"
        replacement = client.get(
            root + f"/configuration/entities/{service['id']}/1",
            headers=headers,
        ).json()["entities"][0]
        replaced = client.put(root + "/configuration", headers=headers, json={
            "schemaVersion": 1,
            "expectedRevision": 1,
            "serviceId": service["id"],
            "expectedServiceRevision": 1,
            "entityId": "sensor.guest_room",
            "candidateId": replacement["candidateId"],
            "roomId": room["ref"]["id"],
            "expectedRoomRevision": room["revision"],
            "maxSignalAgeMs": 30_000,
            "consent": True,
        })
        assert replaced.status_code == 200, replaced.text
        assert "bedroom" not in replaced.text
        private_source = app.state.core.room_presence.source_store.internal_source()
        assert private_source.entityUniqueId == "private-guest-ble-id"
        assert [item.providerToken for item in private_source.mappings] == ["bedroom"]

        MqttRoomHomeAssistant.observed_ms = now_ms - 500
        with TestClient(create_app(settings)) as restarted:
            durable_authority = restarted.post(
                root + "/scope", headers=headers, json={
                    "schemaVersion": 1, "routeId": "e" * 32,
                    "routeRevision": 1, "clientSessionRevision": 1,
                },
            ).json()
            durable = restarted.post(
                root + "/devices/query", headers=headers,
                json={"schemaVersion": 1, "authority": durable_authority},
            )
            assert durable.status_code == 200, durable.text
            devices = durable.json()["devices"]
            assert [item["state"] for item in devices] == ["candidate"]
            assert all(item["grantsAccess"] is False for item in devices)
            MqttRoomHomeAssistant.observed_ms = now_ms
            durable_second = restarted.post(
                root + "/devices/query", headers=headers,
                json={"schemaVersion": 1, "authority": durable_authority},
            )
            assert durable_second.status_code == 200, durable_second.text
            assert durable_second.json()["devices"][0]["state"] == "present"

        previous_source = app.state.core.room_presence.source_store.internal_source()
        repository = app.state.core.room_presence.repository
        original_register = repository.register_provider_in_transaction

        def registration_failure(*_args, **_kwargs):
            raise ApiError("revision_conflict", 409)

        repository.register_provider_in_transaction = registration_failure
        try:
            failed_registration = client.put(
                root + "/configuration", headers=headers, json={
                    "schemaVersion": 1,
                    "expectedRevision": 2,
                    "serviceId": service["id"],
                    "expectedServiceRevision": 1,
                    "entityId": "sensor.guest_room",
                    "candidateId": replacement["candidateId"],
                    "roomId": room["ref"]["id"],
                    "expectedRoomRevision": room["revision"],
                    "maxSignalAgeMs": 45_000,
                    "consent": True,
                },
            )
        finally:
            repository.register_provider_in_transaction = original_register
        assert failed_registration.status_code == 409, failed_registration.text
        assert (
            app.state.core.room_presence.source_store.internal_source()
            == previous_source
        )
        unchanged = client.get(root + "/configuration", headers=headers)
        assert unchanged.status_code == 200, unchanged.text
        assert unchanged.json()["configuration"]["revision"] == 2
        assert unchanged.json()["configuration"]["maxSignalAgeMs"] == 30_000
        unchanged_reducer = client.post(
            root + "/devices/query", headers=headers,
            json={"schemaVersion": 1, "authority": authority},
        )
        assert unchanged_reducer.status_code == 200, unchanged_reducer.text
        assert unchanged_reducer.json()["devices"][0]["policyRevision"] == 2

        state_reads = len([
            item for item in MqttRoomHomeAssistant.requests
            if item[1].startswith("/api/states/")
        ])
        MqttRoomHomeAssistant.after_registry = lambda: app.state.core.auth.logout(actor)
        revoked = client.put(root + "/configuration", headers=headers, json={
            "schemaVersion": 1,
            "expectedRevision": 2,
            "serviceId": service["id"],
            "expectedServiceRevision": 1,
            "entityId": "sensor.guest_room",
            "candidateId": replacement["candidateId"],
            "roomId": room["ref"]["id"],
            "expectedRoomRevision": room["revision"],
            "maxSignalAgeMs": 30_000,
            "consent": True,
        })
        assert revoked.status_code == 401, revoked.text
        assert len([
            item for item in MqttRoomHomeAssistant.requests
            if item[1].startswith("/api/states/")
        ]) == state_reads

        fresh_pair = login(
            client, "admin", "Synthetic new password 2026", "Revoke tablet"
        ).json()
        fresh_headers = auth(fresh_pair)
        upstream.shutdown()
        thread.join(timeout=5)
        upstream.server_close()
        upstream_stopped = True

        offline_metadata = client.get(
            root + "/configuration", headers=fresh_headers
        )
        assert offline_metadata.status_code == 200, offline_metadata.text
        assert offline_metadata.json()["configuration"]["consentActive"] is True
        revoked_offline = client.post(
            root + "/configuration/consent/revoke",
            headers=fresh_headers,
            json={"schemaVersion": 1, "expectedRevision": 2},
        )
        assert revoked_offline.status_code == 200, revoked_offline.text
        assert revoked_offline.json()["configuration"]["revision"] == 3
        assert revoked_offline.json()["configuration"]["consentActive"] is False
        stale_revoke = client.post(
            root + "/configuration/consent/revoke",
            headers=fresh_headers,
            json={"schemaVersion": 1, "expectedRevision": 2},
        )
        assert stale_revoke.status_code == 409, stale_revoke.text

        revoked_authority = client.post(
            root + "/scope", headers=fresh_headers, json={
                "schemaVersion": 1,
                "routeId": "d" * 32,
                "routeRevision": 1,
                "clientSessionRevision": 1,
            },
        ).json()
        no_evidence = client.post(
            root + "/devices/query", headers=fresh_headers,
            json={"schemaVersion": 1, "authority": revoked_authority},
        )
        assert no_evidence.status_code == 200, no_evidence.text
        assert no_evidence.json()["devices"] == []

        with TestClient(create_app(settings)) as revoked_restart:
            retained = revoked_restart.get(
                root + "/configuration", headers=fresh_headers
            )
            assert retained.status_code == 200, retained.text
            assert retained.json()["configuration"]["consentActive"] is False
            restarted_authority = revoked_restart.post(
                root + "/scope", headers=fresh_headers, json={
                    "schemaVersion": 1,
                    "routeId": "c" * 32,
                    "routeRevision": 1,
                    "clientSessionRevision": 1,
                },
            ).json()
            restarted_devices = revoked_restart.post(
                root + "/devices/query", headers=fresh_headers,
                json={
                    "schemaVersion": 1,
                    "authority": restarted_authority,
                },
            )
            assert restarted_devices.status_code == 200, restarted_devices.text
            assert restarted_devices.json()["devices"] == []

        assert all(
            token in {None, "Bearer private-ha-token"}
            for _method, _path, token in MqttRoomHomeAssistant.requests
        )
    finally:
        if not upstream_stopped:
            upstream.shutdown()
            thread.join(timeout=5)
            upstream.server_close()
