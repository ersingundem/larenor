import os
from pathlib import Path
import json
import hashlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import pytest

from larenor_server.ai_resources.runtime import (
    AiDispatch,
    AiRuntimeError,
    AiRuntimeObservation,
    build_ai_job_runtime,
)
from larenor_server.ai_resources.worker_ipc import AiWorkerClient, AiWorkerServer
from larenor_server.config import Settings
from larenor_server.errors import StartupError
from larenor_server.runtime import create_configured_app


JOB = "1" * 32
DISPATCH = "2" * 32


class Runtime:
    enforcement = "systemdCgroupV2"

    def __init__(self):
        self.calls = []
        self.phase = AiRuntimeObservation("running", memory_peak_mb=12, cpu_millis=34)

    def available(self):
        self.calls.append(("available", None))
        return True

    def supports(self, kind):
        self.calls.append(("supports", kind))
        return kind == "assistant"

    def provider(self, kind):
        self.calls.append(("provider", kind))
        return "llama-cpp-main" if kind == "assistant" else None

    def start(self, dispatch):
        self.calls.append(("start", dispatch))
        return self.phase

    def observe(self, dispatch):
        self.calls.append(("observe", dispatch))
        return self.phase

    def cancel(self, dispatch):
        self.calls.append(("cancel", dispatch))
        return AiRuntimeObservation("cancelled", "cancelled", 15, 12, 35)

    def release(self, dispatch):
        self.calls.append(("release", dispatch))


def _dispatch():
    return AiDispatch(JOB, DISPATCH, "request-key-0001", "assistant", 512, 70)


def _start(tmp_path, *, peer_uid=None):
    directory = Path("/tmp") / f"larenor-f08-{uuid.uuid4().hex[:12]}"
    directory.mkdir(mode=0o700)
    path = directory / "ai.sock"
    runtime = Runtime()
    server = AiWorkerServer(
        path,
        runtime,
        owner_uid=os.geteuid(),
        peer_uid=os.geteuid() if peer_uid is None else peer_uid,
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    deadline = time.monotonic() + 2
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert path.exists()
    return path, runtime, server, thread


def _cleanup(path):
    path.parent.rmdir()


def test_exact_uid_private_worker_round_trip_exposes_real_runtime(tmp_path):
    path, runtime, server, thread = _start(tmp_path)
    client = AiWorkerClient(path, owner_uid=os.geteuid(), peer_uid=os.geteuid())
    dispatch = _dispatch()
    try:
        assert client.available()
        assert client.supports("assistant")
        assert client.provider("assistant") == "llama-cpp-main"
        assert client.start(dispatch) == runtime.phase
        assert client.observe(dispatch) == runtime.phase
        assert client.cancel(dispatch).phase == "cancelled"
        assert client.release(dispatch) is None
    finally:
        server.close()
        thread.join(timeout=2)
        _cleanup(path)

    assert [call[0] for call in runtime.calls] == [
        "available", "supports", "provider", "start", "observe", "cancel", "release"
    ]


def test_client_rejects_socket_owned_by_unexpected_uid_before_io(tmp_path):
    path, _runtime, server, thread = _start(tmp_path)
    try:
        client = AiWorkerClient(path, owner_uid=os.geteuid() + 1, peer_uid=os.geteuid())
        assert client.available() is False
    finally:
        server.close()
        thread.join(timeout=2)
        _cleanup(path)


def test_server_rejects_untrusted_peer_without_calling_runtime(tmp_path):
    path, runtime, server, thread = _start(tmp_path, peer_uid=os.geteuid() + 1)
    try:
        client = AiWorkerClient(path, owner_uid=os.geteuid(), peer_uid=os.geteuid())
        assert client.available() is False
    finally:
        server.close()
        thread.join(timeout=2)
        _cleanup(path)
    assert runtime.calls == []


def test_wire_rejects_forged_dispatch_fields_without_runtime_io(tmp_path):
    path, runtime, server, thread = _start(tmp_path)
    client = AiWorkerClient(path, owner_uid=os.geteuid(), peer_uid=os.geteuid())
    try:
        with pytest.raises(AiRuntimeError, match="invalid_runtime_response"):
            client.start({"dispatchId": DISPATCH})
    finally:
        server.close()
        thread.join(timeout=2)
        _cleanup(path)
    assert runtime.calls == []


def test_worker_restart_keeps_systemd_runtime_as_authoritative_state(tmp_path):
    path, runtime, server, thread = _start(tmp_path)
    dispatch = _dispatch()
    try:
        AiWorkerClient(path, owner_uid=os.geteuid(), peer_uid=os.geteuid()).start(dispatch)
    finally:
        server.close()
        thread.join(timeout=2)

    replacement = AiWorkerServer(
        path, runtime, owner_uid=os.geteuid(), peer_uid=os.geteuid()
    )
    thread = threading.Thread(target=replacement.serve_forever, daemon=True)
    thread.start()
    deadline = time.monotonic() + 2
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    try:
        observed = AiWorkerClient(
            path, owner_uid=os.geteuid(), peer_uid=os.geteuid()
        ).observe(dispatch)
        assert observed.phase == "running"
    finally:
        replacement.close()
        thread.join(timeout=2)
        _cleanup(path)


def test_worker_restart_removes_only_its_verified_stale_socket(tmp_path):
    path, runtime, server, thread = _start(tmp_path)
    old, server._socket = server._socket, None
    old.close()
    thread.join(timeout=2)
    assert path.exists()
    replacement = AiWorkerServer(
        path, runtime, owner_uid=os.geteuid(), peer_uid=os.geteuid()
    )
    try:
        replacement.bind()
        assert path.is_socket()
    finally:
        replacement.close()
        _cleanup(path)


def test_normal_core_settings_require_complete_private_worker_socket(tmp_path):
    socket_path = tmp_path / "ai.sock"
    settings = Settings(
        tmp_path, tmp_path / "vault.key",
        ai_worker_socket=socket_path,
        ai_worker_uid=10003,
        ai_worker_socket_gid=10002,
    )
    assert settings.ai_worker_socket == socket_path
    with pytest.raises(ValueError, match="invalid_worker_configuration"):
        Settings(
            tmp_path, tmp_path / "vault.key",
            ai_worker_socket=socket_path,
            ai_worker_uid=10003,
        )
    with pytest.raises(ValueError, match="invalid_worker_configuration"):
        Settings(
            tmp_path, tmp_path / "vault.key",
            ai_worker_socket=socket_path,
            ai_worker_uid=10003,
            ai_worker_socket_gid=10002,
            ai_worker_config=tmp_path / "runtime.json",
        )


def test_normal_core_reads_exact_ai_worker_environment(tmp_path, monkeypatch):
    socket_path = tmp_path / "ai.sock"
    monkeypatch.setenv("LARENOR_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("LARENOR_KEY_FILE", str(tmp_path / "vault.key"))
    monkeypatch.setenv("LARENOR_AI_WORKER_SOCKET", str(socket_path))
    monkeypatch.setenv("LARENOR_AI_WORKER_UID", "10003")
    monkeypatch.setenv("LARENOR_AI_WORKER_SOCKET_GID", "10002")
    settings = Settings.from_environment()
    assert (settings.ai_worker_socket, settings.ai_worker_uid,
            settings.ai_worker_socket_gid) == (socket_path, 10003, 10002)
    monkeypatch.delenv("LARENOR_AI_WORKER_SOCKET_GID")
    with pytest.raises(StartupError, match="invalid_worker_configuration"):
        Settings.from_environment()


def test_normal_core_runtime_uses_worker_socket_instead_of_local_systemd(tmp_path):
    path, _runtime, server, thread = _start(tmp_path)
    try:
        client = build_ai_job_runtime(
            None, worker_socket=path, worker_uid=os.geteuid(),
            socket_gid=os.getegid(),
        )
        assert client.available()
        assert client.provider("assistant") == "llama-cpp-main"
    finally:
        server.close()
        thread.join(timeout=2)
        _cleanup(path)


def test_normal_core_composes_private_worker_client_without_host_catalog(tmp_path):
    socket_path = Path("/tmp") / f"larenor-core-ai-{uuid.uuid4().hex[:12]}.sock"
    settings = Settings(
        tmp_path / "data", tmp_path / "vault.key",
        ai_worker_socket=socket_path,
        ai_worker_uid=os.geteuid(),
        ai_worker_socket_gid=os.getegid(),
    )
    app = create_configured_app(settings)
    runtime = app.state.core.ai_resources.runtime
    assert isinstance(runtime, AiWorkerClient)
    assert runtime.path == socket_path
    assert runtime.owner_uid == runtime.peer_uid == os.geteuid()


@pytest.mark.skipif(
    sys.platform != "linux"
    or os.environ.get("LARENOR_F08_SYSTEMD_ACCEPTANCE") != "1",
    reason="explicit Linux dedicated user-manager acceptance gate",
)
def test_actual_uid10003_user_manager_runs_through_uid10001_ipc():
    assert os.geteuid() == 0
    setpriv = shutil.which("setpriv")
    systemd_run = shutil.which("systemd-run")
    systemctl = shutil.which("systemctl")
    assert setpriv and systemd_run and systemctl
    root = Path(tempfile.mkdtemp(prefix="larenor-f08-ipc-", dir="/tmp"))
    socket_parent = Path(tempfile.mkdtemp(prefix="larenor-f08-socket-", dir="/tmp"))
    worker = None
    environment = {
        "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
        "HOME": "/var/lib/larenor-ai", "XDG_RUNTIME_DIR": "/run/user/10003",
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/10003/bus",
    }
    unit = "larenor-ai-" + "b" * 32 + ".service"
    try:
        state = root / "state"
        state.mkdir(mode=0o700)
        provider = root / "provider"
        shutil.copyfile(
            Path(__file__).parent / "support" / "f08_standalone_provider.py",
            provider,
        )
        provider.chmod(0o700)
        config = root / "runtime.json"
        config.write_text(json.dumps({
            "schemaVersion": 1,
            "manager": "user",
            "systemdRun": systemd_run,
            "systemctl": systemctl,
            "stateRoot": str(state),
            "maxRuntimeSeconds": 30,
            "maxTasks": 8,
            "providers": [{
                "kind": "vision",
                "providerId": "f08-boundary-fixture-v1",
                "executionMode": "standalone",
                "executable": str(provider),
                "executableSha256": hashlib.sha256(provider.read_bytes()).hexdigest(),
                "arguments": ["--fixed-fixture"],
                "artifacts": [],
            }],
        }), encoding="utf-8")
        config.chmod(0o600)
        for path in (root, state, provider, config):
            os.chown(path, 10003, 10003)
        os.chown(socket_parent, 10001, 10002)
        socket_parent.chmod(0o770)
        socket_path = socket_parent / "runtime.sock"
        worker = subprocess.Popen(
            [
                setpriv, "--reuid=10003", "--regid=10003", "--groups=10002",
                sys.executable, "-m", "larenor_server.ai_resources.worker_runtime",
                "--config", str(config), "--socket", str(socket_path),
                "--core-uid", "10001", "--socket-gid", "10002",
            ],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, text=True,
        )
        deadline = time.monotonic() + 15
        while not socket_path.exists() and worker.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        assert socket_path.exists(), worker.stderr.read()
        client = """
import os,sys,time
from larenor_server.ai_resources.runtime import AiDispatch
from larenor_server.ai_resources.worker_ipc import AiWorkerClient
client=AiWorkerClient(sys.argv[1],owner_uid=10003,peer_uid=10003,socket_gid=10002)
assert client.available() and client.provider('vision') == 'f08-boundary-fixture-v1'
dispatch=AiDispatch('a'*32,'b'*32,'ipc-user-manager-0001','vision',64,30)
value=client.start(dispatch)
deadline=time.monotonic()+20
while value.phase in {'starting','running'} and time.monotonic()<deadline:
    time.sleep(.1); value=client.observe(dispatch)
assert value.phase == 'succeeded' and value.output_sha256 and value.output_bytes
assert value.memory_peak_mb is not None and value.memory_peak_mb <= 64
assert value.cpu_millis is not None and value.cpu_millis > 0
"""
        completed = subprocess.run(
            [
                setpriv, "--reuid=10001", "--regid=10001", "--groups=10002",
                sys.executable, "-c", client, str(socket_path),
            ],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
            text=True, timeout=40, check=False,
        )
        assert completed.returncode == 0, completed.stderr
        limits = subprocess.run(
            [
                setpriv, "--reuid=10003", "--regid=10003", "--groups=10002",
                systemctl, "--user", "show", unit,
                "--property=MemoryMax,MemorySwapMax,TasksMax,CPUQuotaPerSecUSec",
            ],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, text=True, timeout=10, check=False,
        )
        assert limits.returncode == 0, limits.stderr
        assert dict(line.split("=", 1) for line in limits.stdout.splitlines()) == {
            "CPUQuotaPerSecUSec": "300ms",
            "MemoryMax": str(64 * 1_048_576),
            "MemorySwapMax": "0",
            "TasksMax": "8",
        }
        release = """
import sys
from larenor_server.ai_resources.runtime import AiDispatch
from larenor_server.ai_resources.worker_ipc import AiWorkerClient
client=AiWorkerClient(sys.argv[1],owner_uid=10003,peer_uid=10003,socket_gid=10002)
client.release(AiDispatch('a'*32,'b'*32,'ipc-user-manager-0001','vision',64,30))
"""
        released = subprocess.run(
            [
                setpriv, "--reuid=10001", "--regid=10001", "--groups=10002",
                sys.executable, "-c", release, str(socket_path),
            ],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
            text=True, timeout=20, check=False,
        )
        assert released.returncode == 0, released.stderr
        assert list(state.iterdir()) == []
    finally:
        if worker is not None:
            worker.terminate()
            try:
                worker.wait(timeout=5)
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.wait(timeout=5)
        subprocess.run(
            [
                setpriv, "--reuid=10003", "--regid=10003", "--groups=10002",
                systemctl, "--user", "stop", unit,
            ],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, env=environment, timeout=10, check=False,
        )
        shutil.rmtree(root, ignore_errors=True)
        shutil.rmtree(socket_parent, ignore_errors=True)
