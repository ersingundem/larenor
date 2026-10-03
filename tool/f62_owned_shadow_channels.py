#!/usr/bin/env python3
"""Prepare and verify the pinned FreeRDP owned-shadow channel fixture."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
from typing import Optional
import urllib.request
import urllib.parse

if __package__:
    from .native_acceptance_receipt import NativeAcceptanceReceiptError, source_revision
else:
    from native_acceptance_receipt import NativeAcceptanceReceiptError, source_revision


ROOT = Path(__file__).resolve().parents[1]
PATCH_PATH = ROOT / "tool/patches/f62-owned-shadow-channels.patch"
AUDIO_PATCH_PATH = ROOT / "tool/patches/f62-owned-shadow-audio.patch"
SOURCE_URL = (
    "https://github.com/FreeRDP/FreeRDP/releases/download/3.31.1/"
    "freerdp-3.31.1.tar.gz"
)
SOURCE_VERSION = "3.31.1"
SOURCE_COMMIT = "63b948ca5cb94307fd5444ee6e73927a41ccdab4"
SOURCE_SHA256 = "4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991"
SOURCE_PREFIX = f"freerdp-{SOURCE_VERSION}"
SOURCE_FILES = {
    "channels/disp/server/disp_main.c": "2d0b71196b7258edbb08cccb10893aa544abee06c273392ae0b25cb38244a0c6",
    "include/freerdp/server/disp.h": "02055944e2b2c3bda2f82a017556b7f3021f67b7b29c349908105fa46711af7f",
    "include/freerdp/server/shadow.h": "c91342c77b9a9ca4eff5490f19299eaaee0f47cfba2f999f0e0f82bb59003e04",
    "server/shadow/CMakeLists.txt": "ee5841906ba41048d35b73359596020b63d2eaaa15293bfd39111f2ab3897f22",
    "server/shadow/shadow_channels.c": "c347e80f6e086d60f8f3f10d130129b4d562169429f131c1efd3c951b1b09645",
    "server/shadow/shadow_client.c": "d4accb9fa930e2fcbfc356ad4f6208589df8702a2f79dc4b41e8cb6b2fd56b30",
    "server/shadow/shadow_rdpsnd.c": "659297a7d9da017546a956a3acdf9b5ec437409af4cf2a63794ad050713c4d46",
}
PATCHED_FILES = {
    "channels/disp/server/disp_main.c": "64ae2952307acbf8e74e3670102362a81323f69ae98d881b909d1eaee1de654f",
    "include/freerdp/server/disp.h": "6bd22a31d84cb495af9f962c4de344bf3dc6d5ac17b54e93bb4537afd28ac0e0",
    "include/freerdp/server/shadow.h": "3116527f6af974912e1dafefca7833f7ee9f071edbd6e559213207de277a007d",
    "server/shadow/CMakeLists.txt": "bcdf84b177a33598c62f2f1ed7eccbba56a7da8171e42452dfc1b66e8cf3bde5",
    "server/shadow/shadow_channels.c": "339bf9aaad03e7d7207ae71345f3a519159a73133621fabf7029d1ce9a8b537c",
    "server/shadow/shadow_client.c": "a07adfae3ef11288f05d72fd5c32899522a4b7ab21a6387f3679a3f5c62ac797",
    "server/shadow/shadow_larenor_channels.c": "0a64f0665c367ceb0442deaf1d3b627aab13a66359ecb5851f2636769a3b8542",
    "server/shadow/shadow_larenor_channels.h": "af7fcfca177f3eb3c5db7bbb910cd74c3fd0a3470c4b68c86eebaeeb805e0b56",
}
PATCH_SHA256 = "58e198fb1b12d8627132a53eac491d29154cc322210415f422d061b4a321c59d"
AUDIO_PATCH_SHA256 = "21251283bf48bcbcac564c6f23d08e029d2883bf918722a6f5a1a6fde4c687c5"
AUDIO_PATCHED_FILES = {
    "server/shadow/shadow_channels.c": "b22db71d11aa6d5f405a6cad7fec47be31ad2bdfb1aa11fc2489ce993bd65f7c",
    "server/shadow/shadow_client.c": "0da0cec3f6b9e5a909b3da89ecb34a9a5ee33d78f77ee0498f6d53c005a950ee",
    "server/shadow/shadow_larenor_channels.c": "56d38abe118f5be62a6293221d868e88c01d4d43fb0a110a3e2c22b3b34dae93",
    "server/shadow/shadow_larenor_channels.h": "af8d0480341af9a5fe697ed2673197c7a8b9aa324b19306cc72be98ea334e957",
    "server/shadow/shadow_rdpsnd.c": "3641cc8fded3889e1b4201b78e76f554c19aa2e03c5e6286037f5ca969df77f3",
}
FINAL_PATCHED_FILES = {**PATCHED_FILES, **AUDIO_PATCHED_FILES}
WITNESS_MAGIC = b"LRNF62C2"
WITNESS_SIZE = 64
AUDIO_WITNESS_MAGIC = b"LRNF62A1"
AUDIO_WITNESS_SIZE = 64
AUDIO_FLAG_JOINED = 0x00000001
AUDIO_FLAG_ACTIVATED = 0x00000002
AUDIO_FLAG_ARMED = 0x00000004
AUDIO_FLAG_SEND_ACCEPTED = 0x00000008
AUDIO_KNOWN_FLAGS = (
    AUDIO_FLAG_JOINED | AUDIO_FLAG_ACTIVATED | AUDIO_FLAG_ARMED | AUDIO_FLAG_SEND_ACCEPTED
)
AUDIO_FRAMES = 2205
MAX_ARCHIVE_SIZE = 32 * 1024 * 1024
MAX_EXPANDED_SIZE = 256 * 1024 * 1024
MAX_MEMBER_SIZE = 32 * 1024 * 1024
MAX_MEMBERS = 20000
MAX_CHANNEL_EVENTS = 8
MAX_FIXTURE_BINARY_SIZE = 256 * 1024 * 1024
MAX_BUILD_LOG_SIZE = 4 * 1024 * 1024
SHADOW_CLI_RELATIVE = Path("server/shadow/cli/freerdp-shadow-cli")
FLAG_CLIPBOARD_EFFECT = 0x00000001
FLAG_DISP_EFFECT = 0x00000002
FLAG_INITIAL_DISP = 0x00000004
KNOWN_FLAGS = FLAG_CLIPBOARD_EFFECT | FLAG_DISP_EFFECT | FLAG_INITIAL_DISP
DIAGNOSTIC_SOURCE_PATHS = (
    "CMakeLists.txt",
    "cmake/FindKRB5.cmake",
    "cmake/JsonDetect.cmake",
    "cmake/PlatformDefaults.cmake",
    "server/shadow/CMakeLists.txt",
    "server/shadow/X11/CMakeLists.txt",
    "server/shadow/shadow_channels.c",
    "server/shadow/shadow_client.c",
    "server/shadow/shadow_larenor_channels.c",
    "server/shadow/shadow_rdpsnd.c",
    "winpr/CMakeLists.txt",
    "winpr/libwinpr/sspi/CMakeLists.txt",
    "winpr/libwinpr/utils/CMakeLists.txt",
)
_DIAGNOSTIC_REASONS = {
    "configure": (
        ("missing_dependency", (b"Could NOT find", b"REQUIRED but not found")),
        (
            "configure_test_failed",
            (b"is not able to compile", b"Failed to detect", b"compiler identification is unknown"),
        ),
        ("invalid_configuration", (b"CMake Error", b"FATAL_ERROR")),
    ),
    "build": (
        ("link_failed", (b"undefined reference", b"ld returned")),
        ("compile_failed", (b"fatal error:", b" error:")),
    ),
}


class FixtureError(ValueError):
    pass


def require(condition, code):
    if not condition:
        raise FixtureError(code)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _open_regular(path: Path, *, max_size: int, exact_mode=None):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except OSError as error:
        raise FixtureError("invalid_file") from error
    try:
        metadata = os.fstat(fd)
        require(
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_nlink == 1
            and metadata.st_uid == os.getuid()
            and metadata.st_size <= max_size
            and (exact_mode is None or stat.S_IMODE(metadata.st_mode) == exact_mode),
            "invalid_file",
        )
        return fd, metadata
    except Exception:
        os.close(fd)
        raise


def _sha256_fd(fd: int) -> str:
    digest = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    os.lseek(fd, 0, os.SEEK_SET)
    return digest.hexdigest()


def _member_relative(member: tarfile.TarInfo) -> PurePosixPath:
    path = PurePosixPath(member.name)
    require(
        not path.is_absolute()
        and len(path.parts) >= 1
        and path.parts[0] == SOURCE_PREFIX
        and ".." not in path.parts
        and all(part not in ("", ".") for part in path.parts),
        "unsafe_source_archive",
    )
    require(member.isfile() or member.isdir(), "unsafe_source_archive")
    if len(path.parts) == 1:
        require(member.isdir(), "unsafe_source_archive")
        return PurePosixPath(".")
    return PurePosixPath(*path.parts[1:])


def verify_source(archive: Path):
    try:
        fd, metadata = _open_regular(archive, max_size=MAX_ARCHIVE_SIZE)
    except FixtureError as error:
        raise FixtureError("invalid_source_archive") from error
    try:
        require(metadata.st_size > 0, "invalid_source_archive")
        require(_sha256_fd(fd) == SOURCE_SHA256, "source_digest_mismatch")
        with os.fdopen(fd, "rb", closefd=False) as source, tarfile.open(fileobj=source, mode="r:gz") as bundle:
            members = bundle.getmembers()
            require(0 < len(members) <= MAX_MEMBERS, "unsafe_source_archive")
            total = 0
            by_name = {}
            archive_names = set()
            for member in members:
                require(member.name not in archive_names, "unsafe_source_archive")
                archive_names.add(member.name)
                relative = _member_relative(member)
                if relative == PurePosixPath("."):
                    continue
                if member.isfile():
                    require(member.size <= MAX_MEMBER_SIZE, "unsafe_source_archive")
                    total += member.size
                    require(total <= MAX_EXPANDED_SIZE, "unsafe_source_archive")
                key = str(relative)
                require(key not in by_name, "unsafe_source_archive")
                by_name[key] = member
            for relative, expected in SOURCE_FILES.items():
                member = by_name.get(relative)
                require(member is not None and member.isfile(), "source_file_mismatch")
                stream = bundle.extractfile(member)
                require(stream is not None, "source_file_mismatch")
                require(hashlib.sha256(stream.read()).hexdigest() == expected, "source_file_mismatch")
    except (OSError, tarfile.TarError) as error:
        raise FixtureError("invalid_source_archive") from error
    finally:
        os.close(fd)


def _extract_verified(archive: Path, output: Path):
    output.mkdir(mode=0o700)
    archive_fd = None
    try:
        archive_fd, _ = _open_regular(archive, max_size=MAX_ARCHIVE_SIZE)
        require(_sha256_fd(archive_fd) == SOURCE_SHA256, "source_digest_mismatch")
        with os.fdopen(archive_fd, "rb", closefd=False) as source, tarfile.open(
            fileobj=source, mode="r:gz"
        ) as bundle:
            for member in bundle.getmembers():
                relative = _member_relative(member)
                if relative == PurePosixPath("."):
                    continue
                destination = output.joinpath(*relative.parts)
                if member.isdir():
                    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
                    continue
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                stream = bundle.extractfile(member)
                require(stream is not None, "invalid_source_archive")
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                destination_fd = os.open(
                    destination, flags, 0o700 if member.mode & 0o111 else 0o600
                )
                try:
                    with os.fdopen(destination_fd, "wb", closefd=False) as target:
                        shutil.copyfileobj(stream, target, length=1024 * 1024)
                    os.fsync(destination_fd)
                finally:
                    os.close(destination_fd)
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise
    finally:
        if archive_fd is not None:
            os.close(archive_fd)


def _verified_patch_bytes(patch: Path, expected_digest: str) -> bytes:
    fd = None
    try:
        fd, metadata = _open_regular(patch, max_size=1024 * 1024)
        require(_sha256_fd(fd) == expected_digest, "patch_digest_mismatch")
        os.lseek(fd, 0, os.SEEK_SET)
        data = os.read(fd, metadata.st_size + 1)
        require(len(data) == metadata.st_size, "patch_digest_mismatch")
        return data
    finally:
        if fd is not None:
            os.close(fd)


def verify_patched_source(
    source: Path,
    patch: Path = PATCH_PATH,
    audio_patch: Path | None = None,
):
    require(source.is_dir() and not source.is_symlink(), "invalid_prepared_source")
    _verified_patch_bytes(patch, PATCH_SHA256)
    selected_audio_patch = AUDIO_PATCH_PATH if audio_patch is None and patch == PATCH_PATH else audio_patch
    if selected_audio_patch is not None:
        _verified_patch_bytes(selected_audio_patch, AUDIO_PATCH_SHA256)
    expected_files = FINAL_PATCHED_FILES if selected_audio_patch is not None else PATCHED_FILES
    for relative, expected in expected_files.items():
        path = source / relative
        try:
            fd, _ = _open_regular(path, max_size=MAX_MEMBER_SIZE)
            require(_sha256_fd(fd) == expected, "patched_source_mismatch")
        except FixtureError as error:
            raise FixtureError("patched_source_mismatch") from error
        finally:
            if "fd" in locals():
                os.close(fd)
                del fd


def prepare_source(
    archive: Path,
    output: Path,
    patch: Path = PATCH_PATH,
    audio_patch: Path | None = None,
):
    require(not output.exists() and not output.is_symlink(), "output_must_not_exist")
    verify_source(archive)
    patch_bytes = _verified_patch_bytes(patch, PATCH_SHA256)
    selected_audio_patch = AUDIO_PATCH_PATH if audio_patch is None and patch == PATCH_PATH else audio_patch
    audio_patch_bytes = (
        _verified_patch_bytes(selected_audio_patch, AUDIO_PATCH_SHA256)
        if selected_audio_patch is not None else None
    )
    _extract_verified(archive, output)
    try:
        run = subprocess.run(
            ["/usr/bin/patch", "-N", "-p1"],
            cwd=output,
            input=patch_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"},
            timeout=30,
            check=False,
        )
        require(run.returncode == 0, "patch_apply_failed")
        if audio_patch_bytes is not None:
            audio_run = subprocess.run(
                ["/usr/bin/patch", "-N", "-p1"],
                cwd=output,
                input=audio_patch_bytes,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"},
                timeout=30,
                check=False,
            )
            require(audio_run.returncode == 0, "patch_apply_failed")
        verify_patched_source(output, patch, selected_audio_patch)
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise


class _BoundedRedirect(urllib.request.HTTPRedirectHandler):
    _hosts = {"github.com", "release-assets.githubusercontent.com"}

    def redirect_request(self, request, fp, code, msg, headers, new_url):
        parsed = urllib.parse.urlparse(new_url)
        if parsed.scheme != "https" or parsed.hostname not in self._hosts:
            raise FixtureError("unsafe_source_redirect")
        return super().redirect_request(request, fp, code, msg, headers, new_url)


def fetch_source(output: Path):
    require(not output.exists() and not output.is_symlink(), "output_must_not_exist")
    opener = urllib.request.build_opener(_BoundedRedirect())
    request = urllib.request.Request(SOURCE_URL, headers={"User-Agent": "Larenor-F62-fixture/1"})
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(output, flags, 0o600)
    try:
        with opener.open(request, timeout=30) as response, os.fdopen(fd, "wb", closefd=False) as stream:
            total = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                require(total <= MAX_ARCHIVE_SIZE, "source_too_large")
                stream.write(chunk)
            stream.flush()
            os.fsync(fd)
    except Exception:
        output.unlink(missing_ok=True)
        raise
    finally:
        os.close(fd)
    verify_source(output)


def _private_log(path: Path):
    require(not path.exists() and not path.is_symlink(), "log_must_not_exist")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    return os.fdopen(fd, "wb")


def _fatal_diagnostic_block(stage: str, data: bytes) -> bytes:
    lines = data.splitlines()
    if stage == "configure":
        marker = b"CMake Error"
        width = 16
    else:
        marker = None
        width = 4
    for index, line in enumerate(lines):
        if (marker is not None and marker in line) or (
            marker is None
            and any(
                token in line
                for token in (b"fatal error:", b" error:", b"undefined reference", b"ld returned")
            )
        ):
            return b"\n".join(item[:1024] for item in lines[index : index + width])
    return b""


def _diagnostic_reason(stage: str, data: bytes) -> str:
    block = _fatal_diagnostic_block(stage, data)
    for reason, tokens in _DIAGNOSTIC_REASONS[stage]:
        if any(token in block for token in tokens):
            return reason
    return "configure_failed" if stage == "configure" else "build_failed"


def _diagnostic_location(data: bytes):
    text = data.decode("utf-8", errors="replace")
    for relative in sorted(DIAGNOSTIC_SOURCE_PATHS, key=len, reverse=True):
        match = re.search(
            r"(?:^|[ /])" + re.escape(relative) + r":([1-9][0-9]{0,5})(?:[^0-9]|$)",
            text,
            flags=re.MULTILINE,
        )
        if match:
            return {"path": relative, "line": int(match.group(1))}
    return None


def _write_failure_receipt(log: Path, output: Path, *, stage: str, code: str, cmake: Path):
    require(stage in ("configure", "build"), "invalid_diagnostic_stage")
    require(
        code == ("configure_failed" if stage == "configure" else "compile_failed"),
        "invalid_diagnostic_code",
    )
    fd = None
    try:
        fd, metadata = _open_regular(log, max_size=MAX_BUILD_LOG_SIZE, exact_mode=0o600)
        digest = _sha256_fd(fd)
        data = os.read(fd, metadata.st_size + 1)
        require(len(data) == metadata.st_size, "invalid_build_log")
    except FixtureError as error:
        raise FixtureError("invalid_build_log") from error
    finally:
        if fd is not None:
            os.close(fd)
    try:
        revision = source_revision(ROOT)
    except NativeAcceptanceReceiptError as error:
        raise FixtureError("invalid_failure_receipt") from error
    receipt = {
        "schemaVersion": 1,
        "stage": stage,
        "code": code,
        "reason": _diagnostic_reason(stage, data),
        "sourceRevision": revision,
        "sourceVersion": SOURCE_VERSION,
        "upstreamSourceRevision": SOURCE_COMMIT,
        "sourceSha256": SOURCE_SHA256,
        "patchSha256": PATCH_SHA256,
        "audioPatchSha256": AUDIO_PATCH_SHA256,
        "cmakeInstalled": cmake.is_file() and not cmake.is_symlink(),
        "privateLogSha256": digest,
        "sourceLocation": _diagnostic_location(_fatal_diagnostic_block(stage, data)),
    }
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        output_fd = os.open(output, flags, 0o600)
    except OSError as error:
        raise FixtureError("invalid_failure_receipt") from error
    try:
        os.fchmod(output_fd, 0o600)
        metadata = os.fstat(output_fd)
        require(
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_nlink == 1
            and metadata.st_uid == os.getuid()
            and stat.S_IMODE(metadata.st_mode) == 0o600,
            "invalid_failure_receipt",
        )
        payload = (json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n").encode(
            "ascii"
        )
        with os.fdopen(output_fd, "wb", closefd=False) as stream:
            stream.write(payload)
            stream.flush()
        os.fsync(output_fd)
    finally:
        os.close(output_fd)


def _record_failure(log: Path, output: Optional[Path], *, stage: str, code: str, cmake: Path):
    if output is None:
        return
    try:
        _write_failure_receipt(log, output, stage=stage, code=code, cmake=cmake)
    except (FixtureError, OSError):
        # Diagnostic publication must not replace the original build failure.
        pass


def build_fixture(
    source: Path,
    build: Path,
    cmake: Path,
    log: Path,
    *,
    jobs: int,
    failure_receipt: Optional[Path] = None,
):
    require(source.is_dir() and not source.is_symlink(), "invalid_prepared_source")
    require(not build.exists() and not build.is_symlink(), "build_must_not_exist")
    require(cmake.is_file() and not cmake.is_symlink(), "invalid_cmake")
    require(1 <= jobs <= 8, "invalid_jobs")
    verify_patched_source(source)
    environment = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(build.parent.resolve()),
        "LC_ALL": "C",
        "LANG": "C",
    }
    configure = [
        str(cmake.resolve()),
        "-S",
        str(source.resolve()),
        "-B",
        str(build.resolve()),
        "-DWITH_LARENOR_F62_OWNED_CHANNELS=ON",
        "-DWITH_SERVER=ON",
        "-DWITH_SERVER_CHANNELS=ON",
        "-DWITH_CHANNELS=ON",
        "-DCHANNEL_CLIPRDR=ON",
        "-DCHANNEL_CLIPRDR_SERVER=ON",
        "-DCHANNEL_DISP=ON",
        "-DCHANNEL_DISP_SERVER=ON",
        "-DCHANNEL_RDPSND=ON",
        "-DCHANNEL_RDPSND_SERVER=ON",
        "-DCHANNEL_DRDYNVC=ON",
        "-DCHANNEL_DRDYNVC_SERVER=ON",
        "-DWITH_SHADOW=ON",
        "-DWITH_SHADOW_SUBSYSTEM=ON",
        "-DWITH_CLIENT=OFF",
        "-DWITH_CLIENT_COMMON=OFF",
        "-DWITH_KRB5=OFF",
        "-DWITH_FFMPEG=OFF",
        "-DWITH_OPENH264=OFF",
        "-DWITH_OPUS=OFF",
        "-DWITH_WEBP=OFF",
        "-DWITH_JPEG=OFF",
        "-DWITH_PNG=OFF",
        "-DWITH_CUPS=OFF",
        "-DWITH_PCSC=OFF",
        "-DWITH_PULSE=OFF",
        "-DWITH_ALSA=OFF",
        "-DWITH_WAYLAND=OFF",
        "-DWITH_X11=ON",
        "-DWITH_SWSCALE=OFF",
        "-DWITH_SERVER_INTERFACE=ON",
        "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
    ]
    compile_command = [
        str(cmake.resolve()),
        "--build",
        str(build.resolve()),
        "--target",
        "freerdp-shadow-cli",
        "--parallel",
        str(jobs),
    ]
    configure_failed = False
    compile_failed = False
    with _private_log(log) as stream:
        try:
            configured = subprocess.run(
                configure,
                stdout=stream,
                stderr=subprocess.STDOUT,
                env=environment,
                timeout=300,
                check=False,
            )
            configure_failed = configured.returncode != 0
        except subprocess.TimeoutExpired:
            configure_failed = True
        if not configure_failed:
            try:
                compiled = subprocess.run(
                    compile_command,
                    stdout=stream,
                    stderr=subprocess.STDOUT,
                    env=environment,
                    timeout=900,
                    check=False,
                )
                compile_failed = compiled.returncode != 0
            except subprocess.TimeoutExpired:
                compile_failed = True
        stream.flush()
        os.fsync(stream.fileno())
    if configure_failed:
        _record_failure(
            log,
            failure_receipt,
            stage="configure",
            code="configure_failed",
            cmake=cmake,
        )
        raise FixtureError("configure_failed")
    if compile_failed:
        _record_failure(
            log,
            failure_receipt,
            stage="build",
            code="compile_failed",
            cmake=cmake,
        )
        raise FixtureError("compile_failed")
    executable = build / SHADOW_CLI_RELATIVE
    try:
        fd, metadata = _open_regular(executable, max_size=MAX_FIXTURE_BINARY_SIZE)
        require(metadata.st_size > 0 and metadata.st_mode & 0o111 != 0, "invalid_fixture_binary")
    except FixtureError as error:
        raise FixtureError("invalid_fixture_binary") from error
    finally:
        if "fd" in locals():
            os.close(fd)
    return executable


def parse_witness(path: Path):
    try:
        fd, metadata = _open_regular(path, max_size=WITNESS_SIZE, exact_mode=0o600)
        require(metadata.st_size == WITNESS_SIZE, "invalid_witness")
        data = os.read(fd, WITNESS_SIZE + 1)
    except FixtureError as error:
        raise FixtureError("invalid_witness") from error
    finally:
        if "fd" in locals():
            os.close(fd)
    require(len(data) == WITNESS_SIZE, "invalid_witness")
    magic, version, size, flags, format_lists, requests, responses, empty, layouts, errors, reserved = struct.unpack(
        "<8sII7I20s", data
    )
    counts = (format_lists, requests, responses, empty, layouts, errors)
    require(
        magic == WITNESS_MAGIC
        and version == 2
        and size == WITNESS_SIZE
        and flags & ~KNOWN_FLAGS == 0
        and all(value <= MAX_CHANNEL_EVENTS for value in counts)
        and reserved == b"\0" * len(reserved),
        "invalid_witness",
    )
    return {
        "schemaVersion": 2,
        "initialDisplayAccepted": bool(flags & FLAG_INITIAL_DISP),
        "clipboardEffect": bool(flags & FLAG_CLIPBOARD_EFFECT),
        "displayEffect": bool(flags & FLAG_DISP_EFFECT),
        "formatLists": format_lists,
        "dataRequests": requests,
        "dataResponses": responses,
        "emptyResponses": empty,
        "displayLayouts": layouts,
        "channelErrors": errors,
    }


def read_witness(path: Path):
    value = parse_witness(path)
    require(
        value["channelErrors"] == 0
        and value["emptyResponses"] <= value["dataResponses"] <= value["dataRequests"]
        and value["dataRequests"] <= value["formatLists"]
        and (
            not value["clipboardEffect"]
            or (
                value["formatLists"] > 0
                and value["dataRequests"] > 0
                and value["dataResponses"] > value["emptyResponses"]
            )
        )
        and (not value["initialDisplayAccepted"] or value["displayLayouts"] > 0)
        and (not value["displayEffect"] or (value["initialDisplayAccepted"] and value["displayLayouts"] == 2)),
        "invalid_witness",
    )
    return value


def read_lifetimes(base: Path):
    require(not base.exists() and not base.is_symlink(), "invalid_lifetime_witnesses")
    third = Path(f"{base}.3")
    require(not third.exists() and not third.is_symlink(), "invalid_lifetime_witnesses")
    first = read_witness(Path(f"{base}.1"))
    second = read_witness(Path(f"{base}.2"))
    require(
        first["clipboardEffect"]
        and first["displayEffect"]
        and first["initialDisplayAccepted"]
        and first["displayLayouts"] == 2
        and second["initialDisplayAccepted"]
        and second["displayLayouts"] == 1
        and not second["displayEffect"]
        and not second["clipboardEffect"]
        and second["formatLists"] == 0
        and second["dataRequests"] == 0
        and second["dataResponses"] == 0
        and second["emptyResponses"] == 0,
        "invalid_lifetime_witnesses",
    )
    return {"schemaVersion": 2, "enabled": first, "disabled": second}


def parse_audio_witness(path: Path):
    try:
        fd, metadata = _open_regular(
            path, max_size=AUDIO_WITNESS_SIZE, exact_mode=0o600
        )
        require(metadata.st_size == AUDIO_WITNESS_SIZE, "invalid_audio_witness")
        data = os.read(fd, AUDIO_WITNESS_SIZE + 1)
    except FixtureError as error:
        raise FixtureError("invalid_audio_witness") from error
    finally:
        if "fd" in locals():
            os.close(fd)
    require(len(data) == AUDIO_WITNESS_SIZE, "invalid_audio_witness")
    (
        magic,
        version,
        size,
        ordinal,
        flags,
        activations,
        arm_records,
        send_calls,
        accepted,
        confirmations,
        frames,
        errors,
        reserved,
    ) = struct.unpack("<8sII9I12s", data)
    counts = (
        activations,
        arm_records,
        send_calls,
        accepted,
        confirmations,
        errors,
    )
    require(
        magic == AUDIO_WITNESS_MAGIC
        and version == 1
        and size == AUDIO_WITNESS_SIZE
        and ordinal in (1, 2)
        and flags & ~AUDIO_KNOWN_FLAGS == 0
        and all(value <= MAX_CHANNEL_EVENTS for value in counts)
        and frames <= AUDIO_FRAMES
        and reserved == b"\0" * len(reserved),
        "invalid_audio_witness",
    )
    return {
        "schemaVersion": 1,
        "ordinal": ordinal,
        "joined": bool(flags & AUDIO_FLAG_JOINED),
        "activated": bool(flags & AUDIO_FLAG_ACTIVATED),
        "armed": bool(flags & AUDIO_FLAG_ARMED),
        "sendAccepted": bool(flags & AUDIO_FLAG_SEND_ACCEPTED),
        "activations": activations,
        "armRecords": arm_records,
        "sendCalls": send_calls,
        "acceptedCount": accepted,
        "waveConfirmations": confirmations,
        "frames": frames,
        "audioErrors": errors,
    }


def read_audio_lifetimes(base: Path):
    require(not base.exists() and not base.is_symlink(), "invalid_audio_lifetimes")
    third = Path(f"{base}.3")
    require(not third.exists() and not third.is_symlink(), "invalid_audio_lifetimes")
    enabled = parse_audio_witness(Path(f"{base}.1"))
    disabled = parse_audio_witness(Path(f"{base}.2"))
    require(
        enabled["ordinal"] == 1
        and enabled["joined"]
        and enabled["activated"]
        and enabled["armed"]
        and enabled["sendAccepted"]
        and enabled["activations"] == 1
        and enabled["armRecords"] == 1
        and enabled["sendCalls"] == 1
        and enabled["acceptedCount"] == 1
        and enabled["frames"] == AUDIO_FRAMES
        and enabled["audioErrors"] == 0
        and disabled["ordinal"] == 2
        and not disabled["joined"]
        and not disabled["activated"]
        and not disabled["armed"]
        and not disabled["sendAccepted"]
        and disabled["activations"] == 0
        and disabled["armRecords"] == 0
        and disabled["sendCalls"] == 0
        and disabled["acceptedCount"] == 0
        and disabled["waveConfirmations"] == 0
        and disabled["frames"] == 0
        and disabled["audioErrors"] == 0,
        "invalid_audio_lifetimes",
    )
    return {"schemaVersion": 1, "enabled": enabled, "disabled": disabled}


def main(argv=None):
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    fetch = commands.add_parser("fetch")
    fetch.add_argument("output", type=Path)
    verify = commands.add_parser("verify-source")
    verify.add_argument("archive", type=Path)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("archive", type=Path)
    prepare.add_argument("output", type=Path)
    build = commands.add_parser("build")
    build.add_argument("source", type=Path)
    build.add_argument("build", type=Path)
    build.add_argument("--cmake", required=True, type=Path)
    build.add_argument("--log", required=True, type=Path)
    build.add_argument("--failure-receipt", type=Path)
    build.add_argument("--jobs", type=int, default=2)
    witness = commands.add_parser("verify-witness")
    witness.add_argument("path", type=Path)
    lifetimes = commands.add_parser("verify-lifetimes")
    lifetimes.add_argument("base", type=Path)
    audio_lifetimes = commands.add_parser("verify-audio-lifetimes")
    audio_lifetimes.add_argument("base", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "fetch":
            fetch_source(args.output)
        elif args.command == "verify-source":
            verify_source(args.archive)
        elif args.command == "prepare":
            prepare_source(args.archive, args.output)
        elif args.command == "build":
            build_fixture(
                args.source,
                args.build,
                args.cmake,
                args.log,
                jobs=args.jobs,
                failure_receipt=args.failure_receipt,
            )
        elif args.command == "verify-witness":
            print(json.dumps(read_witness(args.path), sort_keys=True))
        elif args.command == "verify-lifetimes":
            print(json.dumps(read_lifetimes(args.base), sort_keys=True))
        elif args.command == "verify-audio-lifetimes":
            print(json.dumps(read_audio_lifetimes(args.base), sort_keys=True))
        return 0
    except FixtureError as error:
        print(f"F62 owned shadow channels error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
