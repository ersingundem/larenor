import os
from pathlib import Path
import shutil
import tempfile
import threading

import pytest

from larenor_server.mesh_center.worker_ipc import (
    MeshWorkerError,
    Zigbee2MqttWorkerClient,
    Zigbee2MqttWorkerServer,
    _observation_from_wire,
)
from larenor_server.mesh_center.worker_runtime import config_from_environment
from larenor_server.mesh_center.zigbee2mqtt_provider import Zigbee2MqttObservation
from larenor_server.mesh_center.managed_ota_transport import (
    ManagedOtaInstallEvidence,
    ManagedOtaOfferEvidence,
)


def observation():
    return Zigbee2MqttObservation(
        revision=19,
        capturedAtMs=2_000_000,
        bridgeState=b'{"state":"online"}',
        bridgeInfo=b'{"coordinator":{},"network":{}}',
        devices=b'[{"friendly_name":"living/room"}]',
        deviceStates={"living/room": b'{"battery":83}'},
        availability={"living/room": b"online"},
    )


class Observer:
    def __init__(self):
        self.timeouts = []

    def observe(self, *, timeout):
        self.timeouts.append(timeout)
        return observation()


class ManagedOta:
    def __init__(self):
        self.calls = []

    def check(self, device_id, revision, *, timeout):
        self.calls.append(("check", device_id, revision, timeout))
        return ManagedOtaOfferEvidence(
            deviceId=device_id,
            providerRevision=20,
            installedFileVersion=5,
            latestFileVersion=10,
            sourceDigest="a" * 64,
            checkedAtMs=2_000_000,
            releaseNotesAvailable=True,
        )

    def install(self, device_id, revision, installed, latest, *, timeout):
        self.calls.append(("install", device_id, revision, installed, latest, timeout))
        return ManagedOtaInstallEvidence(
            deviceId=device_id,
            previousProviderRevision=revision,
            providerRevision=revision + 1,
            fromFileVersion=installed,
            toFileVersion=latest,
            installedFileVersion=latest,
            progressPercent=100,
            completedAtMs=2_100_000,
        )


def test_uid_private_worker_returns_only_bounded_observation():
    directory = Path(tempfile.mkdtemp(prefix="mesh-", dir="/tmp"))
    socket_path = directory / "mesh.sock"
    observer = Observer()
    server = Zigbee2MqttWorkerServer(socket_path, observer).bind()
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        result = Zigbee2MqttWorkerClient(socket_path).observe(timeout=1)
    finally:
        server.close()
        worker.join(timeout=1)
        shutil.rmtree(directory)

    assert result == observation()
    assert 0 < observer.timeouts[0] <= 1
    assert not socket_path.exists()


def test_uid_private_worker_exposes_only_bounded_managed_ota_contract():
    directory = Path(tempfile.mkdtemp(prefix="mesh-", dir="/tmp"))
    socket_path = directory / "mesh.sock"
    managed = ManagedOta()
    server = Zigbee2MqttWorkerServer(
        socket_path, Observer(), managed_ota=managed
    ).bind()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    device_id = "a" * 32
    try:
        client = Zigbee2MqttWorkerClient(socket_path)
        offer = client.check_managed_ota(device_id, 19, timeout=1)
        installed = client.install_managed_ota(device_id, 20, 5, 10, timeout=1)
    finally:
        server.close()
        thread.join(timeout=1)
        shutil.rmtree(directory)

    assert offer.latestFileVersion == 10
    assert installed.installedFileVersion == 10
    assert managed.calls[0][:3] == ("check", device_id, 19)
    assert managed.calls[1][:5] == ("install", device_id, 20, 5, 10)


def test_managed_ota_client_rejects_untrusted_material_before_ipc(tmp_path):
    client = Zigbee2MqttWorkerClient(tmp_path / "missing.sock")

    with pytest.raises(MeshWorkerError, match="invalid_request"):
        client.install_managed_ota("file:///tmp/image.bin", 20, 5, 10)


@pytest.mark.parametrize(
    "change",
    [
        {"bridgeState": ""},
        {"revision": True},
        {"deviceStates": {"bad\0topic": "{}"}},
        {"availability": {str(index): "online" for index in range(1_025)}},
    ],
)
def test_worker_rejects_ambiguous_or_unbounded_observation(change):
    value = {
        "revision": 1,
        "capturedAtMs": 2,
        "bridgeState": '{"state":"online"}',
        "bridgeInfo": "{}",
        "devices": "[]",
        "deviceStates": {},
        "availability": {},
    }
    value.update(change)
    with pytest.raises(MeshWorkerError, match="invalid_response"):
        _observation_from_wire(value)


def write_secret(path: Path, value: str):
    path.write_text(value)
    path.chmod(0o600)


def test_worker_runtime_keeps_credentials_in_private_files(tmp_path):
    username = tmp_path / "mqtt-user"
    password = tmp_path / "mqtt-password"
    write_secret(username, "reader\n")
    write_secret(password, "secret\n")

    result = config_from_environment(
        {
            "LARENOR_MESH_WORKER_SOCKET": str(tmp_path / "mesh.sock"),
            "LARENOR_MESH_CORE_UID": str(os.geteuid()),
            "LARENOR_MESH_MQTT_URL": "mqtts://broker.internal:8883",
            "LARENOR_MESH_MQTT_BASE_TOPIC": "home/zigbee",
            "LARENOR_MESH_MQTT_ALLOWED_ADDRESSES": "192.168.1.10,192.168.1.11",
            "LARENOR_MESH_MQTT_USERNAME_FILE": str(username),
            "LARENOR_MESH_MQTT_PASSWORD_FILE": str(password),
        }
    )

    assert result.broker.username == "reader"
    assert result.broker.password == "secret"
    assert result.broker.allowed_addresses == ("192.168.1.10", "192.168.1.11")
    assert "secret" not in repr(result)


def test_worker_runtime_rejects_world_readable_secret(tmp_path):
    username = tmp_path / "mqtt-user"
    password = tmp_path / "mqtt-password"
    write_secret(username, "reader")
    write_secret(password, "secret")
    password.chmod(0o644)

    with pytest.raises(MeshWorkerError, match="invalid_request"):
        config_from_environment(
            {
                "LARENOR_MESH_WORKER_SOCKET": str(tmp_path / "mesh.sock"),
                "LARENOR_MESH_MQTT_URL": "mqtt://broker.internal",
                "LARENOR_MESH_MQTT_ALLOWED_ADDRESSES": "192.168.1.10",
                "LARENOR_MESH_MQTT_USERNAME_FILE": str(username),
                "LARENOR_MESH_MQTT_PASSWORD_FILE": str(password),
            }
        )


def test_worker_never_replaces_an_existing_socket_path(tmp_path):
    path = tmp_path / "mesh.sock"
    path.write_text("owned evidence")

    with pytest.raises(MeshWorkerError, match="worker_unavailable"):
        Zigbee2MqttWorkerServer(path, Observer()).bind()

    assert path.read_text() == "owned evidence"
