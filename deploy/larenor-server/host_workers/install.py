#!/usr/bin/env python3
"""Install the reviewed host-worker release and systemd supervision assets.

The installer consumes an offline, hash-listed wheel bundle. It never fetches
packages, creates private policies, enables units, or starts a worker during
installation. Activation is a separate explicit operation after the operator
has provisioned the exact 0600 policies, archive catalog and plugin keys.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import platform
import grp
import pwd
import re
import shutil
import stat
import subprocess
import sys


SOURCE_REVISION = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
WHEEL = re.compile(r"[A-Za-z0-9_.+-]{1,180}\.whl\Z")
PLATFORMS = {"x86_64": "linux/amd64", "aarch64": "linux/arm64"}
UNMANIC_VERSION = "0.4.1"
UNMANIC_REVISION = "1c324b8fc3974ffce3d7cc945adb938fe7182910"
MAX_MANIFEST = 256 * 1024
MAX_WHEELS = 256
MAX_WHEEL_BYTES = 256 * 1024 * 1024
PREFIX = Path("/opt/larenor-server-host")
IPC = Path("/var/lib/larenor-server/host-workers/ipc")
CONFIG = Path("/etc/larenor-server/host-workers")
ASSETS = {
    "larenor-host-workers.sysusers": (Path("/usr/lib/sysusers.d/larenor-host-workers.conf"), 0o644),
    "larenor-host-workers.tmpfiles": (Path("/usr/lib/tmpfiles.d/larenor-host-workers.conf"), 0o644),
    "larenor-preflight-worker.service": (Path("/etc/systemd/system/larenor-preflight-worker.service"), 0o644),
    "larenor-installation-worker.service": (Path("/etc/systemd/system/larenor-installation-worker.service"), 0o644),
    "installation_journals.py": (Path("/usr/libexec/larenor-installation-journals"), 0o755),
    "larenor-component-backup-worker.service": (Path("/etc/systemd/system/larenor-component-backup-worker.service"), 0o644),
    "larenor-unmanic.service": (Path("/etc/systemd/system/larenor-unmanic.service"), 0o644),
    "larenor-unmanic-provision.service": (Path("/etc/systemd/system/larenor-unmanic-provision.service"), 0o644),
    "unmanic_provision.py": (Path("/usr/libexec/larenor-unmanic-provision"), 0o755),
    "larenor-media-archive-worker.service": (Path("/etc/systemd/system/larenor-media-archive-worker.service"), 0o644),
    "larenor-ai-worker.service": (Path("/etc/systemd/system/larenor-ai-worker.service"), 0o644),
    "larenor-keenetic-worker.service": (Path("/etc/systemd/system/larenor-keenetic-worker.service"), 0o644),
    "larenor-mesh-worker.service": (Path("/etc/systemd/system/larenor-mesh-worker.service"), 0o644),
    "larenor-proxmox-power-worker.service": (Path("/etc/systemd/system/larenor-proxmox-power-worker.service"), 0o644),
    "larenor-nut-bridge.service": (Path("/etc/systemd/system/larenor-nut-bridge.service"), 0o644),
    "nut_notify.py": (Path("/usr/libexec/larenor-nut-notify"), 0o755),
}
PRIVATE_CONFIGS = (
    (CONFIG / "root/preflight.json", 0),
    (CONFIG / "root/installation.json", 0),
    (CONFIG / "archive/runtime.json", 1000),
    (CONFIG / "archive/resolver.json", 1000),
    (CONFIG / "archive/callback.key", 1000),
    (CONFIG / "archive/encoder.json", 1000),
    (CONFIG / "archive/callback.json", 1000),
    (CONFIG / "ai/runtime.json", 10003),
    (CONFIG / "mesh/runtime.json", 10004),
    (CONFIG / "keenetic/policy.json", 10008),
    (CONFIG / "keenetic/lease.key", 10008),
    (Path("/var/lib/larenor-server/core/secrets/keenetic-worker.key"), 10001),
    (CONFIG / "proxmox/credential.bin", 10005),
    (CONFIG / "proxmox/binding.key", 10005),
    (CONFIG / "power-recovery/nut-bridge.json", 10006),
)
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
RELEASE_PHASES = frozenset({
    "server_venv", "server_install", "server_check",
    "unmanic_venv", "unmanic_install", "unmanic_check",
    "preflight_help", "installation_help", "component_backup_help",
    "media_archive_help", "ai_help", "mesh_help", "keenetic_help",
    "proxmox_power_help", "proxmox_supervisor_help", "nut_bridge_help",
    "callback_package_help", "unmanic_help", "callback_package",
    "encoder_package", "sysusers", "tmpfiles", "daemon_reload",
})


class HostWorkerPackageError(RuntimeError):
    CODES = frozenset({
        "bundle_invalid", "host_unsupported", "host_identity_invalid",
        "release_invalid", "asset_install_failed", "private_config_invalid",
        "activation_failed",
    })

    def __init__(self, code="bundle_invalid", phase=None):
        self.code = code if code in self.CODES else "bundle_invalid"
        self.phase = (
            phase
            if self.code == "release_invalid" and phase in RELEASE_PHASES
            else None
        )
        super().__init__(self.code)

    @property
    def safe_message(self):
        return self.code + (":" + self.phase if self.phase is not None else "")


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _platform():
    return PLATFORMS.get(platform.machine().lower()) if platform.system() == "Linux" else None


def _read_regular(path, maximum, *, owner=None, mode=None):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or not 1 <= before.st_size <= maximum
                or owner is not None and before.st_uid != owner
                or mode is not None and stat.S_IMODE(before.st_mode) != mode):
            raise OSError()
        raw = bytearray()
        while len(raw) <= maximum:
            part = os.read(descriptor, min(1024 * 1024, maximum + 1 - len(raw)))
            if not part:
                break
            raw.extend(part)
        after = os.fstat(descriptor)
        entry = os.stat(path, follow_symlinks=False)
        identity = lambda value: (
            value.st_dev, value.st_ino, value.st_uid, value.st_gid,
            stat.S_IFMT(value.st_mode), stat.S_IMODE(value.st_mode),
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
        )
        if len(raw) != before.st_size or identity(before) != identity(after) or identity(after) != identity(entry):
            raise OSError()
        return bytes(raw)
    finally:
        os.close(descriptor)


def _wheel_rows(bundle, values, directory):
    if not isinstance(values, list) or not 1 <= len(values) <= MAX_WHEELS:
        raise ValueError()
    rows, names = [], set()
    for value in values:
        if (not isinstance(value, dict) or set(value) != {"file", "sha256"}
                or not isinstance(value["file"], str)
                or not WHEEL.fullmatch(value["file"])
                or value["file"] in names
                or not isinstance(value["sha256"], str)
                or not DIGEST.fullmatch(value["sha256"])):
            raise ValueError()
        names.add(value["file"])
        path = bundle / directory / value["file"]
        raw = _read_regular(path, MAX_WHEEL_BYTES)
        if hashlib.sha256(raw).hexdigest() != value["sha256"]:
            raise ValueError()
        rows.append(path)
    actual = {item.name for item in (bundle / directory).iterdir()}
    if actual != names:
        raise ValueError()
    return tuple(rows)


def load_bundle(path, *, expected_platform=None):
    try:
        manifest_path = Path(path).absolute()
        bundle = manifest_path.parent
        raw = _read_regular(manifest_path, MAX_MANIFEST)
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs,
                           parse_constant=lambda _item: (_ for _ in ()).throw(ValueError()))
        if (not isinstance(value, dict) or set(value) != {
                "schemaVersion", "sourceRevision", "platform", "serverWheels", "unmanic"}
                or value["schemaVersion"] != 1
                or not isinstance(value["sourceRevision"], str)
                or not SOURCE_REVISION.fullmatch(value["sourceRevision"])
                or value["platform"] not in {"linux/amd64", "linux/arm64"}
                or expected_platform is not None and value["platform"] != expected_platform
                or not isinstance(value["unmanic"], dict)
                or set(value["unmanic"]) != {"version", "upstreamRevision", "wheels"}
                or value["unmanic"]["version"] != UNMANIC_VERSION
                or value["unmanic"]["upstreamRevision"] != UNMANIC_REVISION):
            raise ValueError()
        before = bundle.stat()
        if (not stat.S_ISDIR(before.st_mode) or bundle.is_symlink()
                or before.st_mode & 0o022):
            raise ValueError()
        server = _wheel_rows(bundle, value["serverWheels"], "server")
        unmanic = _wheel_rows(bundle, value["unmanic"]["wheels"], "unmanic")
        if not any(item.name.lower().startswith("larenor_server-") for item in server):
            raise ValueError()
        if not any(item.name.lower().startswith("unmanic-0.4.1-") for item in unmanic):
            raise ValueError()
        return {"manifest": value, "server": server, "unmanic": unmanic}
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, json.JSONDecodeError):
        raise HostWorkerPackageError("bundle_invalid") from None


def preview(bundle):
    value = bundle["manifest"]
    body = {
        "schemaVersion": 1,
        "sourceRevision": value["sourceRevision"],
        "platform": value["platform"],
        "unmanicVersion": value["unmanic"]["version"],
        "unmanicRevision": value["unmanic"]["upstreamRevision"],
        "units": list(UNITS),
        "startsServices": False,
        "createsPrivateConfiguration": False,
    }
    body["packageDigest"] = hashlib.sha256(_canonical(body).encode("ascii")).hexdigest()
    return body


def _run(command, *, timeout=120, phase=None):
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        raise HostWorkerPackageError("release_invalid", phase) from None
    if result.returncode or len(result.stdout) > 1024 * 1024 or len(result.stderr) > 1024 * 1024:
        raise HostWorkerPackageError("release_invalid", phase)


def _root_directory(path, *, mode=None):
    try:
        path = Path(path).absolute()
        for item in (*reversed(path.parents), path):
            info = item.lstat()
            if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
                    or info.st_uid != 0 or info.st_mode & 0o022):
                raise OSError()
        if mode is not None and stat.S_IMODE(path.lstat().st_mode) != mode:
            raise OSError()
    except OSError:
        raise HostWorkerPackageError("release_invalid") from None


def _validate_entrypoints(release):
    # Executing the installed script catches a stale venv shebang as well as
    # missing package/dependency imports. --help must not start any service.
    for relative, phase in (
        ("server/bin/larenor-preflight-worker", "preflight_help"),
        ("server/bin/larenor-installation-worker", "installation_help"),
        ("server/bin/larenor-component-backup-worker", "component_backup_help"),
        ("server/bin/larenor-media-archive-worker", "media_archive_help"),
        ("server/bin/larenor-ai-worker", "ai_help"),
        ("server/bin/larenor-mesh-worker", "mesh_help"),
        ("server/bin/larenor-keenetic-worker", "keenetic_help"),
        ("server/bin/larenor-proxmox-power-worker", "proxmox_power_help"),
        ("server/bin/larenor-proxmox-power-supervisor", "proxmox_supervisor_help"),
        ("server/bin/larenor-nut-bridge", "nut_bridge_help"),
        ("server/bin/larenor-unmanic-callback-package", "callback_package_help"),
        ("unmanic/bin/unmanic", "unmanic_help"),
    ):
        executable = release / relative
        if (not executable.is_file() or executable.is_symlink()
                or not os.access(executable, os.X_OK)):
            raise HostWorkerPackageError("release_invalid")
        _run([str(executable), "--help"], phase=phase)


def _install_environments(release, bundle, python):
    for name, wheels in (("server", bundle["server"]), ("unmanic", bundle["unmanic"])):
        target = release / name
        _run([str(python), "-m", "venv", str(target)], phase=name + "_venv")
        interpreter = target / "bin/python"
        _run([str(interpreter), "-m", "pip", "install", "--no-index", "--no-deps",
              *[str(item) for item in wheels]], timeout=300, phase=name + "_install")
        _run([str(interpreter), "-m", "pip", "check"], phase=name + "_check")
    _validate_entrypoints(release)


def _install_release(bundle, python):
    revision = bundle["manifest"]["sourceRevision"]
    release = PREFIX / "releases" / revision
    if release.exists():
        receipt = release / "release.json"
        try:
            _root_directory(release, mode=0o755)
            if json.loads(_read_regular(receipt, 8192, owner=0, mode=0o600)) != preview(bundle):
                raise ValueError()
            _validate_entrypoints(release)
            return release
        except Exception:
            raise HostWorkerPackageError("release_invalid") from None
    # A Python venv is not relocatable: pip's script shebangs use its absolute
    # installation path. Build at the final path while it is private and not
    # referenced by current; publish only the validated complete release.
    release.mkdir(mode=0o700, parents=True)
    try:
        _root_directory(PREFIX)
        _root_directory(PREFIX / "releases")
        _root_directory(release, mode=0o700)
        _install_environments(release, bundle, python)
        for kind in ("callback", "encoder"):
            _run([
                str(release / "server/bin/larenor-unmanic-callback-package"),
                "--kind", kind, "--output", str(release / (kind + ".zip")),
            ], phase=kind + "_package")
            plugin = release / (kind + ".zip")
            if (not plugin.is_file() or plugin.is_symlink()
                    or plugin.stat().st_uid != 0
                    or stat.S_IMODE(plugin.stat().st_mode) != 0o644
                    or not 1 <= plugin.stat().st_size <= 256 * 1024):
                raise HostWorkerPackageError("release_invalid")
        receipt = release / "release.json"
        receipt.write_text(_canonical(preview(bundle)))
        receipt.chmod(0o600)
        os.chown(receipt, 0, 0)
        release.chmod(0o755)
        return release
    except Exception:
        if release.exists():
            shutil.rmtree(release)
        raise


def _install_asset(source, destination, mode):
    raw = _read_regular(source, 256 * 1024)
    destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    if destination.exists():
        try:
            if _read_regular(destination, 256 * 1024, owner=0, mode=mode) == raw:
                return
        except Exception:
            pass
    temporary = destination.with_name("." + destination.name + ".larenor-new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = -1
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
            os.fchown(stream.fileno(), 0, 0)
        os.replace(temporary, destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def install(bundle, python=Path("/usr/bin/python3")):
    if os.geteuid() != 0 or _platform() != bundle["manifest"]["platform"]:
        raise HostWorkerPackageError("host_unsupported")
    release = _install_release(bundle, python)
    source = Path(__file__).resolve().parent
    for name, (destination, mode) in ASSETS.items():
        _install_asset(source / name, destination, mode)
    _run(["/usr/bin/systemd-sysusers", "/usr/lib/sysusers.d/larenor-host-workers.conf"],
         phase="sysusers")
    try:
        ipc = grp.getgrnam("larenor-ipc")
        if ipc.gr_gid != 10002 or grp.getgrgid(10002).gr_name != "larenor-ipc":
            raise KeyError()
        pwd.getpwuid(1000)
        ai = pwd.getpwnam("larenor-ai")
        ai_group = grp.getgrnam("larenor-ai")
        keenetic = pwd.getpwnam("larenor-keenetic")
        keenetic_group = grp.getgrnam("larenor-keenetic")
        mesh = pwd.getpwnam("larenor-mesh")
        mesh_group = grp.getgrnam("larenor-mesh")
        proxmox = pwd.getpwnam("larenor-proxmox")
        proxmox_group = grp.getgrnam("larenor-proxmox")
        power = pwd.getpwnam("larenor-power")
        power_group = grp.getgrnam("larenor-power")
        nut = pwd.getpwnam("nut")
        if (ai.pw_uid != 10003 or ai.pw_gid != 10003
                or ai_group.gr_gid != 10003
                or pwd.getpwuid(10003).pw_name != "larenor-ai"
                or grp.getgrgid(10003).gr_name != "larenor-ai"
                or 10002 not in os.getgrouplist("larenor-ai", 10003)):
            raise KeyError()
        if (keenetic.pw_uid != 10008 or keenetic.pw_gid != 10008
                or keenetic_group.gr_gid != 10008
                or pwd.getpwuid(10008).pw_name != "larenor-keenetic"
                or grp.getgrgid(10008).gr_name != "larenor-keenetic"
                or 10002 not in os.getgrouplist("larenor-keenetic", 10008)):
            raise KeyError()
        if (mesh.pw_uid != 10004 or mesh.pw_gid != 10004
                or mesh_group.gr_gid != 10004
                or pwd.getpwuid(10004).pw_name != "larenor-mesh"
                or grp.getgrgid(10004).gr_name != "larenor-mesh"
                or 10002 not in os.getgrouplist("larenor-mesh", 10004)):
            raise KeyError()
        if (proxmox.pw_uid != 10005 or proxmox.pw_gid != 10005
                or proxmox_group.gr_gid != 10005
                or pwd.getpwuid(10005).pw_name != "larenor-proxmox"
                or grp.getgrgid(10005).gr_name != "larenor-proxmox"
                or 10002 not in os.getgrouplist("larenor-proxmox", 10005)):
            raise KeyError()
        if (power.pw_uid != 10006 or power.pw_gid != 10006
                or power_group.gr_gid != 10006
                or pwd.getpwuid(10006).pw_name != "larenor-power"
                or grp.getgrgid(10006).gr_name != "larenor-power"
                or 10006 not in os.getgrouplist("nut", nut.pw_gid)
                or nut.pw_gid not in os.getgrouplist("larenor-power", 10006)):
            raise KeyError()
    except KeyError:
        raise HostWorkerPackageError("host_identity_invalid") from None
    _run(["/usr/bin/systemd-tmpfiles", "--create", "/usr/lib/tmpfiles.d/larenor-host-workers.conf"],
         phase="tmpfiles")
    current = PREFIX / "current"
    link = PREFIX / ".current-new"
    if link.exists() or link.is_symlink():
        link.unlink()
    os.symlink(release.relative_to(PREFIX), link)
    os.replace(link, current)
    _run(["/usr/bin/systemctl", "daemon-reload"], phase="daemon_reload")
    return preview(bundle)


def _private_config(path, owner):
    try:
        _read_regular(path, 64 * 1024, owner=owner, mode=0o600)
    except Exception:
        raise HostWorkerPackageError("private_config_invalid") from None


def _check_keenetic_lease_pair():
    try:
        core = _read_regular(Path("/var/lib/larenor-server/core/secrets/keenetic-worker.key"),
                             32, owner=10001, mode=0o600)
        worker = _read_regular(CONFIG / "keenetic/lease.key",
                               32, owner=10008, mode=0o600)
        if len(core) != 32 or len(worker) != 32 or not hmac.compare_digest(core, worker):
            raise ValueError()
        policy = json.loads(_read_regular(CONFIG / "keenetic/policy.json",
                                          4096, owner=10008, mode=0o600),
                            object_pairs_hook=_pairs)
        if type(policy.get("version")) is not int or policy != {"version": 1, "adapter": "rci",
                      "secretFile": str(CONFIG / "keenetic/lease.key")}:
            raise ValueError()
    except Exception:
        raise HostWorkerPackageError("private_config_invalid") from None


def activate():
    if os.geteuid() != 0 or _platform() is None:
        raise HostWorkerPackageError("host_unsupported")
    for path, owner in PRIVATE_CONFIGS:
        _private_config(path, owner)
    _check_keenetic_lease_pair()
    try:
        library = Path("/var/lib/larenor-server/library").stat()
        if (not stat.S_ISDIR(library.st_mode) or library.st_uid != 1000
                or library.st_mode & 0o007):
            raise ValueError()
    except (OSError, ValueError):
        raise HostWorkerPackageError("host_identity_invalid") from None
    server = PREFIX / "current/server/bin"
    _run([
        str(server / "python"), "/usr/libexec/larenor-installation-journals",
        "initialize",
    ])
    _run([str(server / "larenor-preflight-worker"), "--policy", str(CONFIG / "root/preflight.json"),
          "--socket", str(IPC / "root/preflight.sock"), "--api-uid", "10001",
          "--socket-gid", "10002", "--check-config"])
    _run([str(server / "larenor-installation-worker"), "--policy", str(CONFIG / "root/installation.json"),
          "--socket", str(IPC / "root/installation.sock"), "--api-uid", "10001",
          "--socket-gid", "10002", "--check-config"])
    _run([
        str(server / "larenor-component-backup-worker"),
        "--socket", str(IPC / "root/component-backup.sock"),
        "--container-journal", "/var/lib/larenor-server/host-workers/installation/containers",
        "--volume-journal", "/var/lib/larenor-server/host-workers/installation/volumes",
        "--engine-socket", "/var/run/docker.sock",
        "--capture-root", "/var/lib/larenor-server/host-workers/component-backup/captures",
        "--capture-journal", "/var/lib/larenor-server/host-workers/component-backup/capture-journal.json",
        "--api-uid", "10001", "--socket-gid", "10002", "--engine-uid", "0",
        "--btrfs", "/usr/bin/btrfs", "--check-config",
    ])
    _run([str(server / "larenor-media-archive-worker"), "--config",
          str(CONFIG / "archive/runtime.json"), "--check-config"])
    _run(["/usr/bin/loginctl", "enable-linger", "larenor-ai"])
    _run(["/usr/bin/systemctl", "start", "user@10003.service"])
    try:
        runtime_directory = os.stat("/run/user/10003", follow_symlinks=False)
        bus = os.stat("/run/user/10003/bus", follow_symlinks=False)
        if (not stat.S_ISDIR(runtime_directory.st_mode)
                or runtime_directory.st_uid != 10003
                or stat.S_IMODE(runtime_directory.st_mode) != 0o700
                or not stat.S_ISSOCK(bus.st_mode) or bus.st_uid != 10003):
            raise OSError()
    except OSError:
        raise HostWorkerPackageError("host_identity_invalid") from None
    _run([
        "/usr/sbin/runuser", "--user", "larenor-ai", "--group", "larenor-ai",
        "--supp-group", "larenor-ipc", "--", "/usr/bin/env",
        "XDG_RUNTIME_DIR=/run/user/10003",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/10003/bus",
        str(server / "larenor-ai-worker"), "--config",
        str(CONFIG / "ai/runtime.json"), "--socket",
        str(IPC / "ai/runtime.sock"), "--core-uid", "10001",
        "--socket-gid", "10002", "--check-config",
    ])
    _run([
        "/usr/sbin/runuser", "--user", "larenor-mesh", "--group", "larenor-mesh",
        "--supp-group", "larenor-ipc", "--",
        str(server / "larenor-mesh-worker"), "--config",
        str(CONFIG / "mesh/runtime.json"), "--socket",
        str(IPC / "mesh/runtime.sock"), "--core-uid", "10001",
        "--socket-gid", "10002", "--check-config",
    ])
    _run([
        "/usr/sbin/runuser", "--user", "larenor-proxmox", "--group",
        "larenor-proxmox", "--supp-group", "larenor-ipc", "--",
        str(server / "larenor-proxmox-power-worker"),
        "--socket", str(IPC / "proxmox/power.sock"),
        "--health-receipt", str(IPC / "proxmox/health.json"),
        "--credential-file", str(CONFIG / "proxmox/credential.bin"),
        "--binding-key-file", str(CONFIG / "proxmox/binding.key"),
        "--api-uid", "10001", "--socket-gid", "10002", "--check-config",
    ])
    _run([
        "/usr/sbin/runuser", "--user", "larenor-power", "--group",
        "larenor-power", "--",
        str(server / "larenor-nut-bridge"),
        "--config", str(CONFIG / "power-recovery/nut-bridge.json"),
        "--upsmon-config", "/etc/nut/upsmon.conf", "check-config",
    ])
    _run([
        "/usr/sbin/runuser", "--user", "larenor-keenetic", "--group",
        "larenor-keenetic", "--supp-group", "larenor-ipc", "--",
        str(server / "larenor-keenetic-worker"), "--policy",
        str(CONFIG / "keenetic/policy.json"), "--socket",
        str(IPC / "keenetic/commands.sock"), "--health",
        str(IPC / "keenetic/health.json"), "--api-uid", "10001",
        "--socket-gid", "10002", "--check-config",
    ])
    _run(["/usr/bin/systemctl", "enable", "--now", *UNITS], timeout=180)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--python", type=Path, default=Path("/usr/bin/python3"))
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true")
    action.add_argument("--install", action="store_true")
    action.add_argument("--activate", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.activate:
            if args.bundle is not None:
                raise HostWorkerPackageError()
            activate()
            print("host_workers_activated")
            return 0
        if args.bundle is None:
            raise HostWorkerPackageError()
        bundle = load_bundle(args.bundle, expected_platform=_platform())
        result = install(bundle, args.python) if args.install else preview(bundle)
        print(_canonical(result))
        return 0
    except HostWorkerPackageError as error:
        print(error.safe_message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
