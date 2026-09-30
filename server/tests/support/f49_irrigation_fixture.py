"""Real TCP Home Assistant/OpenSprinkler fixture for F49 acceptance gates."""

from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import socket
import threading
from urllib.parse import parse_qs, urlsplit


TOKEN = "f49-synthetic-home-assistant-token"
PASSWORD_MD5 = "d" * 32


class IrrigationFixture:
    """Serve the exact read and timed-controller routes used by normal Core."""

    def __init__(self, now):
        self.now = int(now)
        self.token = TOKEN
        self.password_md5 = PASSWORD_MD5
        self.calls = []
        self.errors = []
        self.command_calls = []
        self.controller_snapshots = 0
        self.phase = "idle"
        self.device_time = self.now
        self.boot_time = self.now - 100
        self.flow_pulses = 100
        self.last_run = [0, 0, 0, 0]
        self.duration = 0
        self.lose_next_run_ack = False
        self._snapshot_callback_at = None
        self._snapshot_callback = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def reply(self, value, *, status=200):
                body = json.dumps(value, separators=(",", ":")).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                try:
                    split = urlsplit(self.path)
                    owner.calls.append(("GET", split.path))
                    if split.path.startswith("/api/states/"):
                        assert self.headers.get("Authorization") == "Bearer " + owner.token
                        self.reply(owner.ha_state(split.path.removeprefix("/api/states/")))
                        return
                    query = parse_qs(split.query, keep_blank_values=True)
                    assert query.pop("pw") == [owner.password_md5]
                    if split.path == "/cm":
                        owner.command(split.path, query, self)
                        return
                    self.reply(owner.controller_read(split.path, query))
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception as error:  # fixture failures remain visible to the runner.
                    owner.errors.append(f"{type(error).__name__}:{error}")
                    try:
                        self.reply({}, status=503)
                    except (BrokenPipeError, ConnectionResetError):
                        pass

            def do_POST(self):
                try:
                    split = urlsplit(self.path)
                    owner.calls.append(("POST", split.path))
                    assert split.path == "/api/services/weather/get_forecasts"
                    assert self.headers.get("Authorization") == "Bearer " + owner.token
                    assert self.headers.get("Content-Type") == "application/json"
                    query = parse_qs(split.query, keep_blank_values=True)
                    assert query == {"return_response": [""]}
                    length = int(self.headers.get("Content-Length", "0"))
                    assert json.loads(self.rfile.read(length)) == {
                        "entity_id": "weather.garden",
                        "type": "hourly",
                    }
                    forecast_at = datetime.fromtimestamp(
                        owner.now + 3600, timezone.utc
                    ).isoformat()
                    self.reply({
                        "changed_states": [],
                        "service_response": {
                            "weather.garden": {
                                "forecast": [{
                                    "datetime": forecast_at,
                                    "precipitation": 1.25,
                                }]
                            }
                        },
                    })
                except Exception as error:
                    owner.errors.append(f"{type(error).__name__}:{error}")
                    self.reply({}, status=503)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def after_controller_snapshots(self, count, callback):
        assert type(count) is int and count > 0 and callable(callback)
        self._snapshot_callback_at = self.controller_snapshots + count
        self._snapshot_callback = callback

    def ha_state(self, entity):
        observed = datetime.fromtimestamp(self.now - 10, timezone.utc).isoformat()
        reset = datetime.fromtimestamp(self.now - 3600, timezone.utc).isoformat()
        next_reset = datetime.fromtimestamp(
            self.now + 23 * 3600, timezone.utc
        ).isoformat()
        values = {
            "weather.garden": (
                "sunny",
                {
                    "temperature": 15.5,
                    "temperature_unit": "°C",
                    "wind_speed": 2.5,
                    "wind_speed_unit": "m/s",
                    "precipitation_unit": "mm",
                },
            ),
            "binary_sensor.garden_leak": (
                "off",
                {"device_class": "moisture"},
            ),
            "sensor.daily_irrigation_water": (
                "12.5",
                {
                    "device_class": "water",
                    "unit_of_measurement": "L",
                    "state_class": "total_increasing",
                    "last_reset": reset,
                    "next_reset": next_reset,
                },
            ),
            "sensor.back_soil": (
                "30",
                {"device_class": "moisture", "unit_of_measurement": "%"},
            ),
            "valve.back_garden": ("closed", {"device_class": "water"}),
        }
        state, attributes = values[entity]
        return {
            "entity_id": entity,
            "state": state,
            "attributes": attributes,
            "last_changed": observed,
            "last_updated": observed,
        }

    def _status(self):
        running = self.phase == "running"
        return {
            "devt": self.device_time,
            "lupt": self.boot_time,
            "lrun": self.last_run,
            "sbits": [1 if running else 0],
            "ps": (
                [[99, self.duration, self.device_time, 0]]
                if running
                else [[0, 0, 0, 0]]
            ) + [[0, 0, 0, 0] for _ in range(7)],
            "flwrt": 1,
            "flcrt": 1 if running else 0,
            "flcto": self.flow_pulses,
            "nq": 1 if running else 0,
            "en": 1,
            "ocs": 0,
        }

    def controller_read(self, path, query):
        assert query == {}
        if path == "/jo":
            return {
                "fwv": 221,
                "fwm": 5,
                "sn1t": 2,
                "fpr0": 1,
                "fpr1": 0,
                "mas": 0,
                "mas2": 0,
                "mas3": 0,
                "mas4": 0,
            }
        if path == "/jn":
            return {"stn_dis": [0], "stn_spe": [0]}
        if path == "/jc":
            return self._status()
        if path != "/js":
            raise AssertionError("unexpected_controller_path")
        running = self.phase == "running"
        result = {"sn": [1 if running else 0] + [0] * 7, "nstations": 8}
        self.controller_snapshots += 1
        if self._snapshot_callback_at == self.controller_snapshots:
            callback, self._snapshot_callback = self._snapshot_callback, None
            self._snapshot_callback_at = None
            callback()
        if running:
            self.phase = "idle"
            self.device_time += self.duration
            expected_ml = max(1, self.duration * 4_000 // 60)
            self.flow_pulses += max(1, expected_ml // 10)
            self.last_run = [0, 99, self.duration, self.device_time]
        return result

    def command(self, path, query, handler):
        assert path == "/cm"
        assert query.get("sid") == ["0"]
        assert query.get("qo") == ["1"]
        assert query.get("en") == ["1"]
        assert set(query) == {"sid", "en", "t", "qo"}
        duration = int(query["t"][0])
        assert 1 <= duration <= 7_200
        self.command_calls.append((path, dict(query)))
        self.duration = duration
        self.phase = "running"
        if self.lose_next_run_ack:
            self.lose_next_run_ack = False
            handler.close_connection = True
            try:
                handler.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            handler.connection.close()
            return
        handler.reply({"result": 1})


def source_body(service, room, *, expected_revision=None):
    return {
        "schemaVersion": 1,
        "expectedRevision": expected_revision,
        "serviceId": service["id"],
        "expectedServiceRevision": service["revision"],
        "weatherEntityId": "weather.garden",
        "leakEntityId": "binary_sensor.garden_leak",
        "dailyWaterEntityId": "sensor.daily_irrigation_water",
        "targetMoisturePermille": 600,
        "soilMaxAgeMs": 60_000,
        "safetyMaxAgeMs": 60_000,
        "forecastMaxAgeMs": 6 * 60 * 60 * 1000,
        "rainDeferralMilliMm": 4_000,
        "freezeThresholdMilliC": 2_000,
        "windLimitMilliMps": 12_000,
        "previewTtlMs": 30_000,
        "dailyLimitMl": 100_000,
        "priceMicrosPerLiter": 2_500_000,
        "zones": [{
            "roomId": room["ref"]["id"],
            "roomRevision": room["revision"],
            "valveEntityId": "valve.back_garden",
            "soilMoistureEntityId": "sensor.back_soil",
            "plantName": "Tomatoes",
            "flowMlPerMinute": 4_000,
            "maxDurationSeconds": 900,
        }],
    }


def provision_inventory(client, core, actor, upstream):
    """Create only public room/service inventory through normal admin routes."""
    from conftest import auth

    headers = auth(actor)
    scope = core.context
    room_response = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=headers,
        json={"kind": "room", "label": "Back garden", "order": 0},
    )
    assert room_response.status_code == 201, room_response.text
    service_response = client.post(
        "/api/v1/admin/services",
        headers=headers,
        json={
            "kind": "home_assistant",
            "name": "Garden Home Assistant",
            "baseUrl": upstream.url,
            "credentials": {"token": upstream.token},
        },
    )
    assert service_response.status_code == 201, service_response.text
    return service_response.json()["service"], room_response.json()["record"]


def configure_irrigation(client, actor, upstream, service, room):
    """Configure the source/controller through the same routes used by Flutter."""
    from conftest import auth

    headers = auth(actor)
    source = client.put(
        "/api/v1/admin/irrigation-budget/source",
        headers=headers,
        json=source_body(service, room),
    )
    assert source.status_code == 200, source.text
    source_value = source.json()["source"]
    zone = source.json()["controlZones"][0]
    controller = client.put(
        "/api/v1/admin/irrigation-budget/controller",
        headers=headers,
        json={
            "schemaVersion": 1,
            "expectedRevision": None,
            "expectedSourceRevision": source_value["revision"],
            "baseUrl": upstream.url,
            "passwordMd5": upstream.password_md5,
            "stations": [{
                "zoneId": zone["zoneId"],
                "expectedZoneRevision": zone["zoneRevision"],
                "stationIndex": 0,
            }],
        },
    )
    assert controller.status_code == 200, controller.text
    return source_value, zone, controller.json()["controller"]
