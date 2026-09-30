import os
import pwd
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
    "larenor-component-backup-worker.service",
    "larenor-unmanic-provision.service",
    "larenor-unmanic.service",
    "larenor-media-archive-worker.service",
    "larenor-ai-worker.service",
    "larenor-mesh-worker.service",
    "larenor-proxmox-power-worker.service",
    "larenor-nut-bridge.service",
)


def _hosted_root_gate():
    return (platform.system() == "Linux" and os.geteuid() == 0
            and os.environ.get("CI") == "true"
            and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("LARENOR_HOST_WORKER_SYSTEMD_ACCEPTANCE") == "1")


def _identity(uid, gid, groups=(10002,)):
    def apply():
        os.setgroups(list(groups))
        os.setgid(gid)
        os.setuid(uid)

    return apply


@pytest.mark.skipif(not _hosted_root_gate(), reason="requires isolated hosted Linux root")
def test_production_units_are_loaded_and_verified_by_real_systemd():
    systemctl = Path("/usr/bin/systemctl")
    analyze = Path("/usr/bin/systemd-analyze")
    sysusers = Path("/usr/bin/systemd-sysusers")
    tmpfiles = Path("/usr/bin/systemd-tmpfiles")
    mount = Path("/usr/bin/mount")
    umount = Path("/usr/bin/umount")
    assert all(path.is_file() for path in (
        systemctl, analyze, sysusers, tmpfiles, mount, umount,
    ))
    destination = Path("/etc/systemd/system")
    installed = []
    prefix = Path("/opt/larenor-server-host")
    helper = Path("/usr/libexec/larenor-unmanic-provision")
    journal_helper = Path("/usr/libexec/larenor-installation-journals")
    data_root = Path("/var/lib/larenor-server")
    core_data = data_root / "core/data"
    core_secrets = data_root / "core/secrets"
    host_ipc = data_root / "host-workers/ipc"
    ipc = host_ipc / "mesh"
    component_ipc = host_ipc / "root"
    runtime_ipc = Path("/run/larenor-workers")
    config_root = Path("/etc/larenor-server")
    mesh_process = None
    proxmox_process = None
    nut_process = None
    nut_runtime = None
    component_process = None
    runtime_mounted = False
    assert (not prefix.exists() and not helper.exists()
            and not journal_helper.exists() and not data_root.exists()
            and not runtime_ipc.exists() and not config_root.exists())
    try:
        try:
            pwd.getpwnam("nut")
        except KeyError:
            subprocess.run(["/usr/sbin/groupadd", "--system", "nut"],
                           check=True, timeout=20)
            subprocess.run([
                "/usr/sbin/useradd", "--system", "--gid", "nut",
                "--home-dir", "/var/lib/nut", "--shell", "/usr/sbin/nologin",
                "nut",
            ], check=True, timeout=20)
        subprocess.run([sysusers, ASSETS / "larenor-host-workers.sysusers"],
                       check=True, timeout=20)
        core_data.mkdir(parents=True, mode=0o700)
        core_secrets.mkdir(mode=0o700)
        for path in (core_data, core_secrets):
            os.chown(path, 10001, 10001)
            path.chmod(0o700)
        subprocess.run(
            [tmpfiles, "--create", ASSETS / "larenor-host-workers.tmpfiles"],
            check=True,
            timeout=20,
        )
        expected_paths = (
            (core_data, 10001, 10001, 0o700),
            (core_secrets, 10001, 10001, 0o700),
            (data_root / "host-workers", 0, 0, 0o711),
            (host_ipc, 0, 10002, 0o750),
            (component_ipc, 0, 10002, 0o750),
            (ipc, 10004, 10002, 0o770),
            (host_ipc / "proxmox", 10005, 10002, 0o770),
            (data_root / "host-workers/power-recovery", 10006, 10006, 0o700),
        )
        for path, uid, gid, mode in expected_paths:
            current = path.stat(follow_symlinks=False)
            assert (current.st_uid, current.st_gid) == (uid, gid)
            assert current.st_mode & 0o777 == mode
        assert not (core_data / "host-workers").exists()
        runtime_ipc.mkdir(mode=0o750)
        os.chown(runtime_ipc, 0, 10002)
        subprocess.run([mount, "--bind", host_ipc, runtime_ipc],
                       check=True, timeout=20)
        runtime_mounted = True
        socket_path = ipc / "runtime.sock"
        core_socket_path = runtime_ipc / "mesh/runtime.sock"
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
            [ROOT / "server/.venv/bin/python", proof, "client", core_socket_path],
            check=True,
            timeout=10,
            env=environment,
            preexec_fn=_identity(10001, 10001),
        )
        nut_user = pwd.getpwnam("nut")
        nut_runtime = Path("/run/larenor-power-recovery")
        nut_runtime.mkdir(mode=0o770)
        os.chown(nut_runtime, 10006, 10006)
        nut_socket = nut_runtime / "notify.sock"
        nut_state = data_root / "host-workers/power-recovery"
        nut_proof = ROOT / "server/tests/support/f18_nut_notify_ipc.py"
        nut_process = subprocess.Popen(
            [
                ROOT / "server/.venv/bin/python", nut_proof, "server",
                nut_socket, nut_state,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=environment,
            preexec_fn=_identity(10006, 10006, (nut_user.pw_gid,)),
        )
        deadline = time.monotonic() + 5
        while not nut_socket.exists() and nut_process.poll() is None:
            if time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        detail = (
            nut_process.stderr.read().decode()
            if nut_process.poll() is not None
            else "nut_notify_socket_not_ready"
        )
        assert nut_socket.is_socket(), detail
        subprocess.run(
            [ROOT / "server/.venv/bin/python", nut_proof, "client", nut_socket],
            check=True,
            timeout=10,
            env=environment,
            preexec_fn=_identity(
                nut_user.pw_uid, nut_user.pw_gid, (10006,),
            ),
        )
        subprocess.run(
            [
                ROOT / "server/.venv/bin/python",
                proof,
                "core",
                core_socket_path,
                core_data,
                core_secrets / "vault.key",
            ],
            check=True,
            timeout=30,
            env=environment,
            preexec_fn=_identity(10001, 10001),
        )
        proxmox_ipc = host_ipc / "proxmox"
        proxmox_socket = proxmox_ipc / "power.sock"
        proxmox_health = proxmox_ipc / "health.json"
        proxmox_proof = ROOT / "server/tests/support/f18_proxmox_worker_ipc.py"
        proxmox_process = subprocess.Popen(
            [
                ROOT / "server/.venv/bin/python", proxmox_proof, "server",
                proxmox_socket, proxmox_health,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=environment,
            preexec_fn=_identity(10005, 10005),
        )
        deadline = time.monotonic() + 5
        while (not proxmox_health.exists()
               and proxmox_process.poll() is None):
            if time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        detail = (
            proxmox_process.stderr.read().decode()
            if proxmox_process.poll() is not None
            else "proxmox_health_not_ready"
        )
        assert proxmox_socket.is_socket() and proxmox_health.is_file(), detail
        subprocess.run(
            [
                ROOT / "server/.venv/bin/python", proxmox_proof, "client",
                runtime_ipc / "proxmox/power.sock",
                runtime_ipc / "proxmox/health.json",
            ],
            check=True,
            timeout=10,
            env=environment,
            preexec_fn=_identity(10001, 10001),
        )
        component_socket = component_ipc / "component.sock"
        component_proof = ROOT / "server/tests/support/f15_component_worker_ipc.py"
        component_process = subprocess.Popen(
            [
                ROOT / "server/.venv/bin/python",
                component_proof,
                "server",
                component_socket,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=environment,
        )
        deadline = time.monotonic() + 5
        while not component_socket.exists() and component_process.poll() is None:
            if time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        detail = (
            component_process.stderr.read().decode()
            if component_process.poll() is not None
            else "component_socket_not_ready"
        )
        assert component_socket.is_socket(), detail
        subprocess.run(
            [
                ROOT / "server/.venv/bin/python",
                component_proof,
                "client",
                component_socket,
            ],
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
        shutil.copyfile(ASSETS / "installation_journals.py", journal_helper)
        journal_helper.chmod(0o755)
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
        if nut_process is not None:
            nut_process.terminate()
            try:
                nut_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                nut_process.kill()
                nut_process.wait(timeout=5)
        if nut_runtime is not None:
            shutil.rmtree(nut_runtime, ignore_errors=True)
        if proxmox_process is not None:
            proxmox_process.terminate()
            try:
                proxmox_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proxmox_process.kill()
                proxmox_process.wait(timeout=5)
        if component_process is not None:
            component_process.terminate()
            try:
                component_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                component_process.kill()
                component_process.wait(timeout=5)
        if mesh_process is not None:
            mesh_process.terminate()
            try:
                mesh_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                mesh_process.kill()
                mesh_process.wait(timeout=5)
        if runtime_mounted:
            unmounted = subprocess.run(
                [umount, runtime_ipc], check=False, timeout=20,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        else:
            unmounted = None
        if runtime_ipc.exists() and (
            unmounted is None or unmounted.returncode == 0
        ):
            runtime_ipc.rmdir()
        shutil.rmtree(data_root, ignore_errors=True)
        for target in installed:
            target.unlink(missing_ok=True)
        subprocess.run([systemctl, "daemon-reload"], check=False, timeout=20,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        helper.unlink(missing_ok=True)
        journal_helper.unlink(missing_ok=True)
        shutil.rmtree(prefix, ignore_errors=True)
        shutil.rmtree(config_root, ignore_errors=True)
