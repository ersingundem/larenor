import os
import json
import pwd
from pathlib import Path
import platform
import re
import shutil
import subprocess
import time
import zipfile

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
    "larenor-keenetic-worker.service",
    "larenor-proxmox-power-worker.service",
    "larenor-nut-bridge.service",
)
PACKAGE_ASSETS = (
    Path("/usr/lib/sysusers.d/larenor-host-workers.conf"),
    Path("/usr/lib/tmpfiles.d/larenor-host-workers.conf"),
    Path("/usr/libexec/larenor-unmanic-provision"),
    Path("/usr/libexec/larenor-installation-journals"),
    Path("/usr/libexec/larenor-nut-notify"),
    *(Path("/etc/systemd/system") / name for name in UNITS),
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
    installed = [Path("/etc/systemd/system") / name for name in UNITS]
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
    keenetic_process = None
    runtime_mounted = False
    bundle = Path(os.environ["LARENOR_HOST_WORKER_BUNDLE"])
    package_python = Path(os.environ["LARENOR_HOST_WORKER_PYTHON"])
    source_revision = os.environ["LARENOR_HOST_WORKER_SOURCE_REVISION"]
    assert len(source_revision) == 40 and all(value in "0123456789abcdef" for value in source_revision)
    assert bundle.is_file() and package_python.is_file()
    assert (not prefix.exists() and not helper.exists()
            and not journal_helper.exists() and not data_root.exists()
            and not runtime_ipc.exists() and not config_root.exists())
    assert all(not path.exists() for path in PACKAGE_ASSETS)
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
        installer = ASSETS / "install.py"
        checked = subprocess.run(
            [package_python, installer, "--bundle", bundle, "--check"],
            check=True, timeout=30, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        preview = json.loads(checked.stdout)
        assert preview["sourceRevision"] == source_revision
        assert preview["unmanicRevision"] == "1c324b8fc3974ffce3d7cc945adb938fe7182910"
        assert preview["startsServices"] is False
        assert preview["createsPrivateConfiguration"] is False
        installed_release = subprocess.run(
            [package_python, installer, "--bundle", bundle, "--python", package_python,
             "--install"],
            check=False, timeout=600, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if installed_release.returncode != 0:
            detail = installed_release.stderr.strip()
            assert re.fullmatch(
                r"(?:bundle_invalid|host_unsupported|host_identity_invalid|"
                r"asset_install_failed|private_config_invalid|activation_failed|"
                r"release_invalid(?::[a-z][a-z0-9_]{0,63})?)",
                detail,
            ), "host_installer_unsafe_failure"
            pytest.fail("host_installer_failed:" + detail)
        assert installed_release.stderr == ""
        assert json.loads(installed_release.stdout) == preview
        current = prefix / "current"
        release = prefix / "releases" / source_revision
        assert current.is_symlink() and current.resolve() == release
        assert json.loads((release / "release.json").read_text()) == preview
        runtime_python = current / "server/bin/python"
        assert runtime_python.is_file() and os.access(runtime_python, os.X_OK)
        imported = subprocess.run(
            [runtime_python, "-c", "import pathlib,larenor_server;"
             "print(pathlib.Path(larenor_server.__file__).resolve())"],
            check=True, timeout=10, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
        ).stdout.strip()
        assert Path(imported).is_relative_to(release / "server")
        for archive, expected_id in (
            (current / "callback.zip", "larenor_archive_terminal"),
            (current / "encoder.zip", "larenor_archive_encoder"),
        ):
            info = archive.stat(follow_symlinks=False)
            assert (info.st_uid, info.st_gid, info.st_mode & 0o777) == (0, 0, 0o644)
            with zipfile.ZipFile(archive) as package:
                assert set(package.namelist()) == {"info.json", "plugin.py", "description.md"}
                assert json.loads(package.read("info.json"))["id"] == expected_id
        core_data.mkdir(parents=True, mode=0o700)
        core_secrets.mkdir(mode=0o700)
        for path in (core_data, core_secrets):
            os.chown(path, 10001, 10001)
            path.chmod(0o700)
        expected_paths = (
            (core_data, 10001, 10001, 0o700),
            (core_secrets, 10001, 10001, 0o700),
            (data_root / "host-workers", 0, 0, 0o711),
            (host_ipc, 0, 10002, 0o750),
            (component_ipc, 0, 10002, 0o750),
            (host_ipc / "keenetic", 10008, 10002, 0o750),
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
            "LANG": "C",
            "LC_ALL": "C",
        }
        mesh_process = subprocess.Popen(
            [runtime_python, proof, "server", socket_path],
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
            [runtime_python, proof, "client", core_socket_path],
            check=True,
            timeout=10,
            env=environment,
            preexec_fn=_identity(10001, 10001),
        )
        nut_user = pwd.getpwnam("nut")
        nut_runtime = Path("/run/larenor-power-recovery")
        nut_runtime.mkdir(mode=0o770)
        os.chown(nut_runtime, 10006, 10006)
        nut_runtime.chmod(0o770)
        nut_socket = nut_runtime / "notify.sock"
        nut_state = data_root / "host-workers/power-recovery"
        nut_proof = ROOT / "server/tests/support/f18_nut_notify_ipc.py"
        nut_process = subprocess.Popen(
            [
                runtime_python, nut_proof, "server",
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
            [runtime_python, nut_proof, "client", nut_socket],
            check=True,
            timeout=10,
            env=environment,
            preexec_fn=_identity(
                nut_user.pw_uid, nut_user.pw_gid, (10006,),
            ),
        )
        subprocess.run(
            [
                runtime_python,
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
                runtime_python, proxmox_proof, "server",
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
                runtime_python, proxmox_proof, "client",
                runtime_ipc / "proxmox/power.sock",
                runtime_ipc / "proxmox/health.json",
            ],
            check=True,
            timeout=10,
            env=environment,
            preexec_fn=_identity(10001, 10001),
        )
        keenetic_ipc = host_ipc / "keenetic"
        keenetic_config = config_root / "host-workers/keenetic"
        worker_key = keenetic_config / "lease.key"
        core_lease_key = core_secrets / "keenetic-worker.key"
        for path, owner in ((worker_key, 10008), (core_lease_key, 10001)):
            path.write_bytes(b"k" * 32)
            os.chown(path, owner, owner)
            path.chmod(0o600)
        policy_path = keenetic_config / "policy.json"
        policy_path.write_text(json.dumps({
            "version": 1, "adapter": "rci", "secretFile": str(worker_key),
        }))
        os.chown(policy_path, 10008, 10008)
        policy_path.chmod(0o600)
        keenetic_socket = keenetic_ipc / "commands.sock"
        keenetic_health = keenetic_ipc / "health.json"
        keenetic_process = subprocess.Popen(
            [runtime_python, "-m",
             "larenor_server.keenetic_commands.worker_runtime", "--policy", policy_path,
             "--socket", keenetic_socket, "--health", keenetic_health,
             "--api-uid", "10001", "--socket-gid", "10002"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, env=environment,
            preexec_fn=_identity(10008, 10008),
        )
        deadline = time.monotonic() + 5
        while not keenetic_health.exists() and keenetic_process.poll() is None:
            if time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        detail = (keenetic_process.stderr.read().decode()
                  if keenetic_process.poll() is not None else "keenetic_health_not_ready")
        assert keenetic_socket.is_socket() and keenetic_health.is_file(), detail
        subprocess.run(
            [runtime_python,
             ROOT / "server/tests/support/keenetic_linux_core_ipc.py",
             runtime_ipc / "keenetic/commands.sock",
             runtime_ipc / "keenetic/health.json", core_lease_key,
             core_data, core_secrets / "vault.key"],
            check=True, timeout=30, env=environment,
            preexec_fn=_identity(10001, 10001),
        )
        component_socket = component_ipc / "component.sock"
        component_proof = ROOT / "server/tests/support/f15_component_worker_ipc.py"
        component_process = subprocess.Popen(
            [
                runtime_python,
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
                runtime_python,
                component_proof,
                "client",
                component_socket,
            ],
            check=True,
            timeout=10,
            env=environment,
            preexec_fn=_identity(10001, 10001),
        )
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
        if keenetic_process is not None:
            keenetic_process.terminate()
            try:
                keenetic_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                keenetic_process.kill()
                keenetic_process.wait(timeout=5)
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
        for target in PACKAGE_ASSETS:
            target.unlink(missing_ok=True)
        subprocess.run([systemctl, "daemon-reload"], check=False, timeout=20,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(prefix, ignore_errors=True)
        shutil.rmtree(config_root, ignore_errors=True)
