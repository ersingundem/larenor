#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import pathlib
import re
import secrets
import signal
import socket
import ssl
import stat
import struct
import subprocess
import tarfile
import time
from types import SimpleNamespace

import f62_owned_rdpdr_target as target_package
import f62_rdpgw_owned_fixture as owned
from native_acceptance_receipt import source_revision


FREERDP_REVISION = "63b948ca5cb94307fd5444ee6e73927a41ccdab4"
FREERDP_ARCHIVE_SHA256 = (
    "4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991"
)
TARGET_PATCH_SHA256 = "52b61d9ecfef7c8d047ee558177ab2b0b664294729a2035c5045041a183eafb4"
TARGET_MANIFEST_SHA256 = (
    "5a5ed427179aaad89b111c6b9bae9bc594b8c78abf7efb5e10c24ee09dfbf1f0"
)
PROBE_NAME = "f62GatewayRdpdrLinuxProbe"
DEVICE_NAME = "LrnXfer"
UPLOAD_PREFIX = "Larenor-F62-Gateway-upload:"
OUTBOUND_PREFIX = "Larenor-F62-Gateway-outbound:"
BUILD_RECEIPT_KEYS = {
    "schemaVersion",
    "sourceRevision",
    "sourceArchiveSha256",
    "targetPatchSha256",
    "sourceManifestSha256",
    "cmakeArgumentsSha256",
    "shadowBinarySha256",
    "xfreerdpBinarySha256",
    "witnessSchemaVersion",
    "deviceName",
}
PUBLIC_RECEIPT_KEYS = {
    "runnerSourceRevision",
    "schemaVersion",
    "scope",
    "sourceRevision",
    "sourceArchiveSha256",
    "targetPatchSha256",
    "sourceManifestSha256",
    "rdpgwRevision",
    "rdpgwArchiveSha256",
    "shadowBinarySha256",
    "xfreerdpBinarySha256",
    "gatewayBinarySha256",
    "authBinarySha256",
    "gatewayAuthObserved",
    "gatewayPinMatched",
    "targetPinMatched",
    "configuredTargetExact",
    "directTargetBlocked",
    "targetConnectedThroughGateway",
    "rdpdrUploadMatched",
    "rdpdrDownloadMatched",
    "targetCleanClose",
    "singleAuthenticatedSession",
    "cleanupComplete",
    "androidProductExercised",
    "runtimeAccepted",
    "featureAccepted",
}
BUILD_FAILURE_RECEIPT_KEYS = {
    "schemaVersion", "runnerSourceRevision", "sourceRevision", "sourceArchiveSha256",
    "targetPatchSha256", "sourceManifestSha256", "phase", "failureCode",
    "exitCode", "logSha256", "compilerSource", "compilerLine",
    "compilerErrorClass", "featureAccepted",
}
BUILD_FAILURE_CODES = frozenset(
    {
        "timeout", "logTooLarge", "missingDependency", "configurationError",
        "missingHeader", "compilerError", "linkerError", "resourceTerminated",
        "commandFailed",
    }
)
_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_COMPILER_SOURCES = {
    b"shadow_owned_rdpdr.c": ("ownedRdpdr", 553),
    b"shadow_owned_rdpdr.h": ("ownedRdpdrHeader", 18),
    b"shadow_channels.c": ("shadowChannels", 66),
    b"shadow_channels.h": ("shadowChannelsHeader", 45),
    b"shadow_client.c": ("shadowClient", 3128),
    b"shadow.h": ("shadowPublicHeader", 438),
}
_COMPILER_ERROR_CLASSES = frozenset(
    {
        "missingHeader", "undeclaredIdentifier", "missingMember",
        "incompatibleType", "callSignature", "syntaxError", "linkUndefined",
        "other",
    }
)
_IN_CLOSE_WRITE = 0x00000008
_IN_CLOEXEC = 0x00080000
_IN_NONBLOCK = 0x00000800


class ProbeError(RuntimeError):
    pass


def fail(stage: str) -> None:
    raise ProbeError(stage)


def _script_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve(strict=True).parent


def _patch_path() -> pathlib.Path:
    return _script_root() / "patches" / "f62-owned-shadow-rdpdr.patch"


def _manifest_path() -> pathlib.Path:
    return _script_root() / "manifests" / "f62-owned-shadow-rdpdr-source.json"


def _write_private_json(path: pathlib.Path, value: dict) -> None:
    owned.private_regular(path, absent=True)
    raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "ascii"
    )
    fd = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600
    )
    try:
        with os.fdopen(fd, "wb", closefd=True) as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        raise


def _safe_extract_freerdp(
    archive: pathlib.Path, destination: pathlib.Path
) -> pathlib.Path:
    owned.private_regular(archive)
    if owned.sha256(archive) != FREERDP_ARCHIVE_SHA256:
        fail("freerdpArchiveHashMismatch")
    destination.mkdir(mode=0o700)
    owned.private_dir(destination)
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        if not members or len(members) > 50000:
            fail("unsafeFreerdpArchive")
        roots: set[str] = set()
        for member in members:
            pure = pathlib.PurePosixPath(member.name)
            if member.name.startswith("/") or ".." in pure.parts or len(pure.parts) < 1:
                fail("unsafeFreerdpArchive")
            roots.add(pure.parts[0])
            if (
                member.issym()
                or member.islnk()
                or not (member.isfile() or member.isdir())
            ):
                fail("unsafeFreerdpArchive")
        if len(roots) != 1:
            fail("unsafeFreerdpArchive")
        bundle.extractall(destination, filter="data")
    source = destination / next(iter(roots))
    for item in source.rglob("*"):
        os.chmod(item, 0o700 if item.is_dir() else 0o600)
    os.chmod(source, 0o700)
    owned.private_dir(source)
    return source


def _classify_build_failure(phase: str, raw: bytes) -> str:
    if phase == "configure":
        if (
            b"Could NOT find" in raw
            or b"No package '" in raw
            or b"Could not find a package configuration file provided by" in raw
        ):
            return "missingDependency"
        if b"CMake Error" in raw:
            return "configurationError"
        return "commandFailed"
    if b"fatal error:" in raw and b"No such file or directory" in raw:
        return "missingHeader"
    if re.search(rb":[0-9]+:[0-9]+: error:", raw):
        return "compilerError"
    if b"undefined reference to" in raw or b"collect2: error:" in raw:
        return "linkerError"
    if b"Killed" in raw or b"out of memory" in raw.lower():
        return "resourceTerminated"
    return "commandFailed"


def _compiler_diagnostic(raw: bytes) -> tuple[str | None, int | None, str | None]:
    """Reduce private compiler output to a fixed, source-bound diagnostic tuple."""
    if b"undefined reference to" in raw or b"collect2: error:" in raw:
        return None, None, "linkUndefined"
    pattern = re.compile(
        rb"(?:^|\n)(?:[^\r\n:]+[/\\])?(?P<file>[A-Za-z0-9_.-]+):"
        rb"(?P<line>[0-9]{1,6}):[0-9]{1,6}: (?:fatal )?error: "
        rb"(?P<message>[^\r\n]{1,512})(?=\r?\n|$)"
    )
    for match in pattern.finditer(raw):
        bound = _COMPILER_SOURCES.get(match.group("file"))
        if bound is None:
            continue
        source, maximum = bound
        line = int(match.group("line"))
        if not 1 <= line <= maximum:
            continue
        message = match.group("message").lower()
        if b"no such file or directory" in message:
            error_class = "missingHeader"
        elif b"undeclared" in message or b"not declared" in message:
            error_class = "undeclaredIdentifier"
        elif b"no member named" in message or b"has no member named" in message:
            error_class = "missingMember"
        elif b"incompatible" in message or b"conflicting types" in message:
            error_class = "incompatibleType"
        elif b"too few arguments" in message or b"too many arguments" in message:
            error_class = "callSignature"
        elif b"expected" in message:
            error_class = "syntaxError"
        else:
            error_class = "other"
        return source, line, error_class
    return None, None, None


def _write_build_failure(
    path: pathlib.Path,
    *,
    phase: str,
    failure_code: str,
    exit_code: int | None,
    log: pathlib.Path,
    compiler_diagnostic: tuple[str | None, int | None, str | None] = (None, None, None),
) -> None:
    compiler_source, compiler_line, compiler_error_class = compiler_diagnostic
    source_line_bounds = {value[0]: value[1] for value in _COMPILER_SOURCES.values()}
    if (
        phase not in ("configure", "compile")
        or failure_code not in BUILD_FAILURE_CODES
        or (exit_code is not None and (type(exit_code) is not int or exit_code == 0 or not -255 <= exit_code <= 255))
        or compiler_source not in ({value[0] for value in _COMPILER_SOURCES.values()} | {None})
        or (compiler_line is not None and (type(compiler_line) is not int or compiler_line < 1))
        or (compiler_source is not None and (compiler_line is None or compiler_line > source_line_bounds[compiler_source]))
        or compiler_error_class not in (_COMPILER_ERROR_CLASSES | {None})
        or ((compiler_source is None) != (compiler_line is None))
        or (compiler_source is not None and compiler_error_class in (None, "linkUndefined"))
        or (compiler_source is None and compiler_error_class not in (None, "linkUndefined"))
        or (compiler_error_class == "linkUndefined" and failure_code != "linkerError")
        or (failure_code not in ("compilerError", "missingHeader", "linkerError") and
            compiler_diagnostic != (None, None, None))
    ):
        fail("invalidBuildFailureReceipt")
    value = {
        "schemaVersion": 2,
        "runnerSourceRevision": source_revision(pathlib.Path(__file__).resolve().parents[1]),
        "sourceRevision": FREERDP_REVISION,
        "sourceArchiveSha256": FREERDP_ARCHIVE_SHA256,
        "targetPatchSha256": TARGET_PATCH_SHA256,
        "sourceManifestSha256": TARGET_MANIFEST_SHA256,
        "phase": phase,
        "failureCode": failure_code,
        "exitCode": exit_code,
        "logSha256": owned.sha256(log),
        "compilerSource": compiler_source,
        "compilerLine": compiler_line,
        "compilerErrorClass": compiler_error_class,
        "featureAccepted": False,
    }
    if set(value) != BUILD_FAILURE_RECEIPT_KEYS:
        fail("invalidBuildFailureReceipt")
    _write_private_json(path, value)


def _run_build(
    argv: list[str], *, cwd: pathlib.Path, log: pathlib.Path, timeout: int,
    phase: str, failure_receipt: pathlib.Path,
) -> None:
    if not argv or not pathlib.Path(argv[0]).is_absolute():
        fail("nonAbsoluteCommand")
    owned.private_regular(log, absent=True)
    fd = os.open(
        log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600
    )
    timed_out = False
    try:
        with os.fdopen(fd, "wb", closefd=True) as stream:
            try:
                process = subprocess.run(
                    argv,
                    cwd=cwd,
                    env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                    stdin=subprocess.DEVNULL,
                    stdout=stream,
                    stderr=subprocess.STDOUT,
                    timeout=timeout,
                    check=False,
                )
            except subprocess.TimeoutExpired:
                timed_out = True
        if timed_out:
            _write_build_failure(
                failure_receipt, phase=phase, failure_code="timeout",
                exit_code=None, log=log,
            )
            raise ProbeError("freerdpBuildTimeout")
        if log.stat().st_size > 8 * 1024 * 1024:
            _write_build_failure(
                failure_receipt, phase=phase, failure_code="logTooLarge",
                exit_code=process.returncode or None, log=log,
            )
            fail("freerdpBuildLogTooLarge")
        if process.returncode != 0:
            raw = log.read_bytes()
            failure_code = _classify_build_failure(phase, raw)
            _write_build_failure(
                failure_receipt, phase=phase, failure_code=failure_code,
                exit_code=process.returncode, log=log,
                compiler_diagnostic=(
                    _compiler_diagnostic(raw)
                    if failure_code in ("compilerError", "missingHeader", "linkerError")
                    else (None, None, None)
                ),
            )
            fail("freerdpBuildFailed")
    finally:
        os.chmod(log, 0o600)


def _private_source_copy(
    source: pathlib.Path, destination: pathlib.Path, digest: str
) -> pathlib.Path:
    # The checkout contains public reviewed sources, not private runtime data.
    # Validate the non-writable source, then give the strict package verifier
    # its own immutable 0600 copy inside the disposable workspace.
    info = source.lstat()
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISREG(info.st_mode)
        or info.st_mode & 0o022
    ):
        fail("unsafeReviewedSource")
    raw = source.read_bytes()
    if not 0 < len(raw) <= 256 * 1024 or hashlib.sha256(raw).hexdigest() != digest:
        fail("targetSourceBindingMismatch")
    fd = os.open(
        destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    with os.fdopen(fd, "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    return destination


def _cmake_arguments(source: pathlib.Path, build: pathlib.Path) -> list[str]:
    return [
        "/usr/bin/cmake",
        "-S",
        str(source),
        "-B",
        str(build),
        "-G",
        "Ninja",
        "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
        "-DCMAKE_INSTALL_PREFIX=/usr",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBUILD_TESTING=OFF",
        "-DWITH_FUSE=OFF",
        "-DWITH_SMARTCARD_EMULATE=OFF",
        "-DWITH_CLIENT=ON",
        "-DWITH_CLIENT_COMMON=ON",
        "-DWITH_CLIENT_CHANNELS=ON",
        "-DWITH_X11=ON",
        "-DWITH_SERVER=ON",
        "-DWITH_SERVER_CHANNELS=ON",
        "-DWITH_SHADOW=ON",
        "-DWITH_SHADOW_SUBSYSTEM=ON",
        "-DWITH_KRB5=OFF",
        "-DWITH_PAM=OFF",
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
        "-DWITH_SWSCALE=OFF",
        "-DWITH_SDL=OFF",
        "-DWITH_MANPAGES=OFF",
        "-DWITH_SAMPLE=OFF",
        "-DCHANNEL_RDPDR=ON",
        "-DCHANNEL_RDPDR_CLIENT=ON",
        "-DCHANNEL_RDPDR_SERVER=ON",
        "-DCHANNEL_CLIPRDR=ON",
        "-DCHANNEL_CLIPRDR_SERVER=ON",
        "-DCHANNEL_RDPSND=OFF",
        "-DCHANNEL_AUDIN=OFF",
        "-DCHANNEL_DRDYNVC=OFF",
    ]


def _verify_xfreerdp(binary: pathlib.Path) -> None:
    owned.private_regular(binary, executable=True)
    raw = binary.read_bytes()
    if len(raw) < 64 or raw[:6] != b"\x7fELF\x02\x01":
        fail("invalidXfreerdpBinary")
    _, machine = struct.unpack_from("<HH", raw, 16)
    if machine != 62 or b"args-from" not in raw or b"LrnXfer" in raw:
        # LrnXfer is a runtime argument and must not be compiled into the stock client.
        fail("invalidXfreerdpBinary")


def build_freerdp(args: argparse.Namespace) -> None:
    owned.require_owned_linux()
    workspace = pathlib.Path(args.workspace)
    owned.private_dir(workspace)
    archive = owned.canonical_under(pathlib.Path(args.archive), workspace)
    patch = _private_source_copy(
        _patch_path(),
        workspace / "reviewed-target.patch",
        TARGET_PATCH_SHA256,
    )
    manifest = _private_source_copy(
        _manifest_path(),
        workspace / "reviewed-target-source.json",
        TARGET_MANIFEST_SHA256,
    )
    source = _safe_extract_freerdp(archive, workspace / "source")
    target_package.verify(
        SimpleNamespace(
            manifest=str(manifest),
            patch=str(patch),
            source_root=str(source),
            prepared=False,
            binary=None,
            receipt=None,
        )
    )
    git = pathlib.Path("/usr/bin/git")
    owned.trusted_executable(git)
    applied = owned.bounded_run(
        [str(git), "apply", "--whitespace=error", str(patch)], cwd=source, timeout=30
    )
    if applied.returncode != 0:
        fail("targetPatchApplyFailed")
    target_manifest = target_package.read_manifest(manifest)
    target_package.verify_tree(source, target_manifest["patched"])
    build = workspace / "cmake-build"
    build.mkdir(mode=0o700)
    args_cmake = _cmake_arguments(source, build)
    build_failure = workspace / "freerdp-build-failure.json"
    owned.private_regular(build_failure, absent=True)
    _run_build(
        args_cmake, cwd=workspace, log=workspace / "configure.log", timeout=360,
        phase="configure", failure_receipt=build_failure,
    )
    _run_build(
        [
            "/usr/bin/cmake",
            "--build",
            str(build),
            "--target",
            "freerdp-shadow-cli",
            "xfreerdp",
            "--parallel",
            "2",
        ],
        cwd=workspace,
        log=workspace / "compile.log",
        timeout=600,
        phase="compile",
        failure_receipt=build_failure,
    )
    shadow = build / "server" / "shadow" / "cli" / "freerdp-shadow-cli"
    client = build / "client" / "X11" / "xfreerdp"
    os.chmod(shadow, 0o700)
    os.chmod(client, 0o700)
    target_package.verify_elf(shadow)
    _verify_xfreerdp(client)
    cmake_digest = hashlib.sha256("\0".join(args_cmake[5:]).encode("utf-8")).hexdigest()
    receipt = {
        "schemaVersion": 1,
        "sourceRevision": FREERDP_REVISION,
        "sourceArchiveSha256": FREERDP_ARCHIVE_SHA256,
        "targetPatchSha256": TARGET_PATCH_SHA256,
        "sourceManifestSha256": TARGET_MANIFEST_SHA256,
        "cmakeArgumentsSha256": cmake_digest,
        "shadowBinarySha256": owned.sha256(shadow),
        "xfreerdpBinarySha256": owned.sha256(client),
        "witnessSchemaVersion": 2,
        "deviceName": DEVICE_NAME,
    }
    out = workspace / "freerdp-build-receipt.json"
    _write_private_json(out, receipt)
    print(
        json.dumps(
            {
                "state": "freerdpBuilt",
                "receiptSha256": owned.sha256(out),
                "featureAccepted": False,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )


def _read_json(path: pathlib.Path, *, limit: int, stage: str) -> dict:
    owned.private_regular(path)
    raw = path.read_bytes()
    if not 0 < len(raw) <= limit:
        fail(stage)
    value = json.loads(raw)
    if not isinstance(value, dict):
        fail(stage)
    return value


def _validate_freerdp_receipt(
    path: pathlib.Path, shadow: pathlib.Path, client: pathlib.Path
) -> dict:
    value = _read_json(path, limit=4096, stage="invalidFreerdpBuildReceipt")
    if set(value) != BUILD_RECEIPT_KEYS or value.get("schemaVersion") != 1:
        fail("invalidFreerdpBuildReceipt")
    expected = {
        "sourceRevision": FREERDP_REVISION,
        "sourceArchiveSha256": FREERDP_ARCHIVE_SHA256,
        "targetPatchSha256": TARGET_PATCH_SHA256,
        "sourceManifestSha256": TARGET_MANIFEST_SHA256,
        "witnessSchemaVersion": 2,
        "deviceName": DEVICE_NAME,
        "shadowBinarySha256": owned.sha256(shadow),
        "xfreerdpBinarySha256": owned.sha256(client),
    }
    if any(value.get(key) != wanted for key, wanted in expected.items()):
        fail("invalidFreerdpBuildReceipt")
    if not _HEX64.fullmatch(str(value.get("cmakeArgumentsSha256", ""))):
        fail("invalidFreerdpBuildReceipt")
    target_package.verify_elf(shadow)
    _verify_xfreerdp(client)
    return value


def _openssl_md4(openssl: pathlib.Path, password: str) -> bytes:
    encoded = bytearray(password.encode("utf-16le"))
    try:
        process = subprocess.run(
            [str(openssl), "dgst", "-md4", "-provider", "legacy", "-binary"],
            input=bytes(encoded),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
    finally:
        encoded[:] = b"\0" * len(encoded)
    if process.returncode != 0 or len(process.stdout) != 16:
        fail("samHashUnavailable")
    return process.stdout


def _create_certificate(
    openssl: pathlib.Path, cert: pathlib.Path, key: pathlib.Path, ip: str
) -> None:
    process = owned.bounded_run(
        [
            str(openssl),
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-subj",
            f"/CN={ip}",
            "-addext",
            f"subjectAltName=IP:{ip}",
            "-keyout",
            str(key),
            "-out",
            str(cert),
        ],
        timeout=30,
    )
    if process.returncode != 0:
        fail("certificateCreateFailed")
    os.chmod(cert, 0o600)
    os.chmod(key, 0o600)


def _certificate_fingerprint(openssl: pathlib.Path, cert: pathlib.Path) -> str:
    process = owned.bounded_run(
        [
            str(openssl),
            "x509",
            "-in",
            str(cert),
            "-noout",
            "-fingerprint",
            "-sha256",
        ],
        timeout=10,
    )
    if process.returncode != 0:
        fail("certificateReadFailed")
    line = process.stdout.decode("ascii", "strict").strip()
    prefix = "sha256 Fingerprint="
    if not line.lower().startswith(prefix.lower()):
        fail("certificateReadFailed")
    value = line[len(prefix) :].replace(":", "").lower()
    if not _HEX64.fullmatch(value):
        fail("certificateReadFailed")
    return "sha256:" + value


def _live_der(host: str, port: int, *, rdp_target: bool = False) -> bytes:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, port), timeout=3) as raw:
            if rdp_target:
                owned.negotiate_target_nla(raw)
            with context.wrap_socket(raw, server_hostname=host) as secured:
                value = secured.getpeercert(binary_form=True)
    except (OSError, ssl.SSLError) as error:
        raise ProbeError("tlsUnavailable") from error
    if not isinstance(value, bytes) or not 64 <= len(value) <= 16384:
        fail("certificateReadFailed")
    return value


def _der_spki_pin(openssl: pathlib.Path, der: bytes, directory: pathlib.Path) -> str:
    cert = directory / ("observed-" + secrets.token_hex(4) + ".der")
    owned.private_regular(cert, absent=True)
    try:
        fd = os.open(cert, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb", closefd=True) as stream:
            stream.write(der)
        converted = directory / (cert.stem + ".pem")
        process = owned.bounded_run(
            [
                str(openssl),
                "x509",
                "-inform",
                "DER",
                "-in",
                str(cert),
                "-out",
                str(converted),
            ],
            timeout=10,
        )
        if process.returncode != 0:
            fail("certificateReadFailed")
        os.chmod(converted, 0o600)
        return owned.tls_pin(openssl, converted)
    finally:
        owned.destroy_private_file(cert)
        try:
            owned.destroy_private_file(directory / (cert.stem + ".pem"))
        except BaseException:
            pass


class CloseWriteWatcher:
    def __init__(self, directory: pathlib.Path, expected_name: str):
        if "/" in expected_name or not expected_name:
            fail("invalidMirrorName")
        libc = ctypes.CDLL(None, use_errno=True)
        fd = libc.inotify_init1(_IN_CLOEXEC | _IN_NONBLOCK)
        if fd < 0:
            fail("inotifyUnavailable")
        watch = libc.inotify_add_watch(fd, os.fsencode(directory), _IN_CLOSE_WRITE)
        if watch < 0:
            os.close(fd)
            fail("inotifyUnavailable")
        self.fd = fd
        self.watch = watch
        self.expected_name = expected_name
        self.libc = libc

    def wait(self, deadline: float) -> None:
        import select

        while time.monotonic() < deadline:
            readable, _, _ = select.select(
                [self.fd], [], [], min(0.2, max(0.0, deadline - time.monotonic()))
            )
            if not readable:
                continue
            data = os.read(self.fd, 65536)
            offset = 0
            while offset + 16 <= len(data):
                _, mask, _, length = struct.unpack_from("iIII", data, offset)
                offset += 16
                if offset + length > len(data):
                    fail("invalidInotifyEvent")
                name = (
                    data[offset : offset + length]
                    .split(b"\0", 1)[0]
                    .decode("ascii", "strict")
                )
                offset += length
                if mask & _IN_CLOSE_WRITE and name == self.expected_name:
                    return
        fail("outboundCloseTimeout")

    def close(self) -> None:
        if self.fd >= 0:
            self.libc.inotify_rm_watch(self.fd, self.watch)
            os.close(self.fd)
            self.fd = -1


class ArgsFdClient:
    def __init__(
        self,
        binary: pathlib.Path,
        arguments: list[str],
        *,
        cwd: pathlib.Path,
        env: dict[str, str],
        log: pathlib.Path,
    ):
        if any("\n" in value or "\r" in value or "\0" in value for value in arguments):
            fail("invalidClientArguments")
        payload = bytearray(("\n".join(arguments) + "\n").encode("utf-8"))
        read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
        owned.private_regular(log, absent=True)
        log_fd = os.open(
            log,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
        )
        try:
            os.write(write_fd, payload)
            os.close(write_fd)
            write_fd = -1
            self.proc = subprocess.Popen(
                [str(binary), f"/args-from:fd:{read_fd}"],
                cwd=cwd,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=log_fd,
                stderr=subprocess.STDOUT,
                pass_fds=(read_fd,),
                start_new_session=True,
            )
            self.pid = self.proc.pid
            self.start = pathlib.Path(f"/proc/{self.pid}/stat").read_text().split()[21]
        finally:
            payload[:] = b"\0" * len(payload)
            if write_fd >= 0:
                os.close(write_fd)
            os.close(read_fd)
            os.close(log_fd)

    def exact(self) -> bool:
        try:
            return (
                pathlib.Path(f"/proc/{self.pid}/stat").read_text().split()[21]
                == self.start
            )
        except (FileNotFoundError, IndexError):
            return False

    def stop_after_effect(self) -> None:
        if self.proc.poll() is None:
            if not self.exact():
                fail("processIdentityChanged")
            os.killpg(self.pid, signal.SIGINT)
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired as error:
                raise ProbeError("clientCloseTimeout") from error

    def close(self) -> None:
        if self.proc.poll() is None:
            if not self.exact():
                fail("processIdentityChanged")
            os.killpg(self.pid, signal.SIGTERM)
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                if not self.exact():
                    fail("processIdentityChanged")
                os.killpg(self.pid, signal.SIGKILL)
                self.proc.wait(5)


def _mirror_file(path: pathlib.Path, expected: bytes) -> None:
    info = path.lstat()
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
    ):
        fail("invalidMirrorEffect")
    if info.st_mode & 0o077 or path.read_bytes() != expected:
        fail("invalidMirrorEffect")


def _validate_target_witness(path: pathlib.Path, nonce: str) -> dict:
    return owned.validate_target_witness(path, nonce)


def _write_cleanup_receipt(path: pathlib.Path, value: dict) -> None:
    if (
        set(value) != PUBLIC_RECEIPT_KEYS
        or value.get("featureAccepted") is not False
        or value.get("runtimeAccepted") is not False
        or value.get("androidProductExercised") is not False
    ):
        fail("invalidPublicReceipt")
    if any(
        value.get(key) is not True
        for key in (
            "gatewayAuthObserved",
            "gatewayPinMatched",
            "targetPinMatched",
            "configuredTargetExact",
            "directTargetBlocked",
            "targetConnectedThroughGateway",
            "rdpdrUploadMatched",
            "rdpdrDownloadMatched",
            "targetCleanClose",
            "singleAuthenticatedSession",
            "cleanupComplete",
        )
    ):
        fail("probeIncomplete")
    _write_private_json(path, value)


def run_probe(args: argparse.Namespace) -> None:
    os.umask(0o077)
    owned.require_owned_linux()
    runner_revision = source_revision(_script_root().parent)
    workspace = pathlib.Path(args.workspace)
    owned.private_dir(workspace)
    if (
        not 1 <= args.gateway_port <= 65535
        or not 1 <= args.target_port <= 65535
        or args.gateway_port == args.target_port
        or not 1 <= args.timeout <= 600
    ):
        fail("invalidBounds")
    gateway_receipt = owned.validate_build_receipt(
        owned.canonical_under(pathlib.Path(args.gateway_build_receipt), workspace)
    )
    gateway = owned.canonical_under(pathlib.Path(args.gateway_binary), workspace)
    auth = owned.canonical_under(pathlib.Path(args.auth_binary), workspace)
    shadow = owned.canonical_under(pathlib.Path(args.shadow_binary), workspace)
    client_binary = owned.canonical_under(pathlib.Path(args.xfreerdp_binary), workspace)
    freerdp_receipt = _validate_freerdp_receipt(
        owned.canonical_under(pathlib.Path(args.freerdp_build_receipt), workspace),
        shadow,
        client_binary,
    )
    for binary in (gateway, auth, shadow, client_binary):
        owned.private_regular(binary, executable=True)
    if (
        owned.sha256(gateway) != gateway_receipt["gatewayBinarySha256"]
        or owned.sha256(auth) != gateway_receipt["authBinarySha256"]
    ):
        fail("binaryHashMismatch")
    openssl = pathlib.Path("/usr/bin/openssl")
    xvfb_binary = pathlib.Path("/usr/bin/Xvfb")
    for tool in (
        openssl,
        xvfb_binary,
        pathlib.Path("/usr/sbin/ip"),
        pathlib.Path("/usr/sbin/iptables"),
        pathlib.Path("/usr/bin/setpriv"),
        pathlib.Path("/usr/bin/env"),
        pathlib.Path("/bin/kill"),
    ):
        owned.trusted_executable(tool)
    run_dir = workspace / "run"
    run_dir.mkdir(mode=0o700)
    token = secrets.token_hex(3)
    state = owned.CleanupState.create(token, args.gateway_port, args.target_port)
    journal = run_dir / "cleanup-state.json"
    owned.write_cleanup_state(journal, state)
    nonce = secrets.token_hex(32)
    gateway_user = "gw_" + secrets.token_hex(8)
    gateway_domain = "LARENOR"
    gateway_password = owned.random_secret(32)
    target_user = "target_" + secrets.token_hex(8)
    target_domain = "LARENOR"
    target_password = owned.random_secret(32)
    ns = state["namespace"]
    target_ip = state["targetIp"]
    host_ip = state["hostIp"]
    host_if = state["hostIf"]
    ns_if = state["nsIf"]
    target_port = args.target_port
    mirror = run_dir / "mirror"
    mirror.mkdir(mode=0o700)
    to_remote = mirror / "ToRemote"
    from_remote = mirror / "FromRemote"
    to_remote.mkdir(mode=0o700)
    from_remote.mkdir(mode=0o700)
    upload_name = f"upload-{nonce[:16]}.bin"
    outbound_name = f"outbound-{nonce[:16]}.bin"
    upload_bytes = (UPLOAD_PREFIX + nonce).encode("ascii")
    outbound_bytes = (OUTBOUND_PREFIX + nonce).encode("ascii")
    if len(upload_bytes) != 91 or len(outbound_bytes) != 93:
        fail("payloadContractDrift")
    upload_path = to_remote / upload_name
    fd = os.open(
        upload_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
    )
    with os.fdopen(fd, "wb", closefd=True) as stream:
        stream.write(upload_bytes)
        stream.flush()
        os.fsync(stream.fileno())
    watcher: CloseWriteWatcher | None = None
    target_witness = run_dir / "target-witness.json"
    owned.private_regular(target_witness, absent=True)
    target_home = run_dir / "target-home"
    target_home.mkdir(mode=0o700)
    target_config = target_home / ".config" / "freerdp" / "shadow"
    target_config.mkdir(parents=True, mode=0o700)
    target_cert = target_config / "shadow.crt"
    target_key = target_config / "shadow.key"
    _create_certificate(openssl, target_cert, target_key, target_ip)
    sam = run_dir / "target.sam"
    nt_hash = _openssl_md4(openssl, target_password)
    owned.write_private(sam, f"{target_user}:{target_domain}::{nt_hash.hex()}:::\n")
    auth_socket = run_dir / "auth.sock"
    gateway_cert = run_dir / "gateway.crt"
    gateway_key = run_dir / "gateway.key"
    _create_certificate(openssl, gateway_cert, gateway_key, "127.0.0.1")
    auth_config = run_dir / "auth.yaml"
    gateway_config = run_dir / "gateway.yaml"
    owned.write_private(
        auth_config,
        f"Users:\n  - Username: {gateway_user}\n    Password: {gateway_password}\n",
    )
    session_key = owned.random_secret()
    session_encryption = owned.random_secret()
    paa_sign = owned.random_secret()
    paa_encrypt = owned.random_secret()
    owned.write_private(
        gateway_config,
        f"""Server:
  Authentication:
    - ntlm
  AuthSocket: {auth_socket}
  BasicAuthTimeout: 5
  Tls: enable
  CertFile: {gateway_cert}
  KeyFile: {gateway_key}
  GatewayAddress: 127.0.0.1:{args.gateway_port}
  BindAddress: {target_ip}
  Port: {args.gateway_port}
  Hosts:
    - {target_ip}:{target_port}
  HostSelection: roundrobin
  AllowPrivateDestinations: false
  SessionKey: {session_key}
  SessionEncryptionKey: {session_encryption}
  SessionStore: cookie
Caps:
  TokenAuth: false
  IdleTimeout: 2
  RedirectAll: false
  DisableRedirect: false
  EnableClipboard: false
  EnablePrinter: false
  EnablePort: false
  EnablePnp: false
  EnableDrive: true
Security:
  PAATokenSigningKey: {paa_sign}
  PAATokenEncryptionKey: {paa_encrypt}
""",
    )
    processes: list[owned.OwnedProcess] = []
    client: ArgsFdClient | None = None
    relay: owned.TcpRelay | None = None
    primary: BaseException | None = None
    facts: dict | None = None
    secret_paths = [
        sam,
        target_cert,
        target_key,
        target_witness,
        auth_config,
        gateway_config,
        gateway_cert,
        gateway_key,
    ]
    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}

    def interrupted(_signum, _frame):
        raise ProbeError("interrupted")

    for sig in handlers:
        signal.signal(sig, interrupted)
    try:
        watcher = CloseWriteWatcher(from_remote, outbound_name)
        owned.sudo(["/usr/sbin/ip", "netns", "add", ns])
        owned._journal_setup(state, "ns", journal)
        owned.sudo(
            [
                "/usr/sbin/ip",
                "link",
                "add",
                host_if,
                "type",
                "veth",
                "peer",
                "name",
                ns_if,
            ]
        )
        owned._journal_setup(state, "link", journal)
        owned.sudo(["/usr/sbin/ip", "link", "set", ns_if, "netns", ns])
        owned.sudo(["/usr/sbin/ip", "addr", "add", f"{host_ip}/30", "dev", host_if])
        owned.sudo(["/usr/sbin/ip", "link", "set", host_if, "up"])
        owned.sudo(
            [
                "/usr/sbin/ip",
                "netns",
                "exec",
                ns,
                "/usr/sbin/ip",
                "addr",
                "add",
                f"{target_ip}/30",
                "dev",
                ns_if,
            ]
        )
        owned.sudo(
            [
                "/usr/sbin/ip",
                "netns",
                "exec",
                ns,
                "/usr/sbin/ip",
                "link",
                "set",
                ns_if,
                "up",
            ]
        )
        owned.sudo(
            [
                "/usr/sbin/ip",
                "netns",
                "exec",
                ns,
                "/usr/sbin/ip",
                "link",
                "set",
                "lo",
                "up",
            ]
        )
        display_number = 90 + secrets.randbelow(30)
        display = f":{display_number}"
        display_socket = pathlib.Path(f"/tmp/.X11-unix/X{display_number}")
        if display_socket.exists() or display_socket.is_symlink():
            fail("displayAlreadyOwned")
        xvfb = owned.OwnedProcess(
            [
                str(xvfb_binary),
                display,
                "-screen",
                "0",
                "1024x768x24",
                "-nolisten",
                "tcp",
                "-noreset",
                "-ac",
            ],
            cwd=run_dir,
        )
        processes.append(xvfb)
        owned._journal_process(state, "xvfb", xvfb, journal)
        owned.wait_path(display_socket, time.monotonic() + 10)
        target_environment = [
            f"HOME={target_home}",
            f"XDG_CONFIG_HOME={target_home / '.config'}",
            f"DISPLAY={display}",
            f"LARENOR_F62_TARGET_USERNAME={target_user}",
            f"LARENOR_F62_TARGET_DOMAIN={target_domain}",
            f"LARENOR_F62_TARGET_NONCE={nonce}",
            f"LARENOR_F62_TARGET_WITNESS={target_witness}",
            f"LARENOR_F62_EXPECT_UPLOAD_SHA256={hashlib.sha256(upload_bytes).hexdigest()}",
            f"LARENOR_F62_EXPECT_OUTBOUND_SHA256={hashlib.sha256(outbound_bytes).hexdigest()}",
        ]
        target_command = [
            "/usr/bin/sudo",
            "-n",
            "/usr/sbin/ip",
            "netns",
            "exec",
            ns,
            "/usr/bin/setpriv",
            "--reuid",
            str(os.getuid()),
            "--regid",
            str(os.getgid()),
            "--clear-groups",
            "--",
            "/usr/bin/env",
            *target_environment,
            str(shadow),
            f"/port:{target_port}",
            f"/bind-address:{target_ip}",
            "/sec:nla",
            f"/sam-file:{sam}",
            "/log-level:OFF",
            "/may-view",
            "/may-interact",
        ]
        target_process = owned.OwnedProcess(target_command, cwd=run_dir)
        processes.append(target_process)
        owned._journal_process(state, "target", target_process, journal)
        owned.wait_tcp(target_ip, target_port, time.monotonic() + 15)
        target_der = _live_der(target_ip, target_port, rdp_target=True)
        target_pin = _der_spki_pin(openssl, target_der, run_dir)
        if target_pin != owned.tls_pin(openssl, target_cert):
            fail("targetListenerPinMismatch")
        rule = [
            "/usr/sbin/iptables",
            "-I",
            "OUTPUT",
            "1",
            "-d",
            f"{target_ip}/32",
            "-p",
            "tcp",
            "--dport",
            str(target_port),
            "-m",
            "comment",
            "--comment",
            state["firewallComment"],
            "-j",
            "REJECT",
            "--reject-with",
            "tcp-reset",
        ]
        owned.sudo(rule)
        owned._journal_setup(state, "firewall", journal)
        owned.require_tcp_blocked(target_ip, target_port)
        ns_prefix = [
            "/usr/bin/sudo",
            "-n",
            "/usr/sbin/ip",
            "netns",
            "exec",
            ns,
            "/usr/bin/setpriv",
            "--reuid",
            str(os.getuid()),
            "--regid",
            str(os.getgid()),
            "--clear-groups",
            "--",
        ]
        auth_process = owned.OwnedProcess(
            [*ns_prefix, str(auth), "-c", str(auth_config), "-s", str(auth_socket)],
            cwd=run_dir,
            capture=True,
        )
        processes.append(auth_process)
        owned._journal_process(state, "auth", auth_process, journal)
        owned.wait_path(auth_socket, time.monotonic() + 10)
        gateway_process = owned.OwnedProcess(
            [*ns_prefix, str(gateway), "-c", str(gateway_config)],
            cwd=run_dir,
            capture=True,
        )
        processes.append(gateway_process)
        owned._journal_process(state, "gateway", gateway_process, journal)
        relay = owned.TcpRelay(args.gateway_port, target_ip, args.gateway_port)
        owned.wait_tls(args.gateway_port, time.monotonic() + 15)
        gateway_der = _live_der("127.0.0.1", args.gateway_port)
        gateway_pin = _der_spki_pin(openssl, gateway_der, run_dir)
        if gateway_pin != owned.tls_pin(openssl, gateway_cert):
            fail("gatewayListenerPinMismatch")
        gateway_fp = _certificate_fingerprint(openssl, gateway_cert)
        target_fp = _certificate_fingerprint(openssl, target_cert)
        client_log = run_dir / "xfreerdp.log"
        client_args = [
            f"/v:{target_ip}:{target_port}",
            f"/u:{target_user}",
            f"/d:{target_domain}",
            f"/p:{target_password}",
            f"/gateway:g:127.0.0.1:{args.gateway_port},u:{gateway_user},d:{gateway_domain},p:{gateway_password},usage-method:direct,type:http,no-websockets",
            f"/drive:{DEVICE_NAME},{mirror}",
            f"/cert:fingerprint:{gateway_fp},fingerprint:{target_fp}",
            "/sec:nla",
            "/gfx:off",
            "/network:auto",
            "/w:800",
            "/h:600",
            "/log-level:OFF",
        ]
        client_env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(run_dir / "client-home"),
            "DISPLAY": display,
            "LANG": "C",
            "LC_ALL": "C",
        }
        pathlib.Path(client_env["HOME"]).mkdir(mode=0o700)
        client = ArgsFdClient(
            client_binary, client_args, cwd=run_dir, env=client_env, log=client_log
        )
        owned._journal_process(state, "client", client, journal)
        assert watcher is not None
        watcher.wait(time.monotonic() + args.timeout)
        outbound_path = from_remote / outbound_name
        _mirror_file(outbound_path, outbound_bytes)
        _mirror_file(upload_path, upload_bytes)
        client.stop_after_effect()
        owned.wait_path(target_witness, time.monotonic() + 10)
        target_facts = _validate_target_witness(target_witness, nonce)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and (
            not owned.auth_observed(auth_process.bounded_output(), gateway_user)
            or not owned.target_connect_observed(
                gateway_process.bounded_output(), target_ip, target_port
            )
        ):
            time.sleep(0.05)
        facts = {
            "gatewayAuthObserved": owned.auth_observed(
                auth_process.bounded_output(), gateway_user
            ),
            "gatewayPinMatched": gateway_pin == owned.tls_pin(openssl, gateway_cert),
            "targetPinMatched": target_pin == owned.tls_pin(openssl, target_cert),
            "configuredTargetExact": owned.target_connect_observed(
                gateway_process.bounded_output(), target_ip, target_port
            ),
            "directTargetBlocked": True,
            "targetConnectedThroughGateway": target_facts["nlaAuthenticated"]
            and owned.target_connect_observed(
                gateway_process.bounded_output(), target_ip, target_port
            ),
            "rdpdrUploadMatched": target_facts["uploadSha256"]
            == hashlib.sha256(upload_bytes).hexdigest(),
            "rdpdrDownloadMatched": target_facts["outboundSha256"]
            == hashlib.sha256(outbound_bytes).hexdigest(),
            "targetCleanClose": target_facts["outboundClosed"]
            and target_facts["cleanClose"],
            "singleAuthenticatedSession": target_facts["authenticatedSessions"] == 1,
        }
        if not all(facts.values()):
            fail("probeIncomplete")
    except BaseException as error:
        primary = error
    finally:
        cleanup_ok = True
        if watcher is not None:
            watcher.close()
        if client is not None:
            try:
                client.close()
            except BaseException:
                cleanup_ok = False
        if relay is not None:
            try:
                relay.close()
            except BaseException:
                cleanup_ok = False
        for process in reversed(processes):
            try:
                process.close()
            except BaseException:
                cleanup_ok = False
        if "firewall" in state["setup"]:
            try:
                owned.sudo(
                    [
                        "/usr/sbin/iptables",
                        "-D",
                        "OUTPUT",
                        "-d",
                        f"{target_ip}/32",
                        "-p",
                        "tcp",
                        "--dport",
                        str(target_port),
                        "-m",
                        "comment",
                        "--comment",
                        state["firewallComment"],
                        "-j",
                        "REJECT",
                        "--reject-with",
                        "tcp-reset",
                    ]
                )
            except BaseException:
                cleanup_ok = False
        if "link" in state["setup"]:
            try:
                owned.sudo(["/usr/sbin/ip", "link", "del", host_if])
            except BaseException:
                cleanup_ok = False
        if "ns" in state["setup"]:
            try:
                pids = (
                    owned.sudo(["/usr/sbin/ip", "netns", "pids", ns])
                    .stdout.decode("ascii", "strict")
                    .split()
                )
                for pid in pids:
                    if not pid.isdigit():
                        fail("cleanupIdentityChanged")
                    owned.sudo(["/bin/kill", "-KILL", pid])
                owned.sudo(["/usr/sbin/ip", "netns", "del", ns])
            except BaseException:
                cleanup_ok = False
        for path in [*secret_paths, run_dir / "xfreerdp.log"]:
            try:
                owned.destroy_private_file(path)
            except BaseException:
                cleanup_ok = False
        try:
            owned.remove_owned_endpoint(auth_socket)
        except BaseException:
            cleanup_ok = False
        if cleanup_ok:
            try:
                owned.destroy_private_file(journal)
            except BaseException:
                cleanup_ok = False
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
    if primary is not None:
        raise primary
    if not cleanup_ok or facts is None:
        fail("cleanupFailed" if not cleanup_ok else "probeIncomplete")
    public = {
        "runnerSourceRevision": runner_revision,
        "schemaVersion": 1,
        "scope": "ownedLinuxRdGatewayRdpdrProbe",
        "sourceRevision": FREERDP_REVISION,
        "sourceArchiveSha256": FREERDP_ARCHIVE_SHA256,
        "targetPatchSha256": TARGET_PATCH_SHA256,
        "sourceManifestSha256": TARGET_MANIFEST_SHA256,
        "rdpgwRevision": owned.REVISION,
        "rdpgwArchiveSha256": owned.ARCHIVE_SHA,
        "shadowBinarySha256": freerdp_receipt["shadowBinarySha256"],
        "xfreerdpBinarySha256": freerdp_receipt["xfreerdpBinarySha256"],
        "gatewayBinarySha256": gateway_receipt["gatewayBinarySha256"],
        "authBinarySha256": gateway_receipt["authBinarySha256"],
        **facts,
        "cleanupComplete": True,
        "androidProductExercised": False,
        "runtimeAccepted": False,
        "featureAccepted": False,
    }
    out = pathlib.Path(args.public_receipt)
    parent = out.parent.resolve(strict=True)
    base = workspace.resolve(strict=True)
    if parent != base and base not in parent.parents:
        fail("pathOutsideWorkspace")
    _write_cleanup_receipt(out, public)
    print(
        json.dumps(
            {
                "state": "linuxProbeObserved",
                "receiptSha256": owned.sha256(out),
                "runtimeAccepted": False,
                "featureAccepted": False,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )


def self_test() -> None:
    import unittest

    class Tests(unittest.TestCase):
        def test_payload_contract(self):
            nonce = "a" * 64
            self.assertEqual(len((UPLOAD_PREFIX + nonce).encode("ascii")), 91)
            self.assertEqual(len((OUTBOUND_PREFIX + nonce).encode("ascii")), 93)
            self.assertEqual(DEVICE_NAME, "LrnXfer")

        def test_mirror_contract_uses_native5_directories(self):
            source = pathlib.Path(__file__).read_text()
            self.assertIn('to_remote = mirror / "ToRemote"', source)
            self.assertIn('from_remote = mirror / "FromRemote"', source)
            self.assertIn("upload_path = to_remote / upload_name", source)
            self.assertIn("outbound_path = from_remote / outbound_name", source)

        def test_receipt_is_explicitly_non_acceptance(self):
            self.assertIn("runtimeAccepted", PUBLIC_RECEIPT_KEYS)
            self.assertIn("androidProductExercised", PUBLIC_RECEIPT_KEYS)
            self.assertNotIn("nonce", PUBLIC_RECEIPT_KEYS)
            self.assertNotIn("gatewayPassword", PUBLIC_RECEIPT_KEYS)
            self.assertNotIn("targetHost", PUBLIC_RECEIPT_KEYS)

        def test_xfreerdp_uses_anonymous_argument_fd(self):
            source = pathlib.Path(__file__).read_text()
            self.assertIn('f"/args-from:fd:{read_fd}"', source)
            self.assertIn("pass_fds=(read_fd,)", source)
            run_body = source[
                source.index("def run_probe(") : source.index("\ndef self_test()")
            ]
            self.assertNotIn("/cert:" + "ignore", run_body)
            self.assertIn("usage-method:direct,type:http,no-websockets", source)

        def test_target_effects_are_host_observed(self):
            source = pathlib.Path(__file__).read_text()
            self.assertIn("CloseWriteWatcher", source)
            self.assertIn("owned.validate_target_witness", source)
            self.assertIn("client.stop_after_effect()", source)
            self.assertLess(
                source.index("watcher.wait("),
                source.index("client.stop_after_effect()"),
            )

        def test_publication_follows_cleanup(self):
            source = pathlib.Path(__file__).read_text()
            body = source[
                source.index("def run_probe(") : source.index("\ndef self_test()")
            ]
            self.assertLess(
                body.index("finally:"),
                body.index("_write_cleanup_receipt(out, public)"),
            )
            self.assertIn('"cleanupComplete": True', body)

    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(Tests)
    )
    if not result.wasSuccessful():
        raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build-freerdp")
    build.add_argument("--workspace", required=True)
    build.add_argument("--archive", required=True)
    run = commands.add_parser("run")
    run.add_argument("--workspace", required=True)
    run.add_argument("--gateway-build-receipt", required=True)
    run.add_argument("--gateway-binary", required=True)
    run.add_argument("--auth-binary", required=True)
    run.add_argument("--freerdp-build-receipt", required=True)
    run.add_argument("--shadow-binary", required=True)
    run.add_argument("--xfreerdp-binary", required=True)
    run.add_argument("--gateway-port", required=True, type=int)
    run.add_argument("--target-port", default=3390, type=int)
    run.add_argument("--timeout", default=180, type=int)
    run.add_argument("--public-receipt", required=True)
    commands.add_parser("self-test")
    args = parser.parse_args()
    try:
        if args.command == "build-freerdp":
            build_freerdp(args)
        elif args.command == "run":
            run_probe(args)
        else:
            self_test()
    except (
        ProbeError,
        owned.FixtureError,
        target_package.PackageError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        UnicodeError,
    ) as error:
        if (
            isinstance(
                error, (ProbeError, owned.FixtureError, target_package.PackageError)
            )
            and error.args
        ):
            stage = str(error.args[0])
        else:
            stage = "probeFailure"
        print(
            json.dumps(
                {
                    "state": "failed",
                    "stage": stage,
                    "runtimeAccepted": False,
                    "featureAccepted": False,
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        raise SystemExit(2)


if __name__ == "__main__":
    main()
