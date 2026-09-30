#!/usr/bin/env python3
"""Build the exact offline host-worker bundle used by hosted Linux acceptance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


UNMANIC_REVISION = "1c324b8fc3974ffce3d7cc945adb938fe7182910"
UNMANIC_VERSION = "0.4.1"
UNMANIC_FULL_VERSION = "0.4.1~1c324b8"
UNMANIC_ARCHIVE_SHA256 = (
    "50110ac6c52490089fc5d778d11e882a4d317e7716ff1abccb665b438a063d42"
)
UNMANIC_ARCHIVE_URL = (
    "https://codeload.github.com/Unmanic/unmanic/tar.gz/" + UNMANIC_REVISION
)
UNMANIC_PACKAGE_LOCK_SHA256 = (
    "3fec3a987a5ec42f9287f6e0c35bc5825189a40deb2199d3a500dd858e6da786"
)
UNMANIC_FRONTEND_REVISION = "96feb65301f243f763c28df903593e3be3850058"
UNMANIC_FRONTEND_ARCHIVE_SHA256 = (
    "d537af4f4741e042b106882188bf7dbabad6d62c520b931e9caee49debd8e0da"
)
UNMANIC_FRONTEND_ARCHIVE_URL = (
    "https://codeload.github.com/Unmanic/unmanic-frontend/tar.gz/"
    + UNMANIC_FRONTEND_REVISION
)
UNMANIC_FRONTEND_PACKAGE_LOCK_SHA256 = (
    "4f4680a90a6e8b0e744d3e907623df3cd5f04719ba514fdb8f81338d68fd77e2"
)
REVISION = re.compile(r"[0-9a-f]{40}\Z")
PLATFORMS = {"linux/amd64", "linux/arm64"}
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_COMMAND_OUTPUT = 1024 * 1024
FRONTEND_NODE_MAJORS = {16, 18, 20, 22}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _run(command, *, cwd=None, timeout=600):
    with tempfile.TemporaryFile() as output:
        completed = subprocess.run(
            [str(item) for item in command],
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
            env={**os.environ, "PIP_DISABLE_PIP_VERSION_CHECK": "1"},
        )
        size = output.tell()
        output.seek(max(0, size - MAX_COMMAND_OUTPUT))
        detail = output.read(MAX_COMMAND_OUTPUT).decode("utf-8", "replace")
    if completed.returncode != 0 or size > MAX_COMMAND_OUTPUT:
        raise RuntimeError(
            "host_package_command_failed:" + Path(str(command[0])).name + ":" + detail
        )


def _frontend_tool_versions():
    values = []
    for name in ("node", "npm"):
        executable = shutil.which(name)
        if executable is None:
            raise RuntimeError("unmanic_frontend_tool_unavailable")
        completed = subprocess.run(
            [executable, "--version"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
            text=True,
            encoding="ascii",
            errors="strict",
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
        )
        value = completed.stdout.strip()
        if completed.returncode != 0 or len(value) > 32 or "\n" in value:
            raise RuntimeError("unmanic_frontend_tool_invalid")
        values.append(value)
    node, npm = values
    node_match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", node)
    npm_match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", npm)
    if (
        node_match is None
        or int(node_match.group(1)) not in FRONTEND_NODE_MAJORS
        or npm_match is None
        or tuple(map(int, npm_match.groups())) < (6, 13, 4)
    ):
        raise RuntimeError("unmanic_frontend_tool_unsupported")
    return node, npm


def _download_archive(
    destination: Path,
    *,
    url=UNMANIC_ARCHIVE_URL,
    expected_sha256=UNMANIC_ARCHIVE_SHA256,
):
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Larenor-host-worker-package-acceptance/1"},
    )
    digest = hashlib.sha256()
    total = 0
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.geturl() != url or response.status != 200:
            raise RuntimeError("unmanic_source_unavailable")
        with destination.open("xb") as output:
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_ARCHIVE_BYTES:
                    raise RuntimeError("unmanic_source_too_large")
                digest.update(chunk)
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
    if total == 0 or digest.hexdigest() != expected_sha256:
        raise RuntimeError("unmanic_source_digest_mismatch")


def _extract_exact_archive(
    archive: Path, destination: Path, *, expected_root: str,
) -> Path:
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        if not 1 <= len(members) <= 20_000:
            raise RuntimeError("unmanic_source_invalid")
        for member in members:
            path = PurePosixPath(member.name)
            if (
                path.is_absolute()
                or not path.parts
                or path.parts[0] != expected_root
                or ".." in path.parts
                or not (member.isfile() or member.isdir())
                or member.size < 0
                or member.size > MAX_ARCHIVE_BYTES
            ):
                raise RuntimeError("unmanic_source_invalid")
        source.extractall(destination, filter="data")
    return destination / expected_root


def _extract_archive(archive: Path, destination: Path) -> Path:
    root = _extract_exact_archive(
        archive, destination, expected_root="unmanic-" + UNMANIC_REVISION,
    )
    package_lock = root / "unmanic/webserver/package-lock.json"
    if (
        not root.is_dir()
        or package_lock.is_symlink()
        or not package_lock.is_file()
        or _sha256(package_lock) != UNMANIC_PACKAGE_LOCK_SHA256
    ):
        raise RuntimeError("unmanic_source_invalid")
    return root


def _extract_frontend_archive(
    archive: Path, destination: Path, source_root: Path,
):
    root = _extract_exact_archive(
        archive,
        destination,
        expected_root="unmanic-frontend-" + UNMANIC_FRONTEND_REVISION,
    )
    package_lock = root / "package-lock.json"
    target = source_root / "unmanic/webserver/frontend"
    if (
        not root.is_dir()
        or package_lock.is_symlink()
        or not package_lock.is_file()
        or _sha256(package_lock) != UNMANIC_FRONTEND_PACKAGE_LOCK_SHA256
        or target.is_symlink()
        or not target.is_dir()
        or any(target.iterdir())
    ):
        raise RuntimeError("unmanic_source_invalid")
    target.rmdir()
    root.rename(target)


def _write_unmanic_version(root: Path):
    """Restore the version file produced by upstream's exact-tag git build."""
    version_path = root / "unmanic/version"
    if (
        version_path.is_symlink()
        or not version_path.is_file()
        or version_path.stat().st_nlink != 1
        or version_path.read_bytes()
        != b'{"short": "UNKNOWN", "long": "UNKNOWN"}'
    ):
        raise RuntimeError("unmanic_source_invalid")
    version_path.write_text(
        json.dumps(
            {"short": UNMANIC_VERSION, "long": UNMANIC_FULL_VERSION},
            sort_keys=True,
            separators=(",", ":"),
        ) + "\n",
        encoding="ascii",
    )
    version_path.chmod(0o644)


def _wheel_rows(directory: Path):
    rows = []
    for path in sorted(directory.glob("*.whl")):
        if path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
            raise RuntimeError("wheelhouse_invalid")
        rows.append({"file": path.name, "sha256": _sha256(path)})
    if not rows:
        raise RuntimeError("wheelhouse_empty")
    return rows


def build(*, root: Path, work: Path, uv: Path, python: Path,
          source_revision: str, platform_name: str):
    root = root.resolve()
    work = work.resolve()
    uv = uv.resolve()
    python = python.resolve()
    if (
        not REVISION.fullmatch(source_revision)
        or platform_name not in PLATFORMS
        or not uv.is_file()
        or not os.access(uv, os.X_OK)
        or not python.is_file()
        or not os.access(python, os.X_OK)
        or work.exists()
        or not (root / "server/uv.lock").is_file()
    ):
        raise RuntimeError("host_package_arguments_invalid")
    work.mkdir(mode=0o755)
    server_wheels = work / "server-wheels"
    unmanic_wheels = work / "unmanic-wheels"
    source_root = work / "source"
    frontend_root = work / "frontend-source"
    for path in (server_wheels, unmanic_wheels, source_root, frontend_root):
        path.mkdir(mode=0o755)
    node_version, npm_version = _frontend_tool_versions()

    build_environment = work / "build-environment"
    _run([python, "-m", "venv", build_environment])
    build_python = build_environment / "bin/python"
    assets = root / "deploy/larenor-server/host_workers"
    _run([
        build_python, "-m", "pip", "install", "--require-hashes",
        "-r", assets / "build-requirements.lock",
    ])

    server_requirements = work / "server-requirements.lock"
    _run([
        uv, "export", "--project", root / "server", "--locked", "--no-dev",
        "--no-emit-project", "--format", "requirements-txt",
        "--output-file", server_requirements,
    ])
    _run([
        build_python, "-m", "pip", "download", "--require-hashes",
        "--only-binary=:all:", "--dest", server_wheels,
        "-r", server_requirements,
    ])
    _run([
        uv, "build", "--wheel", "--python", python,
        "--out-dir", server_wheels, root / "server",
    ])

    archive = work / "unmanic-source.tar.gz"
    _download_archive(archive)
    unmanic_source = _extract_archive(archive, source_root)
    _write_unmanic_version(unmanic_source)
    frontend_archive = work / "unmanic-frontend-source.tar.gz"
    _download_archive(
        frontend_archive,
        url=UNMANIC_FRONTEND_ARCHIVE_URL,
        expected_sha256=UNMANIC_FRONTEND_ARCHIVE_SHA256,
    )
    _extract_frontend_archive(frontend_archive, frontend_root, unmanic_source)
    _run([
        build_python, "-m", "pip", "wheel", "--require-hashes",
        "--no-build-isolation", "--wheel-dir", unmanic_wheels,
        "-r", assets / "unmanic-requirements.lock",
    ], timeout=900)
    _run([
        build_python, "setup.py", "bdist_wheel", "--dist-dir", unmanic_wheels,
    ], cwd=unmanic_source, timeout=900)

    bundle = work / "bundle"
    _run([
        python, assets / "build_bundle.py", "--output", bundle,
        "--server-wheels", server_wheels, "--unmanic-wheels", unmanic_wheels,
        "--source-revision", source_revision, "--platform", platform_name,
    ])
    manifest = bundle / "bundle.json"
    receipt = {
        "schemaVersion": 1,
        "sourceRevision": source_revision,
        "platform": platform_name,
        "serverLockSha256": _sha256(root / "server/uv.lock"),
        "unmanicRevision": UNMANIC_REVISION,
        "unmanicVersion": UNMANIC_VERSION,
        "unmanicFullVersion": UNMANIC_FULL_VERSION,
        "unmanicArchiveSha256": UNMANIC_ARCHIVE_SHA256,
        "unmanicPackageLockSha256": UNMANIC_PACKAGE_LOCK_SHA256,
        "unmanicFrontendRevision": UNMANIC_FRONTEND_REVISION,
        "unmanicFrontendArchiveSha256": UNMANIC_FRONTEND_ARCHIVE_SHA256,
        "unmanicFrontendPackageLockSha256": (
            UNMANIC_FRONTEND_PACKAGE_LOCK_SHA256
        ),
        "frontendNodeVersion": node_version,
        "frontendNpmVersion": npm_version,
        "serverWheels": _wheel_rows(server_wheels),
        "unmanicWheels": _wheel_rows(unmanic_wheels),
        "bundleManifestSha256": _sha256(manifest),
    }
    receipt_path = work / "build-receipt.json"
    receipt_path.write_text(
        json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="ascii",
    )
    receipt_path.chmod(0o644)
    return manifest, receipt_path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--uv", required=True, type=Path)
    parser.add_argument("--python", required=True, type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--platform", required=True, choices=sorted(PLATFORMS))
    args = parser.parse_args(argv)
    try:
        manifest, receipt = build(
            root=args.root,
            work=args.work,
            uv=args.uv,
            python=args.python,
            source_revision=args.source_revision,
            platform_name=args.platform,
        )
        print(json.dumps({"manifest": str(manifest), "receipt": str(receipt)},
                         sort_keys=True, separators=(",", ":")))
        return 0
    except Exception as error:
        print("host_worker_package_build_failed:" + str(error), file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
