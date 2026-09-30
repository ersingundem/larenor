import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import time

import pytest


pytestmark = pytest.mark.skipif(
    sys.platform != "linux"
    or os.environ.get("LARENOR_F08_SYSTEMD_ACCEPTANCE") != "1",
    reason="explicit Linux dedicated user-manager acceptance gate",
)

AI_UID = 10003
CORE_UID = 10001
IPC_GID = 10002
PROVIDER_ID = "f08-cgroup-stress-v1"


def _run_as(setpriv, uid, arguments, *, environment, timeout=15):
    return subprocess.run(
        [
            setpriv,
            f"--reuid={uid}",
            f"--regid={uid}",
            f"--groups={IPC_GID}",
            *arguments,
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        text=True,
        timeout=timeout,
        check=False,
    )


def _flat_keyed(path):
    raw = path.read_text(encoding="ascii")
    values = {}
    for line in raw.splitlines():
        fields = line.split()
        assert len(fields) == 2 and fields[0] not in values, (path, raw)
        assert fields[1].isascii() and fields[1].isdigit(), (path, raw)
        values[fields[0]] = int(fields[1])
    return values


def _client_call(
    setpriv, python, socket_path, *, kind, dispatch_id, cpu, start,
):
    source = """
import dataclasses,json,sys,time
from larenor_server.ai_resources.runtime import AiDispatch
from larenor_server.ai_resources.worker_ipc import AiWorkerClient
client=AiWorkerClient(sys.argv[1],owner_uid=10003,peer_uid=10003,socket_gid=10002)
dispatch=AiDispatch(
    'a'*32,sys.argv[2],sys.argv[3]+'-stress-request',sys.argv[3],64,
    int(sys.argv[4]),
)
value=client.start(dispatch) if sys.argv[5] == 'start' else client.observe(dispatch)
if sys.argv[5] == 'observe':
    deadline=time.monotonic()+10
    while value.phase in {'starting','running'} and time.monotonic()<deadline:
        time.sleep(.05); value=client.observe(dispatch)
print(json.dumps(dataclasses.asdict(value),sort_keys=True,separators=(',',':')))
"""
    result = _run_as(
        setpriv,
        CORE_UID,
        [
            python,
            "-c",
            source,
            str(socket_path),
            dispatch_id,
            kind,
            str(cpu),
            "start" if start else "observe",
        ],
        environment={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def _wait_counter(path, key):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        values = _flat_keyed(path)
        if values.get(key, 0) > 0:
            return values
        time.sleep(0.02)
    pytest.fail(f"cgroup counter did not advance: {path}:{key}")


def _release(setpriv, python, socket_path, kind, dispatch_id, cpu):
    source = """
import sys
from larenor_server.ai_resources.runtime import AiDispatch
from larenor_server.ai_resources.worker_ipc import AiWorkerClient
client=AiWorkerClient(sys.argv[1],owner_uid=10003,peer_uid=10003,socket_gid=10002)
client.release(AiDispatch(
    'a'*32,sys.argv[2],sys.argv[3]+'-stress-request',sys.argv[3],64,
    int(sys.argv[4]),
))
"""
    result = _run_as(
        setpriv,
        CORE_UID,
        [python, "-c", source, str(socket_path), dispatch_id, kind, str(cpu)],
        environment={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
    )
    assert result.returncode == 0, result.stderr


def _control_group(setpriv, systemctl, environment, unit):
    result = _run_as(
        setpriv,
        AI_UID,
        [systemctl, "--user", "show", unit, "--property=ControlGroup", "--value"],
        environment=environment,
    )
    assert result.returncode == 0, result.stderr
    value = result.stdout.strip()
    path = PurePosixPath(value)
    assert path.is_absolute() and ".." not in path.parts and path.name == unit, value
    result = Path("/sys/fs/cgroup").joinpath(*path.parts[1:])
    assert result.is_dir(), result
    return result


def _wait_released(setpriv, systemctl, environment, unit, cgroup):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        state = _run_as(
            setpriv,
            AI_UID,
            [systemctl, "--user", "show", unit, "--property=LoadState", "--value"],
            environment=environment,
        )
        if (state.returncode != 0 or state.stdout.strip() == "not-found") and not cgroup.exists():
            return
        time.sleep(0.05)
    pytest.fail(f"released unit or cgroup remained: {unit}")


def test_actual_user_manager_enforces_memory_pids_and_cpu_throttle_over_ipc():
    assert os.geteuid() == 0
    setpriv = shutil.which("setpriv")
    systemd_run = shutil.which("systemd-run")
    systemctl = shutil.which("systemctl")
    assert setpriv and systemd_run and systemctl
    controllers = set(
        Path("/sys/fs/cgroup/cgroup.controllers").read_text(encoding="ascii").split()
    )
    assert {"cpu", "memory", "pids"} <= controllers

    # The production provider state root is under /var/lib.  A state root in
    # /tmp would be hidden from the worker by the deliberately enabled
    # PrivateTmp sandbox and would test a deployment shape we never ship.
    root = Path(
        tempfile.mkdtemp(prefix="larenor-f08-stress-", dir="/var/lib/larenor-ai")
    )
    socket_parent = Path(
        tempfile.mkdtemp(prefix="larenor-f08-stress-socket-", dir="/tmp")
    )
    worker = None
    units = []
    cgroups = []
    environment = {
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "HOME": "/var/lib/larenor-ai",
        "XDG_RUNTIME_DIR": f"/run/user/{AI_UID}",
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{AI_UID}/bus",
    }
    try:
        state = root / "state"
        state.mkdir(mode=0o700)
        provider = root / "provider"
        shutil.copyfile(
            Path(__file__).parent / "support" / "f08_cgroup_stress_provider.py",
            provider,
        )
        provider.chmod(0o700)
        digest = hashlib.sha256(provider.read_bytes()).hexdigest()
        config = root / "runtime.json"
        config.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "manager": "user",
                    "systemdRun": systemd_run,
                    "systemctl": systemctl,
                    "stateRoot": str(state),
                    "maxRuntimeSeconds": 10,
                    "maxTasks": 8,
                    "providers": [
                        {
                            "kind": kind,
                            "providerId": PROVIDER_ID,
                            "executionMode": "standalone",
                            "executable": str(provider),
                            "executableSha256": digest,
                            "arguments": ["--mode", mode],
                            "artifacts": [],
                        }
                        for kind, mode in (
                            ("vision", "memory"),
                            ("assistant", "tasks"),
                            ("embedding", "cpu"),
                        )
                    ],
                }
            ),
            encoding="utf-8",
        )
        config.chmod(0o600)
        for path in (root, state, provider, config):
            os.chown(path, AI_UID, AI_UID)
        os.chown(socket_parent, CORE_UID, IPC_GID)
        socket_parent.chmod(0o770)
        socket_path = socket_parent / "runtime.sock"
        worker = subprocess.Popen(
            [
                setpriv,
                f"--reuid={AI_UID}",
                f"--regid={AI_UID}",
                f"--groups={IPC_GID}",
                sys.executable,
                "-m",
                "larenor_server.ai_resources.worker_runtime",
                "--config",
                str(config),
                "--socket",
                str(socket_path),
                "--core-uid",
                str(CORE_UID),
                "--socket-gid",
                str(IPC_GID),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            text=True,
        )
        deadline = time.monotonic() + 15
        while (
            not socket_path.exists()
            and worker.poll() is None
            and time.monotonic() < deadline
        ):
            time.sleep(0.05)
        if not socket_path.exists():
            detail = (
                worker.stderr.read()
                if worker.poll() is not None
                else "worker socket deadline expired"
            )
            pytest.fail(detail)

        cases = (
            ("vision", "c" * 32, 100),
            ("assistant", "d" * 32, 100),
            ("embedding", "e" * 32, 20),
        )
        observations = {}
        stats = {}
        for kind, dispatch_id, cpu in cases:
            unit = f"larenor-ai-{dispatch_id}.service"
            units.append((unit, kind, dispatch_id, cpu))
            started = _client_call(
                setpriv,
                sys.executable,
                socket_path,
                kind=kind,
                dispatch_id=dispatch_id,
                cpu=cpu,
                start=True,
            )
            assert started["phase"] in {"starting", "running"}, started
            cgroup = _control_group(setpriv, systemctl, environment, unit)
            cgroups.append((unit, cgroup))
            if kind == "vision":
                stats[kind] = _wait_counter(cgroup / "memory.events", "oom_kill")
            elif kind == "assistant":
                stats[kind] = _wait_counter(cgroup / "pids.events", "max")
            else:
                assert (
                    cgroup / "cpu.max"
                ).read_text(encoding="ascii").strip() == "20000 100000"
                stats[kind] = _wait_counter(cgroup / "cpu.stat", "nr_throttled")
            observations[kind] = _client_call(
                setpriv,
                sys.executable,
                socket_path,
                kind=kind,
                dispatch_id=dispatch_id,
                cpu=cpu,
                start=False,
            )

        assert observations["vision"]["phase"] == "failed"
        assert observations["vision"]["result_code"] == "resource_limit"
        assert observations["vision"]["output_sha256"] is None
        assert stats["vision"]["oom"] > 0
        assert stats["vision"]["oom_kill"] > 0

        assert observations["assistant"]["phase"] == "failed"
        assert observations["assistant"]["result_code"] == "provider_failed"
        assert observations["assistant"]["output_sha256"] is None
        assert stats["assistant"]["max"] > 0

        assert observations["embedding"]["phase"] == "succeeded"
        assert observations["embedding"]["result_code"] == "succeeded"
        assert observations["embedding"]["output_sha256"] is not None
        assert stats["embedding"]["nr_throttled"] > 0
        assert stats["embedding"]["throttled_usec"] > 0

        for unit, kind, dispatch_id, cpu in units:
            _release(
                setpriv,
                sys.executable,
                socket_path,
                kind,
                dispatch_id,
                cpu,
            )
            cgroup = next(path for name, path in cgroups if name == unit)
            _wait_released(setpriv, systemctl, environment, unit, cgroup)
        assert list(state.iterdir()) == []
    finally:
        if worker is not None:
            worker.terminate()
            try:
                worker.wait(timeout=5)
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.wait(timeout=5)
        for unit, _kind, _dispatch_id, _cpu in units:
            _run_as(
                setpriv,
                AI_UID,
                [systemctl, "--user", "stop", unit],
                environment=environment,
            )
        shutil.rmtree(root, ignore_errors=True)
        shutil.rmtree(socket_parent, ignore_errors=True)
