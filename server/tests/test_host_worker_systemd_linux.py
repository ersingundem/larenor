import os
from pathlib import Path
import platform
import shutil
import subprocess
import time

import pytest


ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "deploy/larenor-server/host_workers"
UNITS = (
    "larenor-preflight-worker.service",
    "larenor-installation-worker.service",
    "larenor-unmanic-provision.service",
    "larenor-unmanic.service",
    "larenor-media-archive-worker.service",
    "larenor-ai-worker.service",
    "larenor-mesh-worker.service",
)


def _hosted_root_gate():
    return (platform.system() == "Linux" and os.geteuid() == 0
            and os.environ.get("CI") == "true"
            and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("LARENOR_HOST_WORKER_SYSTEMD_ACCEPTANCE") == "1")


def _identity(uid, gid):
    def apply():
        os.setgroups([10002])
        os.setgid(gid)
        os.setuid(uid)

    return apply


@pytest.mark.skipif(not _hosted_root_gate(), reason="requires isolated hosted Linux root")
def test_production_units_are_loaded_and_verified_by_real_systemd():
    systemctl = Path("/usr/bin/systemctl")
    analyze = Path("/usr/bin/systemd-analyze")
    sysusers = Path("/usr/bin/systemd-sysusers")
    assert systemctl.is_file() and analyze.is_file() and sysusers.is_file()
    destination = Path("/etc/systemd/system")
    installed = []
    prefix = Path("/opt/larenor-server-host")
    helper = Path("/usr/libexec/larenor-unmanic-provision")
    data_root = Path("/var/lib/larenor-server")
    ipc = data_root / "core/data/host-workers/ipc/mesh"
    mesh_process = None
    assert not prefix.exists() and not helper.exists() and not data_root.exists()
    try:
        subprocess.run([sysusers, ASSETS / "larenor-host-workers.sysusers"],
                       check=True, timeout=20)
        ancestors = (
            (data_root, 0, 0, 0o755),
            (data_root / "core", 10001, 10002, 0o750),
            (data_root / "core/data", 10001, 10002, 0o750),
            (data_root / "core/data/host-workers", 10001, 10002, 0o750),
            (data_root / "core/data/host-workers/ipc", 10001, 10002, 0o750),
            (ipc, 10004, 10002, 0o770),
        )
        for path, uid, gid, mode in ancestors:
            path.mkdir(mode=mode)
            os.chown(path, uid, gid)
        socket_path = ipc / "runtime.sock"
        proof = ROOT / "server/tests/support/f55_linux_mesh_ipc.py"
        environment = {
            "PATH": "/usr/bin:/bin",
            "PYTHONPATH": str(ROOT / "server"),
            "LANG": "C",
            "LC_ALL": "C",
        }
        mesh_process = subprocess.Popen(
            [ROOT / "server/.venv/bin/python", proof, "server", socket_path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=environment,
            preexec_fn=_identity(10004, 10004),
        )
        deadline = time.monotonic() + 5
        while not socket_path.exists() and mesh_process.poll() is None:
            if time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        detail = (
            mesh_process.stderr.read().decode()
            if mesh_process.poll() is not None
            else "mesh_socket_not_ready"
        )
        assert socket_path.is_socket(), detail
        subprocess.run(
            [ROOT / "server/.venv/bin/python", proof, "client", socket_path],
            check=True,
            timeout=10,
            env=environment,
            preexec_fn=_identity(10001, 10001),
        )
        current = prefix / "current"
        current.mkdir(parents=True)
        (current / "server").symlink_to(ROOT / "server/.venv", target_is_directory=True)
        (current / "unmanic/bin").mkdir(parents=True)
        (current / "unmanic/bin/python").symlink_to("/bin/true")
        (current / "unmanic/bin/unmanic").symlink_to("/bin/true")
        shutil.copyfile(ASSETS / "unmanic_provision.py", helper)
        helper.chmod(0o755)
        for name in UNITS:
            target = destination / name
            assert not target.exists(), "host_worker_unit_already_exists"
            shutil.copyfile(ASSETS / name, target)
            target.chmod(0o644)
            installed.append(target)
        subprocess.run([systemctl, "daemon-reload"], check=True, timeout=20)
        subprocess.run([analyze, "verify", *installed], check=True, timeout=20,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for source, target in zip((ASSETS / name for name in UNITS), installed):
            assert target.read_bytes() == source.read_bytes()
            shown = subprocess.run([systemctl, "show", target.name,
                                    "--property=LoadState", "--value"],
                                   check=True, timeout=10, text=True,
                                   stdout=subprocess.PIPE).stdout.strip()
            assert shown == "loaded"
    finally:
        if mesh_process is not None:
            mesh_process.terminate()
            try:
                mesh_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                mesh_process.kill()
                mesh_process.wait(timeout=5)
        shutil.rmtree(data_root, ignore_errors=True)
        for target in installed:
            target.unlink(missing_ok=True)
        subprocess.run([systemctl, "daemon-reload"], check=False, timeout=20,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        helper.unlink(missing_ok=True)
        shutil.rmtree(prefix, ignore_errors=True)
