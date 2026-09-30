import hashlib
import importlib.util
from io import BytesIO
from pathlib import Path
import tarfile

from fastapi import APIRouter
import pytest

from larenor_server.app import create_app
from larenor_server.config import Settings


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "server/tests/support/host_worker_package_linux.py"
SPEC = importlib.util.spec_from_file_location("host_worker_package_linux", HELPER)
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)
TCP_HELPER = ROOT / "server/tests/support/installed_core_tcp.py"
TCP_SPEC = importlib.util.spec_from_file_location("installed_core_tcp", TCP_HELPER)
tcp = importlib.util.module_from_spec(TCP_SPEC)
TCP_SPEC.loader.exec_module(tcp)


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
