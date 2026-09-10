"""Lifecycle and packaging contract for the private Proxmox power worker."""

import json
import os
from pathlib import Path
import socket
import stat
import tempfile
import threading
import time

import pytest

from larenor_server.proxmox_commands.api_adapter import (
    ProxmoxApiEffectAdapter,
    ProxmoxServiceBinding,
    seal_service_binding,
)
from larenor_server.proxmox_commands.worker_runtime import (
    CREDENTIAL_MAGIC,
    ProxmoxWorkerRuntimeError,
    WorkerRuntimeConfig,
    load_configured_adapter,
    load_encrypted_credential,
    main as runtime_main,
    read_health_receipt,
    serve_worker,
)
from larenor_server.proxmox_commands.worker_supervisor import (
    ProxmoxWorkerSupervisor,
    SupervisorConfig,
    check_health,
    cleanup_exact_socket,
)


def private_root():
    return tempfile.TemporaryDirectory(
        prefix="lpwr-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    )


def encrypted_credential(path):
    # Synthetic sealed envelope: header + 12-byte nonce + AEAD ciphertext/tag.
    path.write_bytes(CREDENTIAL_MAGIC + b"n" * 12 + b"c" * 48)
    path.chmod(0o600)
    return path


def config(root):
    return WorkerRuntimeConfig(
        socket_path=root / "power.sock",
        health_path=root / "health.json",
        credential_path=encrypted_credential(root / "credential.bin"),
        api_uid=os.getuid(),
    )


def configured(root):
    key = root / "binding.key"
    key.write_bytes(b"k" * 32)
    key.chmod(0o600)
    credential = root / "credential.bin"
    seal_service_binding(
        credential,
        key,
        ProxmoxServiceBinding(
            schema_version=1,
            resource_id="a" * 32,
            resource_revision=2,
            binding_id="binding_1",
            binding_revision=3,
            service_id="service_1",
            service_revision=4,
            scheme="https",
            host="proxmox.lan",
            port=8006,
            pinned_address="192.168.1.20",
            node="node-a",
            guest_kind="qemu",
            guest_id=101,
            token_id="larenor@pve!tablet",
            token_secret="synthetic-secret",
        ),
    )
    return WorkerRuntimeConfig(
        socket_path=root / "power.sock",
        health_path=root / "health.json",
        credential_path=credential,
        api_uid=os.getuid(),
        binding_key_path=key,
    )


def wait_for(predicate, timeout=2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    pytest.fail("fixture timeout")


def test_encrypted_service_credential_requires_exact_owner_mode_and_binary_envelope():
    with private_root() as name:
        root = Path(name)
        path = encrypted_credential(root / "credential.bin")
        sealed = load_encrypted_credential(path)
        assert repr(sealed) == "EncryptedServiceCredential(<redacted>)"
        assert b"c" * 24 not in repr(sealed).encode()

        path.chmod(0o640)
        with pytest.raises(ProxmoxWorkerRuntimeError, match="^worker_configuration_invalid$"):
            load_encrypted_credential(path)
        path.chmod(0o600)
        path.write_text('{"token":"plaintext-forbidden"}')
        with pytest.raises(ProxmoxWorkerRuntimeError, match="^worker_configuration_invalid$") as raised:
            load_encrypted_credential(path)
        assert "plaintext-forbidden" not in repr(raised.value)


def test_configured_adapter_is_loaded_from_sealed_binding_and_check_is_network_free(monkeypatch, capsys):
    with private_root() as name:
        selected = configured(Path(name))
        adapter = load_configured_adapter(selected)
        assert isinstance(adapter, ProxmoxApiEffectAdapter)
        assert repr(adapter) == "ProxmoxApiEffectAdapter(<private>)"

        def no_socket(*_args, **_kwargs):
            pytest.fail("check-config opened a socket")

        monkeypatch.setattr(socket, "socket", no_socket)
        assert runtime_main([
            "--socket", str(selected.socket_path),
            "--health-receipt", str(selected.health_path),
            "--credential-file", str(selected.credential_path),
            "--binding-key-file", str(selected.binding_key_path),
            "--api-uid", str(os.getuid()),
            "--check-config",
        ]) == 0
        captured = capsys.readouterr()
        assert captured.out == captured.err == ""


def test_runtime_health_is_atomic_private_and_graceful_shutdown_removes_owned_socket(monkeypatch):
    with private_root() as name:
        root = Path(name)
        selected = config(root)
        stopped = threading.Event()
        result = []
        real_socket = socket.socket

        def local_only(family=socket.AF_INET, *args, **kwargs):
            if family in (socket.AF_INET, socket.AF_INET6):
                pytest.fail("worker opened live network")
            return real_socket(family, *args, **kwargs)

        monkeypatch.setattr(socket, "socket", local_only)
        thread = threading.Thread(
            target=lambda: result.append(
                serve_worker(
                    selected, stopped,
                    peer_uid=lambda _connection: os.getuid(), timeout=0.25,
                )
            )
        )
        thread.start()
        wait_for(selected.health_path.exists)
        wait_for(lambda: read_health_receipt(selected.health_path).state == "ready")
        ready = read_health_receipt(selected.health_path)
        socket_info = selected.socket_path.lstat()
        assert (ready.socket_device, ready.socket_inode) == (
            socket_info.st_dev, socket_info.st_ino,
        )
        assert stat.S_IMODE(socket_info.st_mode) == 0o600
        health_info = selected.health_path.lstat()
        assert health_info.st_uid == os.getuid()
        assert stat.S_IMODE(health_info.st_mode) == 0o600
        assert not list(root.glob("*.tmp"))
        wire = selected.health_path.read_text()
        assert not any(word in wire.lower() for word in (
            "token", "password", "credential", "url", "host", "upid",
        ))
        assert check_health(selected) is True

        stopped.set()
        thread.join(2)
        assert not thread.is_alive()
        assert result == [0]
        assert not selected.socket_path.exists()
        assert read_health_receipt(selected.health_path).state == "stopped"
        assert check_health(selected) is False


def test_runtime_check_config_is_non_effectful_and_static(monkeypatch, capsys):
    with private_root() as name:
        selected = config(Path(name))
        real_socket = socket.socket

        def no_socket(*_args, **_kwargs):
            pytest.fail("check-config opened a socket")

        monkeypatch.setattr(socket, "socket", no_socket)
        assert runtime_main([
            "--socket", str(selected.socket_path),
            "--health-receipt", str(selected.health_path),
            "--credential-file", str(selected.credential_path),
            "--api-uid", str(os.getuid()),
            "--check-config",
        ]) == 0
        captured = capsys.readouterr()
        assert captured.out == captured.err == ""
        monkeypatch.setattr(socket, "socket", real_socket)


def test_exact_inode_cleanup_never_unlinks_replacement():
    with private_root() as name:
        path = Path(name) / "power.sock"
        first = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            first.bind(str(path))
            info = path.lstat()
            expected = (info.st_dev, info.st_ino)
            path.unlink()
            replacement.bind(str(path))
            path.chmod(0o600)
            replacement_inode = path.lstat().st_ino
            assert cleanup_exact_socket(path, expected, os.getuid()) is False
            assert path.lstat().st_ino == replacement_inode
            current = path.lstat()
            assert cleanup_exact_socket(
                path, (current.st_dev, current.st_ino), os.getuid()
            ) is True
            assert not path.exists()
        finally:
            first.close()
            replacement.close()


class Process:
    def __init__(self, code=None, *, on_poll=None):
        self.code = code
        self.on_poll = on_poll
        self.terminated = self.killed = False

    def poll(self):
        if self.on_poll is not None:
            self.on_poll()
            self.on_poll = None
        return self.code

    def wait(self, timeout=None):
        if self.code is None:
            self.code = 0 if self.terminated else -9
        return self.code

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True
        self.code = -9


def test_supervisor_restart_backoff_is_bounded_and_never_forever():
    with private_root() as name:
        root = Path(name)
        selected = SupervisorConfig.from_runtime(config(root))
        launched = []
        sleeps = []

        def launch(command):
            launched.append(tuple(command))
            return Process(1)

        supervisor = ProxmoxWorkerSupervisor(
            selected, launch=launch, sleep=sleeps.append,
        )
        assert supervisor.run(threading.Event()) == 1
        assert len(launched) == 4
        assert all(command == launched[0] for command in launched)
        assert sleeps == [0.1, 0.2, 0.4]
        assert not any("token" in part.lower() for part in launched[0])


def test_supervisor_graceful_shutdown_terminates_once_without_restart():
    with private_root() as name:
        root = Path(name)
        selected = SupervisorConfig.from_runtime(config(root))
        stopped = threading.Event()
        process = Process(on_poll=stopped.set)
        supervisor = ProxmoxWorkerSupervisor(
            selected, launch=lambda _command: process, sleep=lambda _value: None,
        )
        assert supervisor.run(stopped) == 0
        assert process.terminated is True
        assert process.killed is False


def test_real_supervisor_launcher_discards_all_child_output(monkeypatch):
    observed = {}

    def popen(command, **options):
        observed["command"] = command
        observed.update(options)
        return Process(0)

    monkeypatch.setattr(
        "larenor_server.proxmox_commands.worker_supervisor.subprocess.Popen",
        popen,
    )
    with private_root() as name:
        selected = SupervisorConfig.from_runtime(config(Path(name)))
        supervisor = ProxmoxWorkerSupervisor(selected)
        assert supervisor.run(threading.Event()) == 0
    import subprocess

    assert observed["stdout"] is subprocess.DEVNULL
    assert observed["stderr"] is subprocess.DEVNULL
    assert observed["stdin"] is subprocess.DEVNULL
    assert observed["close_fds"] is True


def test_container_overlay_is_nonroot_readonly_cap_dropped_and_endpoint_only():
    source = Path(__file__).resolve().parents[2] / "deploy/larenor-server/proxmox-worker.compose.yaml"
    value = json.loads(source.read_text())
    service = value["services"]["larenor-proxmox-power-worker"]
    assert service["user"] == "10001:10001"
    assert service["read_only"] is True
    assert service["network_mode"] == "bridge"
    assert service["restart"] == "no"
    assert service["cap_drop"] == ["ALL"]
    assert service["security_opt"] == ["no-new-privileges:true"]
    assert service["pids_limit"] <= 32
    assert "privileged" not in service and "cap_add" not in service
    assert "ports" not in service
    assert service["stop_grace_period"] == "10s"
    assert service["entrypoint"][-1].endswith("worker_supervisor")
    health = service["healthcheck"]
    assert health["test"][:3] == ["CMD", "/opt/larenor/.venv/bin/python", "-m"]
    assert "--check-health" in health["test"]
    assert "--binding-key-file" in service["command"]
    assert "--binding-key-file" in health["test"]
    mounts = service["volumes"]
    assert any(item["target"] == "/run/larenor" and item["read_only"] is False for item in mounts)
    assert any(item["target"] == "/run/secrets/proxmox-credential.bin" and item["read_only"] is True for item in mounts)
    assert any(item["target"] == "/run/secrets/proxmox-binding.key" and item["read_only"] is True for item in mounts)
