import hashlib
import importlib.util
from io import BytesIO
import os
from pathlib import Path
import subprocess
import tarfile

from fastapi import APIRouter
import pytest

from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.media_archive_actions import plugin_package


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "server/tests/support/host_worker_package_linux.py"
SPEC = importlib.util.spec_from_file_location("host_worker_package_linux", HELPER)
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)
TCP_HELPER = ROOT / "server/tests/support/installed_core_tcp.py"
TCP_SPEC = importlib.util.spec_from_file_location("installed_core_tcp", TCP_HELPER)
tcp = importlib.util.module_from_spec(TCP_SPEC)
TCP_SPEC.loader.exec_module(tcp)
INSTALLER = ROOT / "deploy/larenor-server/host_workers/install.py"
INSTALLER_SPEC = importlib.util.spec_from_file_location("host_worker_install", INSTALLER)
installer = importlib.util.module_from_spec(INSTALLER_SPEC)
INSTALLER_SPEC.loader.exec_module(installer)


def _archive(path, members):
    with tarfile.open(path, "w:gz") as output:
        for name, body, kind in members:
            entry = tarfile.TarInfo(name)
            if kind == "directory":
                entry.type = tarfile.DIRTYPE
                entry.mode = 0o755
                output.addfile(entry)
            elif kind == "symlink":
                entry.type = tarfile.SYMTYPE
                entry.linkname = body.decode("ascii")
                output.addfile(entry)
            else:
                entry.size = len(body)
                entry.mode = 0o644
                output.addfile(entry, BytesIO(body))


def test_unmanic_archive_extraction_requires_exact_regular_pinned_tree(tmp_path, monkeypatch):
    prefix = "unmanic-" + package.UNMANIC_REVISION
    lock = b'{"lockfileVersion":3}\n'
    monkeypatch.setattr(
        package, "UNMANIC_PACKAGE_LOCK_SHA256", hashlib.sha256(lock).hexdigest()
    )
    archive = tmp_path / "source.tar.gz"
    _archive(archive, [
        (prefix, b"", "directory"),
        (prefix + "/unmanic", b"", "directory"),
        (prefix + "/unmanic/webserver", b"", "directory"),
        (
            prefix + "/unmanic/version",
            b'{"short": "UNKNOWN", "long": "UNKNOWN"}',
            "file",
        ),
        (prefix + "/unmanic/webserver/package-lock.json", lock, "file"),
    ])
    destination = tmp_path / "source"
    destination.mkdir()
    assert package._extract_archive(archive, destination) == destination / prefix
    package._write_unmanic_version(destination / prefix)
    assert (destination / prefix / "unmanic/version").read_text() == (
        '{"long":"0.4.1~1c324b8","short":"0.4.1"}\n'
    )
    assert package.UNMANIC_REVISION.startswith(
        package.UNMANIC_FULL_VERSION.rsplit("~", 1)[1]
    )
    with pytest.raises(RuntimeError, match="unmanic_source_invalid"):
        package._write_unmanic_version(destination / prefix)

    unsafe = tmp_path / "unsafe.tar.gz"
    _archive(unsafe, [(prefix + "/link", b"../../etc/passwd", "symlink")])
    with pytest.raises(RuntimeError, match="unmanic_source_invalid"):
        package._extract_archive(unsafe, tmp_path / "unsafe")


def test_frontend_submodule_requires_exact_regular_pinned_tree(tmp_path, monkeypatch):
    prefix = "unmanic-frontend-" + package.UNMANIC_FRONTEND_REVISION
    lock = b'{"lockfileVersion":3}\n'
    monkeypatch.setattr(
        package,
        "UNMANIC_FRONTEND_PACKAGE_LOCK_SHA256",
        hashlib.sha256(lock).hexdigest(),
    )
    archive = tmp_path / "frontend.tar.gz"
    _archive(archive, [
        (prefix, b"", "directory"),
        (prefix + "/package-lock.json", lock, "file"),
    ])
    destination = tmp_path / "frontend-source"
    destination.mkdir()
    source = tmp_path / "parent"
    (source / "unmanic/webserver/frontend").mkdir(parents=True)
    package._extract_frontend_archive(archive, destination, source)
    assert (source / "unmanic/webserver/frontend/package-lock.json").read_bytes() == lock

    unsafe = tmp_path / "unsafe-frontend.tar.gz"
    _archive(unsafe, [(prefix + "/link", b"../../etc/passwd", "symlink")])
    with pytest.raises(RuntimeError, match="unmanic_source_invalid"):
        package._extract_frontend_archive(
            unsafe, tmp_path / "unsafe-frontend", source,
        )


def test_frontend_build_tool_versions_match_upstream_engines(monkeypatch):
    versions = {"node": "v20.19.4\n", "npm": "10.8.2\n"}

    def run(command, **_arguments):
        return type("Completed", (), {
            "returncode": 0,
            "stdout": versions[Path(command[0]).name],
        })()

    monkeypatch.setattr(package.shutil, "which", lambda value: "/usr/bin/" + value)
    monkeypatch.setattr(package.subprocess, "run", run)
    assert package._frontend_tool_versions() == ("v20.19.4", "10.8.2")
    versions["node"] = "v26.0.0\n"
    with pytest.raises(RuntimeError, match="unmanic_frontend_tool_unsupported"):
        package._frontend_tool_versions()


def test_uv_project_wheel_marker_is_verified_outside_the_bundle(tmp_path):
    output = tmp_path / "uv-output"
    wheels = tmp_path / "wheels"
    output.mkdir()
    wheels.mkdir()
    (output / ".gitignore").write_bytes(b"*")
    wheel = output / "larenor_server-0.1.0-py3-none-any.whl"
    wheel.write_bytes(b"wheel")

    package._merge_uv_project_wheel(output, wheels)
    assert not wheel.exists()
    assert (wheels / wheel.name).read_bytes() == b"wheel"
    assert (output / ".gitignore").read_bytes() == b"*"

    foreign = tmp_path / "foreign-output"
    foreign.mkdir()
    (foreign / ".gitignore").write_bytes(b"*")
    (foreign / wheel.name).write_bytes(b"wheel")
    (foreign / "unexpected.txt").write_text("not admitted")
    with pytest.raises(RuntimeError, match="server_project_wheel_invalid"):
        package._merge_uv_project_wheel(foreign, wheels)


def test_committed_unmanic_lock_pins_every_upstream_runtime_dependency_with_hashes():
    lock = (
        ROOT / "deploy/larenor-server/host_workers/unmanic-requirements.lock"
    ).read_text(encoding="utf-8")
    names = {
        line.split("==", 1)[0].lower()
        for line in lock.splitlines()
        if line and line[0].isalnum() and "==" in line
    }
    assert {
        "schedule", "tornado", "marshmallow", "peewee", "peewee-migrate",
        "psutil", "requests", "requests-toolbelt", "py-cpuinfo",
        "json-log-formatter", "xxhash", "watchdog", "sentry-sdk", "inquirer",
        "swagger-ui-py",
    } <= names
    requirement_lines = [
        line for line in lock.splitlines()
        if line and line[0].isalnum() and "==" in line
    ]
    assert len(requirement_lines) == 32
    assert lock.count("--hash=sha256:") >= len(requirement_lines)


def test_installed_core_client_uses_actual_normal_core_loopback_tcp(tmp_path):
    router = APIRouter()

    @router.post("/host-proof-echo")
    def echo(value: dict):
        return value

    app = create_app(
        Settings(tmp_path / "data", tmp_path / "secrets/vault.key"),
        routers=(router,),
    )
    with tcp.InstalledCoreTcp(app) as client:
        status, value = client.json(
            "POST", "/api/v1/host-proof-echo", body={"actual": "tcp"}
        )
        assert status == 200
        assert value == {"actual": "tcp"}


def test_installer_reports_only_a_fixed_phase_when_a_child_fails(monkeypatch):
    monkeypatch.setattr(
        installer.subprocess,
        "run",
        lambda *_args, **_kwargs: subprocess.CompletedProcess(
            (), 1, stdout=b"synthetic secret output", stderr=b"private detail"
        ),
    )
    with pytest.raises(installer.HostWorkerPackageError) as captured:
        installer._run(["/synthetic/command"], phase="unmanic_help")
    assert captured.value.safe_message == "release_invalid:unmanic_help"
    assert "secret" not in captured.value.safe_message
    assert "private" not in captured.value.safe_message

    unknown = installer.HostWorkerPackageError("release_invalid", "secret-value")
    assert unknown.safe_message == "release_invalid"


@pytest.mark.parametrize(
    ("relative", "expected_phase"),
    [(relative, layout) for relative, _help, layout in installer.ENTRYPOINTS],
)
def test_installer_reports_the_fixed_missing_entrypoint_layout(
    tmp_path, monkeypatch, relative, expected_phase
):
    release = tmp_path / "release"
    for candidate, _help, _layout in installer.ENTRYPOINTS:
        if candidate == relative:
            continue
        path = release / candidate
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
    monkeypatch.setattr(installer, "_run", lambda *_args, **_kwargs: None)
    with pytest.raises(installer.HostWorkerPackageError) as captured:
        installer._validate_entrypoints(release)
    assert captured.value.safe_message == "release_invalid:" + expected_phase


@pytest.mark.parametrize("kind", ["callback", "encoder"])
def test_installer_plugin_artifact_check_uses_real_package_and_fixed_phase(
    tmp_path, kind,
):
    callback = tmp_path / (kind + ".zip")
    previous_umask = os.umask(0o077)
    try:
        assert plugin_package.main([
            "--kind", kind, "--output", str(callback),
        ]) == 0
    finally:
        os.umask(previous_umask)
    assert callback.stat().st_mode & 0o777 == 0o644
    installer._validate_plugin_artifact(
        callback, phase=kind + "_artifact", owner=callback.stat().st_uid,
    )
    callback.chmod(0o600)
    with pytest.raises(installer.HostWorkerPackageError) as captured:
        installer._validate_plugin_artifact(
            callback, phase=kind + "_artifact", owner=callback.stat().st_uid,
        )
    assert captured.value.safe_message == "release_invalid:" + kind + "_artifact"


def test_plugin_artifact_packager_rejects_symlink_without_touching_target(
    tmp_path,
):
    target = tmp_path / "existing.zip"
    target.write_bytes(b"existing-private-artifact")
    alias = tmp_path / "callback.zip"
    alias.symlink_to(target)

    assert plugin_package.main([
        "--kind", "callback", "--output", str(alias),
    ]) == 2
    assert target.read_bytes() == b"existing-private-artifact"


def test_installer_release_root_check_has_one_safe_fixed_phase(tmp_path):
    with pytest.raises(installer.HostWorkerPackageError) as captured:
        installer._root_directory(tmp_path)
    assert captured.value.phase in installer.RELEASE_ROOT_PHASES
    assert str(tmp_path) not in captured.value.safe_message


def test_installer_creates_exact_directory_modes_under_group_writable_umask(
    tmp_path, monkeypatch,
):
    def validate(path, *, mode=None, leaf=None):
        if Path(path).stat().st_mode & 0o777 != mode:
            raise installer.HostWorkerPackageError(
                "release_invalid", f"release_{leaf}_nonroot_unsafe_dir"
            )

    monkeypatch.setattr(installer, "_root_directory", validate)
    parent = tmp_path / "host"
    release = parent / "release"
    previous = os.umask(0o002)
    try:
        assert installer._create_root_directory(
            parent, mode=0o755, allow_existing=True, leaf="prefix",
        )
        assert installer._create_root_directory(
            release, mode=0o700, allow_existing=False, leaf="leaf",
        )
    finally:
        os.umask(previous)
    assert parent.stat().st_mode & 0o777 == 0o755
    assert release.stat().st_mode & 0o777 == 0o700

    parent.chmod(0o775)
    with pytest.raises(installer.HostWorkerPackageError) as captured:
        installer._create_root_directory(
            parent, mode=0o755, allow_existing=True, leaf="prefix",
        )
    assert captured.value.safe_message == (
        "release_invalid:release_prefix_nonroot_unsafe_dir"
    )
    assert parent.stat().st_mode & 0o777 == 0o775

    with pytest.raises(installer.HostWorkerPackageError) as captured:
        installer._create_root_directory(
            release, mode=0o700, allow_existing=False, leaf="leaf",
        )
    assert captured.value.safe_message == "release_invalid:release_leaf_exists"


@pytest.mark.parametrize(
    ("mode", "owner", "kind", "expected"),
    [
        (0o40755, 0, "dir", "release_prefix_root_exact_dir"),
        (0o40700, 0, "dir", "release_prefix_root_safe_dir"),
        (0o40775, 1000, "dir", "release_prefix_nonroot_unsafe_dir"),
        (0o120755, 0, "symlink", "release_prefix_root_exact_symlink"),
        (0o100755, 0, "other", "release_prefix_root_exact_other"),
    ],
)
def test_installer_release_root_metadata_is_bounded(
    mode, owner, kind, expected,
):
    info = type("Info", (), {"st_mode": mode, "st_uid": owner})()
    phase = installer._release_root_metadata("prefix", info, 0o755)
    assert phase == expected
    assert phase in installer.RELEASE_ROOT_PHASES
