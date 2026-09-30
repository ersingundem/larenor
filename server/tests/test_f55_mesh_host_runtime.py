import json
import os
from pathlib import Path
import shutil
import socket
import struct
import tempfile
import threading
import time

from fastapi.testclient import TestClient

from larenor_server.config import Settings
from larenor_server.mesh_center.mqtt_transport import (
    MqttBrokerConfig,
    MqttRetainedObserver,
)
from larenor_server.mesh_center.worker_ipc import (
    Zigbee2MqttWorkerServer,
)
from larenor_server.runtime import create_configured_app

from conftest import auth, bootstrap_password, login


def _remaining(value):
    result = bytearray()
    while True:
        digit = value % 128
        value //= 128
        result.append(digit | (0x80 if value else 0))
        if not value:
            return bytes(result)


def _packet(kind, body):
    return bytes([kind]) + _remaining(len(body)) + body


def _field(value):
    return struct.pack("!H", len(value)) + value


def _publish(topic, payload, *, retained=True):
    return _packet(0x31 if retained else 0x30, _field(topic.encode()) + payload)


def _read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        part = stream.recv(count - len(result))
        if not part:
            raise OSError
        result.extend(part)
    return bytes(result)


def _read_packet(stream):
    kind = _read_exact(stream, 1)[0]
    multiplier = 1
    size = 0
    while True:
        digit = _read_exact(stream, 1)[0]
        size += (digit & 127) * multiplier
        if digit & 128 == 0:
            return kind, _read_exact(stream, size)
        multiplier *= 128


def _fixture_address():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        return probe.getsockname()[0]
    finally:
        probe.close()


class _Broker:
    def __init__(self):
        self.address = _fixture_address()
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind((self.address, 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.health_requests = []
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def start(self):
        self.thread.start()

    def _serve(self):
        stream, _peer = self.listener.accept()
        with stream:
            assert _read_packet(stream)[0] >> 4 == 1
            stream.sendall(_packet(0x20, b"\x00\x00"))
            assert _read_packet(stream)[0] >> 4 == 8
            stream.sendall(_packet(0x90, b"\x00\x01\x00"))
            base = "home/zigbee"
            info = {
                "coordinator": {
                    "ieee_address": "0x00124b00120144ae",
                    "meta": {"majorrel": 2, "minorrel": 7, "maintrel": 2},
                },
                "network": {"channel": 15},
            }
            for topic, payload in (
                (base + "/bridge/state", b'{"state":"online"}'),
                (base + "/bridge/info", json.dumps(info).encode()),
                (base + "/bridge/devices", b"[]"),
            ):
                stream.sendall(_publish(topic, payload))
            kind, body = _read_packet(stream)
            assert kind >> 4 == 3
            topic_size = struct.unpack("!H", body[:2])[0]
            topic = body[2 : 2 + topic_size].decode()
            request = json.loads(body[2 + topic_size :])
            self.health_requests.append((topic, request))
            response = json.dumps(
                {
                    "data": {"healthy": True},
                    "status": "ok",
                    "transaction": request["transaction"],
                },
                separators=(",", ":"),
            ).encode()
            stream.sendall(
                _publish(
                    base + "/bridge/response/health_check",
                    response,
                    retained=False,
                )
            )
            time.sleep(0.4)

    def close(self):
        self.listener.close()
        self.thread.join(timeout=2)


def test_normal_core_reads_real_tcp_broker_through_private_worker(tmp_path):
    broker = _Broker()
    broker.start()
    ipc = Path(tempfile.mkdtemp(prefix="mesh-core-", dir=Path.home()))
    os.chown(ipc, os.geteuid(), os.getegid())
    socket_path = ipc / "mesh.sock"
    config = MqttBrokerConfig.parse(
        f"mqtt://broker.internal:{broker.port}",
        base_topic="home/zigbee",
        allowed_addresses=(broker.address,),
    )
    worker = Zigbee2MqttWorkerServer(
        socket_path,
        MqttRetainedObserver(config, clock=lambda: 2_000),
        owner_uid=os.geteuid(),
        peer_uid=os.geteuid(),
        socket_gid=os.getegid(),
    ).bind()
    worker_thread = threading.Thread(target=worker.serve_forever, daemon=True)
    worker_thread.start()
    settings = Settings(
        tmp_path / "data",
        tmp_path / "secrets/vault.key",
        clock=lambda: 2_000,
        mesh_center_worker_socket=socket_path,
        mesh_center_worker_uid=os.geteuid(),
        mesh_center_worker_socket_gid=os.getegid(),
    )
    try:
        app = create_configured_app(settings)
        with TestClient(app) as client:
            password = bootstrap_password(settings)
            signed_in = login(client, "admin", password).json()
            credentials = client.post(
                "/api/v1/auth/password",
                headers=auth(signed_in),
                json={
                    "currentPassword": password,
                    "newPassword": "Synthetic new password 2026",
                },
            ).json()
            context = app.state.core.context
            response = client.get(
                f"/api/v1/admin/mesh-center/{context.coreId}/{context.homeId}",
                headers=auth(credentials),
            )
    finally:
        worker.close()
        worker_thread.join(timeout=2)
        broker.close()
        shutil.rmtree(ipc)

    assert response.status_code == 200
    assert response.json()["snapshot"]["topology"]["devices"] == []
    assert broker.health_requests[0][0] == "home/zigbee/bridge/request/health_check"
