import base64
import hashlib
import json
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

from conftest import auth, ready


class HomeAssistantHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    climate = "off"

    def log_message(self, *_args):
        pass

    def _send(self, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(length))
        assert self.headers["Authorization"] == "Bearer synthetic-ha-token"
        if self.path == "/api/services/climate/set_hvac_mode":
            assert body == {
                "entity_id": "climate.living_room",
                "hvac_mode": "heat",
            }
            type(self).climate = "heat"
            self._send([])
            return
        self.send_error(404)

    def do_GET(self):
        if self.path == "/api/websocket":
            self._websocket()
            return
        assert self.headers["Authorization"] == "Bearer synthetic-ha-token"
        if not self.path.startswith("/api/states/"):
            self.send_error(404)
            return
        entity = self.path.removeprefix("/api/states/")
        state, attributes = {
            "sensor.living_temperature": ("19", {"unit_of_measurement": "°C"}),
            "sensor.living_humidity": ("50", {"unit_of_measurement": "%"}),
            "sensor.living_co2": ("700", {"unit_of_measurement": "ppm"}),
            "sensor.living_voc": ("200", {"unit_of_measurement": "ppb"}),
            "binary_sensor.living_smoke": ("off", {"device_class": "smoke"}),
            "binary_sensor.living_occupancy": ("on", {"device_class": "occupancy"}),
            "cover.living_room_window": (
                "closed", {"supported_features": 3},
            ),
            "weather.home": (
                "sunny", {"temperature": 12, "temperature_unit": "°C"},
            ),
            "sensor.outdoor_aqi": ("40", {"unit_of_measurement": "AQI"}),
        }.get(entity, (None, None))
        if entity == "climate.living_room":
            state, attributes = type(self).climate, {
                "hvac_modes": ["off", "heat", "cool", "fan_only"],
            }
        if state is None:
            self.send_error(404)
            return
        changed = (
            "2026-09-05T12:00:00+00:00"
            if entity == "climate.living_room" and state == "heat"
            else "2026-09-05T11:59:59+00:00"
        )
        self._send({
            "entity_id": entity,
            "state": state,
            "attributes": attributes,
            "last_updated": changed,
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
        self._write_frame({"type": "auth_required"})
        assert self._read_frame() == {
            "type": "auth", "access_token": "synthetic-ha-token",
        }
        self._write_frame({"type": "auth_ok"})
        command = self._read_frame()
        assert command == {"id": 1, "type": "config/entity_registry/list"}
        entities = [
            "weather.home", "sensor.outdoor_aqi",
            "climate.living_room", "cover.living_room_window",
            "sensor.living_temperature", "sensor.living_humidity",
            "sensor.living_co2", "sensor.living_voc",
            "binary_sensor.living_smoke",
            "binary_sensor.living_occupancy",
        ]
        self._write_frame({
            "id": 1,
            "type": "result",
            "success": True,
            "result": [
                {
                    "entity_id": entity,
                    "disabled_by": None,
                    "hidden_by": None,
                }
                for entity in entities
            ],
        })

    def _read_exact(self, count):
        value = bytearray()
        while len(value) < count:
            part = self.rfile.read(count - len(value))
            if not part:
                raise EOFError
            value.extend(part)
        return bytes(value)

    def _read_frame(self):
        _first, second = self._read_exact(2)
        length = second & 0x7f
        if length == 126:
            length = struct.unpack("!H", self._read_exact(2))[0]
        mask = self._read_exact(4)
        payload = self._read_exact(length)
        return json.loads(bytes(
            child ^ mask[index % 4]
            for index, child in enumerate(payload)
        ))

    def _write_frame(self, value):
        payload = json.dumps(value, separators=(",", ":")).encode()
        header = (
            bytes((0x81, len(payload)))
            if len(payload) < 126
            else b"\x81\x7e" + struct.pack("!H", len(payload))
        )
        self.wfile.write(header + payload)
        self.wfile.flush()


def _configuration(service, room, area):
    return {
        "schemaVersion": 1,
        "expectedRevision": None,
        "serviceId": service["id"],
        "expectedServiceRevision": 1,
        "weatherEntityId": "weather.home",
        "aqiEntityId": "sensor.outdoor_aqi",
        "targetTemperatureMilliC": 22000,
        "temperatureToleranceMilliC": 1000,
        "humidityHighPermille": 700,
        "co2HighPpm": 1000,
        "vocHighPpb": 500,
        "outdoorAqiLimit": 100,
        "freezeThresholdMilliC": 3000,
        "indoorMaxAgeMs": 60000,
        "outdoorMaxAgeMs": 120000,
        "occupancyMaxAgeMs": 60000,
        "previewTtlMs": 30000,
        "rooms": [{
            "roomId": room["ref"]["id"],
            "roomRevision": room["revision"],
            "areaId": area["ref"]["id"],
            "areaRevision": area["revision"],
            "climateEntityId": "climate.living_room",
            "windowEntityId": "cover.living_room_window",
            "temperatureEntityId": "sensor.living_temperature",
            "humidityEntityId": "sensor.living_humidity",
            "co2EntityId": "sensor.living_co2",
            "vocEntityId": "sensor.living_voc",
            "smokeEntityId": "binary_sensor.living_smoke",
            "occupancyEntityId": "binary_sensor.living_occupancy",
        }],
    }


def test_normal_core_refresh_and_confirm_use_real_ha_tcp_boundary(server):
    app, client, _settings, _clock = server
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), HomeAssistantHandler)
    thread = Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    try:
        HomeAssistantHandler.climate = "off"
        pair = ready(server)
        headers = auth(pair)
        context = app.state.core.context
        resources = (
            f"/api/v1/admin/home-resources/{context.coreId}/{context.homeId}"
        )
        room = client.post(resources, headers=headers, json={
            "kind": "room", "label": "Living room", "order": 0,
        }).json()["record"]
        area = client.post(resources, headers=headers, json={
            "kind": "resource", "label": "Downstairs", "order": 0,
        }).json()["record"]
        service = client.post(
            "/api/v1/admin/services", headers=headers, json={
                "name": "Home Assistant",
                "kind": "home_assistant",
                "baseUrl": f"http://127.0.0.1:{upstream.server_port}",
                "credentials": {"token": "synthetic-ha-token"},
            },
        ).json()["service"]
        actor = app.state.core.auth.authenticate(pair["accessToken"])
        app.state.core.services.record_verification(
            actor, service["id"], 1,
            state="authenticated", version="2026.9",
        )
        root = f"/api/v1/room-comfort/{context.coreId}/{context.homeId}"
        catalog = client.get(root + "/configuration/setup", headers=headers)
        assert catalog.status_code == 200, catalog.text
        assert catalog.json()["services"][0]["id"] == service["id"]
        entities = client.get(
            root + f"/configuration/entities/{service['id']}/1",
            headers=headers,
        )
        assert entities.status_code == 200, entities.text
        assert entities.json()["entities"]["climate"] == [
            "climate.living_room"
        ]
        configured = client.put(
            root + "/configuration", headers=headers,
            json=_configuration(service, room, area),
        )
        assert configured.status_code == 200, configured.text

        refreshed = client.post(root + "/plan/refresh", headers=headers)
        assert refreshed.status_code == 200, refreshed.text
        plan = refreshed.json()["plan"]
        assert plan["items"][0]["hvacMode"] == "heat"
        preview = client.post(root + "/previews", headers=headers, json={
            "schemaVersion": 1,
            "requestId": "f" * 32,
            "expectedPlanId": plan["planId"],
            "expectedHomeRevision": plan["homeRevision"],
            "expectedPolicyRevision": plan["policyRevision"],
        }).json()["preview"]
        confirmed = client.post(
            root + f"/previews/{preview['previewId']}/confirm",
            headers=headers,
            json={
                "schemaVersion": 1,
                "expectedPlanId": plan["planId"],
                "expectedPolicyRevision": plan["policyRevision"],
                "confirmToken": preview["confirmToken"],
            },
        )

        assert confirmed.status_code == 201, confirmed.text
        receipt = confirmed.json()["receipt"]
        assert receipt["status"] == "applied"
        assert receipt["results"][0]["readback"]["state"] == "heat"
        state_revision = receipt["results"][0]["readback"]["stateRevision"]
        assert 1 <= state_revision <= 2**53 - 1
        assert json.loads(json.dumps(state_revision)) == state_revision
        assert HomeAssistantHandler.climate == "heat"
    finally:
        upstream.shutdown()
        thread.join(timeout=5)
        upstream.server_close()
