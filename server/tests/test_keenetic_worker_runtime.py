import json
import os
from pathlib import Path
import socket
import threading
import time

import pytest

from larenor_server.keenetic_commands.worker_ipc import KeeneticCommandWorkerClient
from larenor_server.keenetic_commands.worker_runtime import (
    KeeneticWorkerSupervisor,
    RuntimeConfigurationError,
    WorkerHealthStore,
    load_policy,
    main,
    run_worker_once,
)
from larenor_server.keenetic_commands.service import KeeneticEffectError

from test_keenetic_command_worker_ipc import socket_directory, worker_command


def private_file(path, body):
    path.write_text(body)
    path.chmod(0o600)
    return path


def policy(path, secret=None, *, adapter="unavailable", **extra):
    value = {
        "version": 1,
        "adapter": adapter,
        "secretFile": None if secret is None else str(secret),
    } | extra
    return private_file(path, json.dumps(value))


def test_policy_is_private_address_free_and_secret_permission_checked(tmp_path):
    secret = tmp_path / "keenetic.secret"
    secret.write_bytes(b"S" * 32)
    secret.chmod(0o600)
    loaded = load_policy(policy(tmp_path / "worker.json", secret, adapter="rci"))
    assert repr(loaded) == "KeeneticWorkerPolicy(<private>)"
    assert loaded.adapter == "rci" and loaded.secret_file == secret

    secret.chmod(0o640)
    with pytest.raises(RuntimeConfigurationError, match="^worker_configuration_invalid$"):
        load_policy(tmp_path / "worker.json")
    secret.chmod(0o600)

    for forbidden in (
        {"endpoint": "http://192.0.2.1"},
        {"username": "private-user"},
        {"password": "private-password"},
        {"command": "show running-config"},
    ):
        with pytest.raises(RuntimeConfigurationError, match="^worker_configuration_invalid$") as caught:
            load_policy(policy(tmp_path / "worker.json", secret, adapter="rci", **forbidden))
        assert next(iter(forbidden.values())) not in str(caught.value)


def test_policy_file_must_be_private_and_check_config_opens_no_socket(tmp_path, monkeypatch, capsys):
    source = policy(tmp_path / "worker.json")
    source.chmod(0o644)
    with pytest.raises(RuntimeConfigurationError):
        load_policy(source)
    source.chmod(0o600)
    monkeypatch.setattr(socket, "socket", lambda *_args, **_kwargs: pytest.fail("socket opened"))
    monkeypatch.setattr(
        "larenor_server.keenetic_commands.worker_runtime._platform",
        lambda: "linux/arm64",
    )
    assert main(["--policy", str(source), "--check-config"]) == 0
    assert capsys.readouterr().out == capsys.readouterr().err == ""


def test_health_receipt_binds_private_file_to_exact_owned_socket_inode():
    with socket_directory() as directory:
        path = directory / "worker.sock"
        health = directory / "health.json"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        os.chmod(path, 0o600)
        store = WorkerHealthStore(health, owner_uid=os.getuid())
        receipt = store.publish_ready(path, worker_id="a" * 32, worker_pid=os.getpid())
        assert store.verify_ready(path) == receipt
        assert health.stat().st_mode & 0o777 == 0o600
        assert set(json.loads(health.read_text())) == {
            "schemaVersion", "workerId", "workerPid", "socketDevice",
            "socketInode", "status",
        }
        listener.close()


def test_orphan_cleanup_removes_only_receipted_dead_socket_and_never_replacement():
    with socket_directory() as directory:
        path = directory / "worker.sock"
        health = directory / "health.json"
        first = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        first.bind(str(path))
        os.chmod(path, 0o600)
        store = WorkerHealthStore(health, owner_uid=os.getuid())
        store.publish_ready(path, worker_id="b" * 32, worker_pid=99999999)
        first.close()
        store.cleanup_orphan(path, process_alive=lambda _pid: False)
        assert not path.exists() and not health.exists()

        second = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        second.bind(str(path))
        os.chmod(path, 0o600)
        store.publish_ready(path, worker_id="c" * 32, worker_pid=99999999)
        path.unlink()
        replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        replacement.bind(str(path))
        os.chmod(path, 0o600)
        inode = path.stat().st_ino
        with pytest.raises(RuntimeConfigurationError):
            store.cleanup_orphan(path, process_alive=lambda _pid: False)
        assert path.stat().st_ino == inode and health.exists()
        second.close()
        replacement.close()


def test_supervisor_has_bounded_exponential_backoff_and_stops_restarting():
    calls = []
    waits = []

    class Stop:
        def is_set(self):
            return False

        def wait(self, delay):
            waits.append(delay)
            return False

    supervisor = KeeneticWorkerSupervisor(
        lambda _stop: calls.append("run") or "failed",
        cleanup=lambda: calls.append("cleanup"),
        max_restarts=3,
        initial_backoff=.25,
    )
    assert supervisor.run(Stop()) == 1
    assert calls == ["cleanup", "run"] * 4
    assert waits == [.25, .5, 1.0]


def test_supervisor_shutdown_during_backoff_is_clean_and_not_replayed():
    calls = []

    class Stop:
        def is_set(self):
            return False

        def wait(self, _delay):
            return True

    supervisor = KeeneticWorkerSupervisor(
        lambda _stop: calls.append("run") or "failed",
        cleanup=lambda: calls.append("cleanup"),
    )
    assert supervisor.run(Stop()) == 0
    assert calls == ["cleanup", "run"]


def test_real_loopback_runtime_publishes_health_and_gracefully_cleans_up():
    with socket_directory() as directory:
        socket_path = directory / "worker.sock"
        health_path = directory / "health.json"
        stop = threading.Event()
        result = []

        thread = threading.Thread(
            target=lambda: result.append(run_worker_once(
                socket_path,
                health_path,
                api_uid=os.getuid(),
                socket_gid=None,
                stop=stop,
                peer_uid=lambda _connection: os.getuid(),
            )),
            daemon=True,
        )
        thread.start()
        deadline = time.monotonic() + 2
        while not health_path.exists():
            assert time.monotonic() < deadline
            time.sleep(.01)
        store = WorkerHealthStore(health_path, owner_uid=os.getuid())
        assert store.verify_ready(socket_path).status == "ready"
        effect = KeeneticCommandWorkerClient(
            socket_path,
            owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
            timeout=.5,
        )
        with pytest.raises(KeeneticEffectError, match="^keenetic_effect_unavailable$"):
            effect.execute(worker_command(), guard=lambda: None)
        stop.set()
        thread.join(2)
        assert result == ["stopped"]
        assert not socket_path.exists() and not health_path.exists()


def test_container_package_is_non_networked_bounded_and_health_checked():
    root = Path(__file__).parents[2]
    dockerfile = (root / "server/Dockerfile.keenetic-worker").read_text()
    compose = json.loads(
        (root / "deploy/larenor-server/keenetic-worker.compose.yaml").read_text()
    )["services"]["larenor-keenetic-worker"]
    assert "USER 10001:10001" in dockerfile
    assert "HEALTHCHECK" in dockerfile and "STOPSIGNAL SIGTERM" in dockerfile
    assert compose["network_mode"] == "none"
    assert compose["read_only"] is True
    assert compose["restart"] == "on-failure:3"
    assert compose["cap_drop"] == ["ALL"]
    assert compose["security_opt"] == ["no-new-privileges:true"]
    assert compose["stop_grace_period"] == "10s"
    assert all(volume.get("read_only") is True for volume in compose["volumes"] if volume["target"] == "/run/secrets")


def test_unreceipted_stale_socket_is_never_removed():
    with socket_directory() as directory:
        path = directory / "worker.sock"
        health = directory / "health.json"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        os.chmod(path, 0o600)
        store = WorkerHealthStore(health, owner_uid=os.getuid())

        with pytest.raises(RuntimeConfigurationError, match="^worker_health_invalid$"):
            store.cleanup_orphan(path, process_alive=lambda _pid: False)

        assert path.exists()
        listener.close()


def test_supervisor_crash_recovery_cleans_before_each_bounded_attempt():
    events = []
    outcomes = iter((RuntimeError("crash"), "stopped"))

    class Stop:
        def is_set(self):
            return False

        def wait(self, delay):
            events.append(("wait", delay))
            return False

    def run_once(_stop):
        events.append("run")
        outcome = next(outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    supervisor = KeeneticWorkerSupervisor(
        run_once,
        cleanup=lambda: events.append("cleanup"),
        max_restarts=1,
        initial_backoff=.25,
    )
    assert supervisor.run(Stop()) == 0
    assert events == ["cleanup", "run", ("wait", .25), "cleanup", "run"]


def test_runtime_argv_and_environment_are_not_mutated(tmp_path, monkeypatch):
    source = policy(tmp_path / "worker.json")
    argv = ("--policy", str(source), "--check-config")
    environment = dict(os.environ)
    monkeypatch.setattr(
        "larenor_server.keenetic_commands.worker_runtime._platform",
        lambda: "linux/amd64",
    )

    assert main(argv) == 0
    assert argv == ("--policy", str(source), "--check-config")
    assert dict(os.environ) == environment


def test_container_uses_immutable_exec_argv_without_ambient_environment():
    root = Path(__file__).parents[2]
    dockerfile = (root / "server/Dockerfile.keenetic-worker").read_text()
    compose = json.loads(
        (root / "deploy/larenor-server/keenetic-worker.compose.yaml").read_text()
    )["services"]["larenor-keenetic-worker"]

    assert 'ENTRYPOINT ["/opt/larenor/.venv/bin/larenor-keenetic-worker"]' in dockerfile
    assert 'CMD ["--policy",' in dockerfile
    assert "environment" not in compose and "env_file" not in compose
    assert "command" not in compose and "entrypoint" not in compose


def test_worker_liveness_tracks_private_socket_thread():
    from larenor_server.keenetic_commands.worker_ipc import KeeneticCommandWorkerServer

    with socket_directory() as directory:
        worker = KeeneticCommandWorkerServer(
            directory / "worker.sock",
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
            timeout=.5,
        )
        assert worker.is_alive is False
        worker.start()
        assert worker.is_alive is True
        worker.close()
        assert worker.is_alive is False
