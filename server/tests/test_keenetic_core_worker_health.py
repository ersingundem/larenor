import json
import os
from pathlib import Path
import socket
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import ApiError, StartupError
from larenor_server.keenetic_commands.core_worker import (
    HealthGatedKeeneticWorkerEffect,
    build_keenetic_worker_effect,
)
from larenor_server.keenetic_commands.service import (
    KeeneticEffectError,
    UnavailableKeeneticEffect,
)
from larenor_server.keenetic_commands.worker_runtime import WorkerHealthStore

from conftest import auth, ready
from test_component_egress import grant_body, policy_url
from test_keenetic_command_authority import Actor, request
from test_keenetic_command_worker_ipc import socket_directory
from test_services import create


class Egress:
    def __init__(self, allowed=True):
        self.allowed = allowed
        self.calls = []

    def check_component(self, actor, service_id, revision, component):
        self.calls.append((actor.id, service_id, revision, component))
        if not self.allowed:
            raise ApiError("outbound_denied", 403)
        return SimpleNamespace(
            revision=3,
            grants=[SimpleNamespace(addresses=[
                SimpleNamespace(address="192.168.1.1")
            ])],
        )


class Delegate:
    def __init__(self):
        self.calls = []

    def execute_for_actor(self, actor, body, guard):
        guard()
        self.calls.append((actor.id, body.requestId))
        return body.target


def private_key(path):
    path.write_bytes(b"H" * 32)
    path.chmod(0o600)
    return path


def worker_settings(root, socket_path, health_path, lease_key):
    return Settings(
        root / "data",
        root / "vault.key",
        keenetic_worker_socket=socket_path,
        keenetic_worker_health=health_path,
        keenetic_worker_key_file=lease_key,
        keenetic_worker_uid=os.getuid(),
    )


def publish(listener, path, health, worker_id="a" * 32, pid=None):
    listener.bind(str(path))
    os.chmod(path, 0o600)
    return WorkerHealthStore(health, owner_uid=os.getuid()).publish_ready(
        path, worker_id=worker_id, worker_pid=pid or os.getpid()
    )


@pytest.mark.parametrize("missing", ["socket", "health", "key"])
def test_settings_require_complete_distinct_absolute_worker_identity(tmp_path, missing):
    values = {
        "keenetic_worker_socket": tmp_path / "worker.sock",
        "keenetic_worker_health": tmp_path / "health.json",
        "keenetic_worker_key_file": tmp_path / "lease.key",
        "keenetic_worker_uid": os.getuid(),
    }
    values[f"keenetic_worker_{missing}" if missing != "key" else "keenetic_worker_key_file"] = None
    with pytest.raises(ValueError, match="^invalid_worker_configuration$"):
        Settings(tmp_path / "data", tmp_path / "vault.key", **values)


def test_environment_configuration_is_all_or_nothing_and_redacted(monkeypatch, tmp_path):
    socket_path = tmp_path / "worker.sock"
    health_path = tmp_path / "health.json"
    key_path = tmp_path / "lease.key"
    monkeypatch.setenv("LARENOR_KEENETIC_WORKER_SOCKET", str(socket_path))
    with pytest.raises(StartupError, match="^invalid_worker_configuration$") as caught:
        Settings.from_environment()
    assert str(socket_path) not in str(caught.value)

    monkeypatch.setenv("LARENOR_KEENETIC_WORKER_HEALTH", str(health_path))
    monkeypatch.setenv("LARENOR_KEENETIC_WORKER_KEY_FILE", str(key_path))
    monkeypatch.setenv("LARENOR_KEENETIC_WORKER_UID", str(os.getuid()))
    settings = Settings.from_environment()
    assert settings.keenetic_worker_socket == socket_path
    assert settings.keenetic_worker_health == health_path
    assert settings.keenetic_worker_key_file == key_path


def test_core_binds_only_exact_live_health_identity_and_keeps_checks_read_only(tmp_path):
    with socket_directory() as directory:
        socket_path = directory / "worker.sock"
        health_path = directory / "health.json"
        lease_key = private_key(directory / "lease.key")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        receipt = publish(listener, socket_path, health_path)
        before = (health_path.read_bytes(), health_path.stat().st_mtime_ns)
        settings = worker_settings(tmp_path, socket_path, health_path, lease_key)
        effect = build_keenetic_worker_effect(
            settings, object(), Egress(), process_alive=lambda pid: pid == receipt.workerPid
        )
        assert isinstance(effect, HealthGatedKeeneticWorkerEffect)
        assert (health_path.read_bytes(), health_path.stat().st_mtime_ns) == before
        listener.close()


def test_missing_dead_or_replaced_worker_is_unavailable_without_effect(tmp_path):
    with socket_directory() as directory:
        socket_path = directory / "worker.sock"
        health_path = directory / "health.json"
        lease_key = private_key(directory / "lease.key")
        settings = worker_settings(tmp_path, socket_path, health_path, lease_key)
        assert build_keenetic_worker_effect(settings, object(), Egress()) is None

        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        publish(listener, socket_path, health_path, pid=99999999)
        assert build_keenetic_worker_effect(
            settings, object(), Egress(), process_alive=lambda _pid: False
        ) is None
        listener.close()


def test_replaced_socket_health_or_worker_id_is_rejected_before_delegate(tmp_path):
    with socket_directory() as directory:
        socket_path = directory / "worker.sock"
        health_path = directory / "health.json"
        lease_key = private_key(directory / "lease.key")
        first = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        publish(first, socket_path, health_path)
        effect = HealthGatedKeeneticWorkerEffect(
            worker_settings(tmp_path, socket_path, health_path, lease_key),
            object(), Egress(), process_alive=lambda _pid: True
        )
        delegate = Delegate()
        effect._delegate = delegate
        first.close()
        socket_path.unlink()
        replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        publish(replacement, socket_path, health_path, worker_id="b" * 32)
        with pytest.raises(KeeneticEffectError, match="^keenetic_effect_unavailable$"):
            effect.execute_for_actor(Actor(), request(), lambda: None)
        assert delegate.calls == []
        replacement.close()


def test_missing_egress_or_binding_revision_denies_before_worker_dispatch(tmp_path):
    with socket_directory() as directory:
        socket_path = directory / "worker.sock"
        health_path = directory / "health.json"
        lease_key = private_key(directory / "lease.key")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        publish(listener, socket_path, health_path)
        egress = Egress(allowed=False)
        effect = HealthGatedKeeneticWorkerEffect(
            worker_settings(tmp_path, socket_path, health_path, lease_key),
            object(), egress, process_alive=lambda _pid: True
        )
        delegate = Delegate()
        effect._delegate = delegate
        body = request()
        with pytest.raises(KeeneticEffectError, match="^keenetic_effect_unavailable$"):
            effect.execute_for_actor(Actor(), body, lambda: None)
        assert delegate.calls == []
        assert egress.calls == [(
            Actor().id, body.target.serviceId, body.target.serviceRevision,
            "keenetic_command_worker",
        )]
        listener.close()


def test_keenetic_component_egress_policy_is_revision_bound_and_read_only(server):
    app, client, _, _ = server
    pair = ready(server)
    record = create(
        client,
        pair,
        kind="keenetic",
        baseUrl="http://router.example.test",
        credentials={"username": "fixture", "password": "private"},
    )
    body = grant_body(
        service_revision=record["revision"],
        address="192.168.1.1",
        host="router.example.test",
    )
    body["grants"][0]["scheme"] = "http"
    body["grants"][0]["port"] = 80
    changed = client.put(policy_url(record), headers=auth(pair), json=body)
    assert changed.status_code == 200, changed.text
    assert changed.json()["policy"]["component"] == "keenetic_command_worker"
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    with app.state.core.db.connection() as connection:
        before = connection.execute(
            "SELECT COUNT(*) FROM service_audit"
        ).fetchone()[0]
    policy = app.state.core.component_egress.check_component(
        actor, record["id"], record["revision"], "keenetic_command_worker"
    )
    with app.state.core.db.connection() as connection:
        after = connection.execute(
            "SELECT COUNT(*) FROM service_audit"
        ).fetchone()[0]
    assert policy.revision == 1 and before == after
    assert [item.address for item in policy.grants[0].addresses] == [
        "192.168.1.1"
    ]
    with pytest.raises(ApiError):
        app.state.core.component_egress.check_component(
            actor, record["id"], record["revision"] + 1,
            "keenetic_command_worker",
        )


def test_compose_gives_worker_egress_without_published_ports_and_default_core_is_closed():
    root = Path(__file__).parents[2]
    compose = json.loads(
        (root / "deploy/larenor-server/keenetic-worker.compose.yaml").read_text()
    )
    worker = compose["services"]["larenor-keenetic-worker"]
    assert worker["networks"] == ["keenetic-rci-egress"]
    assert "ports" not in worker and "expose" not in worker
    assert compose["networks"]["keenetic-rci-egress"]["driver"] == "bridge"

    settings = Settings(root / ".test-unused-data", root / ".test-unused-key")
    assert build_keenetic_worker_effect(settings, object(), Egress()) is None
    assert isinstance(UnavailableKeeneticEffect(), UnavailableKeeneticEffect)


def test_core_startup_installs_health_gated_effect_only_for_live_worker(tmp_path):
    with socket_directory() as directory:
        socket_path = directory / "worker.sock"
        health_path = directory / "health.json"
        lease_key = private_key(directory / "lease.key")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        publish(listener, socket_path, health_path)
        settings = worker_settings(tmp_path, socket_path, health_path, lease_key)
        with TestClient(create_app(settings)) as client:
            effect = client.app.state.core.keenetic_commands._effect
            assert isinstance(effect, HealthGatedKeeneticWorkerEffect)
            assert "worker.sock" not in repr(effect)
        listener.close()


@pytest.mark.parametrize("uid", [-1, 2**31, True])
def test_settings_reject_invalid_keenetic_worker_uid(tmp_path, uid):
    with pytest.raises(ValueError, match="^invalid_worker_configuration$"):
        Settings(
            tmp_path / "data",
            tmp_path / "vault.key",
            keenetic_worker_socket=tmp_path / "worker.sock",
            keenetic_worker_health=tmp_path / "health.json",
            keenetic_worker_key_file=tmp_path / "lease.key",
            keenetic_worker_uid=uid,
        )


def test_invalid_health_receipt_is_read_only_and_unavailable(tmp_path):
    with socket_directory() as directory:
        socket_path = directory / "worker.sock"
        health_path = directory / "health.json"
        lease_key = private_key(directory / "lease.key")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(socket_path))
        os.chmod(socket_path, 0o600)
        health_path.write_text('{"workerId":"invalid"}')
        health_path.chmod(0o600)
        before = health_path.read_bytes()
        effect = build_keenetic_worker_effect(
            worker_settings(tmp_path, socket_path, health_path, lease_key),
            object(), Egress(), process_alive=lambda _pid: True,
        )
        assert effect is None
        assert health_path.read_bytes() == before
        listener.close()
