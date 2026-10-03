#!/usr/bin/env python3
from __future__ import annotations
import argparse
import base64
import hashlib
import ipaddress
import json
import os
import pathlib
import platform
import re
import secrets
import select
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

REVISION = "16cdaaf4dce6a6567ce9b612f14e71d0ca704148"
ARCHIVE_SHA = "b96e24cddfdf4b6eee939dc1558734f29534c7e0ebae650858c8ba715a166907"
GO_VERSION = "go1.25.0"
TARGET_REVISION = "63b948ca5cb94307fd5444ee6e73927a41ccdab4"
TARGET_ARCHIVE_SHA = "4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991"
TARGET_PATCH_SHA = "52b61d9ecfef7c8d047ee558177ab2b0b664294729a2035c5045041a183eafb4"
TARGET_SOURCE_MANIFEST_SHA = "5a5ed427179aaad89b111c6b9bae9bc594b8c78abf7efb5e10c24ee09dfbf1f0"
CLIENT_WITNESS_KEYS = {
    "schemaVersion",
    "nonce",
    "testClass",
    "testName",
    "tests",
    "failures",
    "errors",
    "skipped",
    "directTargetBlocked",
    "gatewayPinMatched",
    "targetPinMatched",
    "frameAcknowledged",
    "nativeDrainConfirmed",
    "safReadbackSha256",
    "ownersRetired",
}
TARGET_WITNESS_KEYS = {
    "schemaVersion",
    "nonce",
    "authenticatedSessions",
    "nlaAuthenticated",
    "uploadSha256",
    "outboundSha256",
    "outboundClosed",
    "cleanClose",
}
ACCEPTANCE_FACT_KEYS = frozenset(
    {
        "gatewayPinMatched",
        "targetPinMatched",
        "gatewayAuthObserved",
        "configuredTargetExact",
        "directTargetBlocked",
        "targetConnectedThroughGateway",
        "frameAcknowledged",
        "safUploadMatched",
        "safDownloadCommitted",
        "sessionDrained",
        "ownersRetired",
    }
)
RECEIPT_KEYS = {
    "schemaVersion",
    "sourceRevision",
    "archiveSha256",
    "goVersion",
    "goSumSha256",
    "gatewayBinarySha256",
    "authBinarySha256",
    "testClass",
    "testName",
    "tests",
    "failures",
    "errors",
    "skipped",
    *ACCEPTANCE_FACT_KEYS,
    "featureAccepted",
    "scope",
}
_HEX64 = re.compile(r"[0-9a-f]{64}")
_TOKEN = re.compile(r"[0-9a-f]{6}")


class FixtureError(RuntimeError):
    pass


def fail(stage: str) -> None:
    raise FixtureError(stage)


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def expected_upload_sha256(nonce: str) -> str:
    if not _HEX64.fullmatch(nonce):
        fail("invalidNonce")
    return hashlib.sha256(
        ("Larenor-F62-Gateway-upload:" + nonce).encode("ascii")
    ).hexdigest()


def expected_outbound_sha256(nonce: str) -> str:
    if not _HEX64.fullmatch(nonce):
        fail("invalidNonce")
    return hashlib.sha256(
        ("Larenor-F62-Gateway-outbound:" + nonce).encode("ascii")
    ).hexdigest()


def _read_private_json(path: pathlib.Path, limit: int, stage: str) -> dict:
    private_regular(path)
    raw = path.read_bytes()
    if not 0 < len(raw) <= limit:
        fail(stage)
    value = json.loads(raw)
    if not isinstance(value, dict):
        fail(stage)
    return value


def validate_client_witness(
    path: pathlib.Path, nonce: str, test_class: str, test_name: str
) -> dict:
    value = _read_private_json(path, 2048, "invalidClientWitness")
    if (
        set(value) != CLIENT_WITNESS_KEYS
        or value.get("schemaVersion") != 2
        or value.get("nonce") != nonce
        or value.get("testClass") != test_class
        or value.get("testName") != test_name
    ):
        fail("invalidClientWitness")
    if (
        value.get("tests"),
        value.get("failures"),
        value.get("errors"),
        value.get("skipped"),
    ) != (1, 0, 0, 0):
        fail("invalidClientWitness")
    for key in (
        "directTargetBlocked",
        "gatewayPinMatched",
        "targetPinMatched",
        "frameAcknowledged",
        "nativeDrainConfirmed",
        "ownersRetired",
    ):
        if value.get(key) is not True:
            fail("invalidClientWitness")
    if value.get("safReadbackSha256") != expected_outbound_sha256(nonce):
        fail("invalidClientWitness")
    return value


def validate_target_witness(path: pathlib.Path, nonce: str) -> dict:
    value = _read_private_json(path, 1024, "invalidTargetWitness")
    if (
        set(value) != TARGET_WITNESS_KEYS
        or value.get("schemaVersion") != 2
        or value.get("nonce") != nonce
    ):
        fail("invalidTargetWitness")
    if (
        value.get("authenticatedSessions") != 1
        or value.get("nlaAuthenticated") is not True
        or value.get("outboundClosed") is not True
        or value.get("cleanClose") is not True
    ):
        fail("invalidTargetWitness")
    if value.get("uploadSha256") != expected_upload_sha256(nonce) or value.get(
        "outboundSha256"
    ) != expected_outbound_sha256(nonce):
        fail("invalidTargetWitness")
    return value


def auth_observed(log: bytes, username: str) -> bool:
    if len(log) > 262144 or not re.fullmatch(r"gw_[0-9a-f]{16}", username):
        return False
    # Exact wording is source-bound to cmd/auth/auth.go at the pinned revision.
    needle = re.compile(
        rb"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} \[[^\]\r\n]{1,96}\] User: "
        + re.escape(username.encode("ascii"))
        + rb" authenticated using NTLM$",
        re.MULTILINE,
    )
    return needle.search(log) is not None


def target_connect_observed(log: bytes, host: str, port: int) -> bool:
    if len(log) > 262144:
        return False
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return False
    endpoint = f"{host}:{port}".encode("ascii")
    patterns = (
        b"Verifying " + endpoint + b" host connection",
        b"Establishing connection to RDP server: " + endpoint,
        b"Connection established",
    )
    cursor = 0
    for pattern in patterns:
        found = log.find(pattern, cursor)
        if found < 0:
            return False
        cursor = found + len(pattern)
    return True


def acceptance_complete(facts: dict) -> bool:
    return set(facts) == set(ACCEPTANCE_FACT_KEYS) and all(
        facts.get(key) is True for key in ACCEPTANCE_FACT_KEYS
    )


class CleanupState:
    @staticmethod
    def create(token: str, gateway_port: int, target_port: int) -> dict:
        if (
            not _TOKEN.fullmatch(token)
            or not 1 <= gateway_port <= 65535
            or not 1 <= target_port <= 65535
            or gateway_port == target_port
        ):
            fail("invalidCleanupState")
        index = int(token, 16) % 32768
        network = ipaddress.ip_network(
            (int(ipaddress.ip_address("198.18.0.0")) + index * 4, 30)
        )
        return {
            "schemaVersion": 2,
            "token": token,
            "namespace": "lrnrg" + token,
            "hostIf": "lrg" + token,
            "nsIf": "lrn" + token,
            "hostIp": str(network[1]),
            "targetIp": str(network[2]),
            "gatewayPort": gateway_port,
            "targetPort": target_port,
            "firewallComment": "larenor-rdgw-" + token,
            "setup": [],
            "processes": [],
        }


def _validate_cleanup_state(value: dict) -> dict:
    keys = {
        "schemaVersion",
        "token",
        "namespace",
        "hostIf",
        "nsIf",
        "hostIp",
        "targetIp",
        "gatewayPort",
        "targetPort",
        "firewallComment",
        "setup",
        "processes",
    }
    if set(value) != keys or value.get("schemaVersion") != 2:
        fail("invalidCleanupState")
    expected = CleanupState.create(
        value.get("token", ""), value.get("gatewayPort", 0), value.get("targetPort", 0)
    )
    for key in keys - {"setup", "processes"}:
        if value.get(key) != expected[key]:
            fail("invalidCleanupState")
    if (
        not isinstance(value["setup"], list)
        or any(item not in ("ns", "link", "firewall") for item in value["setup"])
        or len(set(value["setup"])) != len(value["setup"])
    ):
        fail("invalidCleanupState")
    if not isinstance(value["processes"], list) or len(value["processes"]) > 8:
        fail("invalidCleanupState")
    for process in value["processes"]:
        if (
            not isinstance(process, dict)
            or set(process) != {"kind", "pid", "start"}
            or process["kind"] not in ("xvfb", "target", "auth", "gateway", "client")
            or not isinstance(process["pid"], int)
            or process["pid"] <= 1
            or not isinstance(process["start"], str)
            or not process["start"].isdigit()
        ):
            fail("invalidCleanupState")
    return value


def write_cleanup_state(path: pathlib.Path, state: dict) -> None:
    value = _validate_cleanup_state(dict(state))
    private_dir(path.parent)
    raw = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "ascii"
    )
    if len(raw) > 8192:
        fail("invalidCleanupState")
    tmp = path.with_name(path.name + ".tmp-" + secrets.token_hex(4))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=True) as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def read_cleanup_state(path: pathlib.Path) -> dict:
    return _validate_cleanup_state(
        _read_private_json(path, 8192, "invalidCleanupState")
    )


def private_regular(path: pathlib.Path, *, executable=False, absent=False) -> None:
    if absent:
        if path.exists() or path.is_symlink():
            fail("pathAlreadyExists")
        return
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail("unsafePath")
    if info.st_uid != os.getuid():
        fail("wrongOwner")
    if info.st_mode & 0o077:
        fail("unsafeMode")
    if executable and not info.st_mode & stat.S_IXUSR:
        fail("notExecutable")


def trusted_executable(path: pathlib.Path) -> None:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail("unsafeExecutable")
    if (
        info.st_uid not in (0, os.getuid())
        or info.st_mode & 0o022
        or not info.st_mode & stat.S_IXUSR
    ):
        fail("unsafeExecutable")


def private_dir(path: pathlib.Path) -> None:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        fail("unsafeDirectory")
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        fail("unsafeDirectoryMode")


def canonical_under(path: pathlib.Path, parent: pathlib.Path) -> pathlib.Path:
    p = path.resolve(strict=True)
    q = parent.resolve(strict=True)
    if p == q or q not in p.parents:
        fail("pathOutsideWorkspace")
    return p


def require_owned_linux() -> None:
    if platform.system() != "Linux":
        fail("unsupportedHost")
    expected = {
        "GITHUB_ACTIONS": "true",
        "RUNNER_OS": "Linux",
        "RUNNER_ENVIRONMENT": "github-hosted",
        "LARENOR_F62_OWNED_RDGW": "required",
    }
    if any(os.environ.get(k) != v for k, v in expected.items()):
        fail("unownedRunner")
    if os.geteuid() == 0:
        fail("rootRunnerRejected")


def bounded_run(
    argv: list[str],
    *,
    cwd: pathlib.Path | None = None,
    env: dict[str, str] | None = None,
    timeout=1200,
) -> subprocess.CompletedProcess:
    if not argv or not pathlib.Path(argv[0]).is_absolute():
        fail("nonAbsoluteCommand")
    process = subprocess.Popen(
        argv,
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    output = [bytearray(), bytearray()]

    def drain(index, pipe):
        for block in iter(lambda: pipe.read(8192), b""):
            room = 65536 - len(output[index])
            if room > 0:
                output[index].extend(block[:room])

    readers = [
        threading.Thread(target=drain, args=(0, process.stdout)),
        threading.Thread(target=drain, args=(1, process.stderr)),
    ]
    for reader in readers:
        reader.start()
    try:
        process.wait(timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        for reader in readers:
            reader.join()
        fail("commandTimeout")
    for reader in readers:
        reader.join()
    return subprocess.CompletedProcess(
        argv, process.returncode, bytes(output[0]), bytes(output[1])
    )


def safe_extract(archive: pathlib.Path, dest: pathlib.Path) -> pathlib.Path:
    private_regular(archive)
    if sha256(archive) != ARCHIVE_SHA:
        fail("archiveHashMismatch")
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        root = f"rdpgw-{REVISION}"
        prefix = root + "/"
        for m in members:
            exact_root = m.name == root
            if (
                not (exact_root or m.name.startswith(prefix))
                or m.name.startswith("/")
                or ".." in pathlib.PurePosixPath(m.name).parts
                or m.issym()
                or m.islnk()
                or not (m.isfile() or m.isdir())
                or (exact_root and not m.isdir())
            ):
                fail("unsafeArchive")
        tf.extractall(dest, filter="data")
    source = dest / root
    for item in source.rglob("*"):
        os.chmod(item, 0o700 if item.is_dir() else 0o600)
    os.chmod(source, 0o700)
    private_dir(source)
    return source


def exact_go(go: pathlib.Path) -> str:
    trusted_executable(go)
    cp = bounded_run([str(go), "version"], timeout=10)
    text = cp.stdout.decode("ascii", "strict").strip()
    if cp.returncode or text != f"go version {GO_VERSION} linux/amd64":
        fail("goVersionMismatch")
    return GO_VERSION


def build(args) -> None:
    require_owned_linux()
    workspace = pathlib.Path(args.workspace)
    private_dir(workspace)
    archive = canonical_under(pathlib.Path(args.archive), workspace)
    out = workspace / "build"
    out.mkdir(mode=0o700)
    private_dir(out)
    source = safe_extract(archive, out / "source")
    go = pathlib.Path(args.go).resolve(strict=True)
    version = exact_go(go)
    pam = pathlib.Path("/usr/include/security/pam_appl.h")
    if not pam.is_file() or pam.is_symlink():
        fail("pamHeadersUnavailable")
    env = dict(os.environ)
    env.update(
        {
            "PATH": str(go.parent) + ":/usr/bin:/bin",
            "GOTOOLCHAIN": "local",
            "CGO_ENABLED": "1",
            "GOOS": "linux",
            "GOARCH": "amd64",
            "GOPATH": str(out / "gopath"),
            "GOMODCACHE": str(out / "gomodcache"),
            "GOCACHE": str(out / "gocache"),
            "GOSUMDB": "sum.golang.org",
            "GOPROXY": "https://proxy.golang.org,direct",
        }
    )
    for name in ("gopath", "gomodcache", "gocache", "bin"):
        (out / name).mkdir(mode=0o700)
    cp = bounded_run(
        [str(go), "mod", "download", "all"], cwd=source, env=env, timeout=1200
    )
    if cp.returncode:
        fail("goModuleDownloadFailed")
    gosum = source / "go.sum"
    if not gosum.is_file() or gosum.is_symlink() or gosum.stat().st_size > 512 * 1024:
        fail("goSumUnavailable")
    env["GOFLAGS"] = "-mod=readonly -trimpath -buildvcs=false"
    binaries = {}
    for name, pkg in (("rdpgw", "./cmd/rdpgw"), ("rdpgw-auth", "./cmd/auth")):
        target = out / "bin" / name
        cp = bounded_run(
            [str(go), "build", "-o", str(target), pkg],
            cwd=source,
            env=env,
            timeout=1800,
        )
        if cp.returncode:
            fail("gatewayBuildFailed" if name == "rdpgw" else "authBuildFailed")
        os.chmod(target, 0o700)
        private_regular(target, executable=True)
        binaries[name] = sha256(target)
    receipt = {
        "schemaVersion": 1,
        "sourceRevision": REVISION,
        "archiveSha256": ARCHIVE_SHA,
        "goVersion": version,
        "goSumSha256": sha256(gosum),
        "gatewayBinarySha256": binaries["rdpgw"],
        "authBinarySha256": binaries["rdpgw-auth"],
    }
    receipt_path = workspace / "build-receipt.json"
    private_regular(receipt_path, absent=True)
    receipt_path.write_text(
        json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
    )
    os.chmod(receipt_path, 0o600)
    print(
        json.dumps(
            {"state": "built", "receiptSha256": sha256(receipt_path)},
            sort_keys=True,
            separators=(",", ":"),
        )
    )


class OwnedProcess:
    def __init__(self, argv: list[str], *, cwd: pathlib.Path, env=None, capture=False):
        self._capture = capture
        self._output = bytearray()
        self._truncated = False
        self._lock = threading.Lock()
        self._reader = None
        stream = subprocess.PIPE if capture else subprocess.DEVNULL
        self.proc = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=stream,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        self.pid = self.proc.pid
        self.start = self._start()
        if capture:
            self._reader = threading.Thread(
                target=self._drain, name="owned-process-log", daemon=False
            )
            self._reader.start()

    def _start(self):
        fields = pathlib.Path(f"/proc/{self.pid}/stat").read_text().split()
        return fields[21]

    def exact(self):
        try:
            return (
                pathlib.Path(f"/proc/{self.pid}/stat").read_text().split()[21]
                == self.start
            )
        except (FileNotFoundError, IndexError):
            return False

    def _drain(self):
        assert self.proc.stdout is not None
        for block in iter(lambda: self.proc.stdout.read(8192), b""):
            with self._lock:
                room = 262144 - len(self._output)
                if room > 0:
                    self._output.extend(block[:room])
                if len(block) > room:
                    self._truncated = True

    def bounded_output(self) -> bytes:
        with self._lock:
            if self._truncated:
                fail("serviceLogTruncated")
            return bytes(self._output)

    def close(self):
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
        if self._reader is not None:
            self._reader.join(5)
            if self._reader.is_alive():
                fail("processLogCleanupFailed")


class TcpRelay:
    def __init__(self, listen_port: int, target_host: str, target_port: int):
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.sockets: set[socket.socket] = set()
        self.workers: list[threading.Thread] = []
        self.target = (target_host, target_port)
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", listen_port))
        self.listener.listen(16)
        self.listener.settimeout(0.2)
        self.listen_port = self.listener.getsockname()[1]
        self.thread = threading.Thread(
            target=self._accept, name="owned-rdpgw-relay", daemon=False
        )
        self.thread.start()

    def _accept(self):
        while not self.stop.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with self.lock:
                if len(self.workers) >= 16:
                    client.close()
                    continue
            try:
                upstream = socket.create_connection(self.target, timeout=2)
                upstream.settimeout(None)
            except OSError:
                client.close()
                continue
            worker = threading.Thread(
                target=self._bridge,
                args=(client, upstream),
                name="owned-rdpgw-bridge",
                daemon=False,
            )
            with self.lock:
                self.sockets.update((client, upstream))
                self.workers.append(worker)
            worker.start()

    def _bridge(self, left: socket.socket, right: socket.socket):
        try:
            while not self.stop.is_set():
                try:
                    readable, _, _ = select.select((left, right), (), (), 0.2)
                except (OSError, ValueError):
                    break
                for source in readable:
                    try:
                        data = source.recv(65536)
                    except OSError:
                        return
                    if not data:
                        return
                    destination = right if source is left else left
                    try:
                        destination.sendall(data)
                    except OSError:
                        return
        finally:
            with self.lock:
                for endpoint in (left, right):
                    self.sockets.discard(endpoint)
            for endpoint in (left, right):
                try:
                    endpoint.close()
                except OSError:
                    pass

    def close(self):
        self.stop.set()
        try:
            self.listener.close()
        except OSError:
            pass
        with self.lock:
            active = list(self.sockets)
        for endpoint in active:
            try:
                endpoint.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                endpoint.close()
            except OSError:
                pass
        self.thread.join(5)
        with self.lock:
            workers = list(self.workers)
        for worker in workers:
            worker.join(5)
        if self.thread.is_alive() or any(worker.is_alive() for worker in workers):
            fail("relayCleanupFailed")


def sudo(argv: list[str], timeout=30):
    exe = pathlib.Path("/usr/bin/sudo")
    trusted_executable(exe)
    cp = bounded_run([str(exe), "-n", *argv], timeout=timeout)
    if cp.returncode:
        fail("privilegedSetupFailed")
    return cp


def sudo_status(argv: list[str], timeout=30):
    exe = pathlib.Path("/usr/bin/sudo")
    trusted_executable(exe)
    return bounded_run([str(exe), "-n", *argv], timeout=timeout)


def random_secret(n=32):
    alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    return "".join(secrets.choice(alphabet) for _ in range(n))


def write_private(path: pathlib.Path, text: str):
    private_regular(path, absent=True)
    path.write_text(text)
    os.chmod(path, 0o600)


def read_command(path: pathlib.Path) -> list[str]:
    private_regular(path)
    raw = path.read_bytes()
    if len(raw) > 32768:
        fail("commandTooLarge")
    value = json.loads(raw)
    if (
        not isinstance(value, dict)
        or set(value) != {"argv"}
        or not isinstance(value["argv"], list)
        or not 1 <= len(value["argv"]) <= 64
    ):
        fail("invalidCommand")
    argv = value["argv"]
    if any(
        not isinstance(x, str) or not x or len(x) > 4096 or "\x00" in x for x in argv
    ):
        fail("invalidCommand")
    exe = pathlib.Path(argv[0])
    trusted_executable(exe)
    return argv


def tls_pin(openssl: pathlib.Path, cert: pathlib.Path) -> str:
    a = bounded_run(
        [str(openssl), "x509", "-in", str(cert), "-pubkey", "-noout"], timeout=10
    )
    if a.returncode:
        fail("certificateReadFailed")
    b = subprocess.run(
        [str(openssl), "pkey", "-pubin", "-outform", "DER"],
        input=a.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )
    if b.returncode:
        fail("certificateReadFailed")
    return base64.b64encode(hashlib.sha256(b.stdout).digest()).decode("ascii")


def negotiate_target_nla(connection: socket.socket) -> None:
    """Bounded MS-RDPBCGR X.224 negotiation before the target TLS handshake."""
    deadline = time.monotonic() + 3

    def exact(length: int) -> bytes:
        data = bytearray()
        while len(data) < length:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail("targetNegotiationTimeout")
            connection.settimeout(remaining)
            block = connection.recv(length - len(data))
            if not block:
                fail("targetNegotiationIncomplete")
            data.extend(block)
        return bytes(data)

    # TPKT + X.224 connection request + SSL|HYBRID RDP_NEG_REQ. No credentials.
    connection.sendall(bytes.fromhex("030000130ee000000000000100080003000000"))
    header = exact(4)
    if header != bytes.fromhex("03000013"):
        fail("targetNegotiationInvalid")
    body = exact(15)
    if body[0:2] != bytes.fromhex("0ed0") or body[6] != 0:
        fail("targetNegotiationInvalid")
    # TYPE_RDP_NEG_RSP, length8, CredSSP only. TLS/RDP fallback is rejected.
    if (
        body[7] != 2
        or body[9:11] != bytes.fromhex("0800")
        or body[11:15] != bytes.fromhex("02000000")
    ):
        fail("targetNlaNegotiationRejected")
    connection.settimeout(3)


def live_tls_pin(
    openssl: pathlib.Path, host: str, port: int, workspace: pathlib.Path
) -> str:
    import ssl

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, port), timeout=3) as raw:
            negotiate_target_nla(raw)
            with context.wrap_socket(raw, server_hostname=host) as secured:
                der = secured.getpeercert(binary_form=True)
    except (OSError, ssl.SSLError):
        fail("targetTlsUnavailable")
    if not isinstance(der, bytes) or not 64 <= len(der) <= 16384:
        fail("targetCertificateInvalid")
    path = workspace / ("live-target-" + secrets.token_hex(4) + ".pem")
    private_regular(path, absent=True)
    try:
        path.write_text(ssl.DER_cert_to_PEM_cert(der), encoding="ascii")
        os.chmod(path, 0o600)
        return tls_pin(openssl, path)
    finally:
        destroy_private_file(path)


def wait_path(path: pathlib.Path, deadline: float):
    while time.monotonic() < deadline:
        if path.exists() and not path.is_symlink():
            return
        time.sleep(0.05)
    fail("serviceNotReady")


def wait_tls(port: int, deadline: float):
    import ssl

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5) as raw:
                with context.wrap_socket(raw, server_hostname="10.0.2.2"):
                    return
        except OSError:
            time.sleep(0.05)
    fail("gatewayNotReady")


def wait_tcp(host: str, port: int, deadline: float):
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.05)
    fail("targetNotReady")


def require_tcp_blocked(host: str, port: int) -> None:
    try:
        connection = socket.create_connection((host, port), timeout=0.5)
    except OSError:
        return
    connection.close()
    fail("directTargetNotBlocked")


def destroy_private_file(path: pathlib.Path) -> None:
    try:
        info = path.lstat()
        if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid():
            with path.open("r+b", buffering=0) as f:
                remaining = info.st_size
                while remaining:
                    count = min(65536, remaining)
                    f.write(b"\0" * count)
                    remaining -= count
                os.fsync(f.fileno())
            path.unlink()
    except FileNotFoundError:
        return


def remove_owned_endpoint(path: pathlib.Path) -> None:
    try:
        info = path.lstat()
        if info.st_uid != os.getuid() or stat.S_ISLNK(info.st_mode):
            fail("cleanupIdentityChanged")
        if stat.S_ISSOCK(info.st_mode) or stat.S_ISREG(info.st_mode):
            path.unlink()
        else:
            fail("cleanupIdentityChanged")
    except FileNotFoundError:
        return


def absent_output(path: pathlib.Path, workspace: pathlib.Path) -> pathlib.Path:
    parent = path.parent.resolve(strict=True)
    base = workspace.resolve(strict=True)
    if parent != base and base not in parent.parents:
        fail("pathOutsideWorkspace")
    private_dir(parent)
    private_regular(path, absent=True)
    return path


def validate_test_identity(test_class: str, test_name: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_.]{1,200}", test_class) or not re.fullmatch(
        r"[A-Za-z0-9_]{1,160}", test_name
    ):
        fail("invalidTestIdentity")


def validate_build_receipt(path: pathlib.Path) -> dict:
    private_regular(path)
    raw = path.read_bytes()
    if len(raw) > 4096:
        fail("invalidBuildReceipt")
    value = json.loads(raw)
    expected = {
        "schemaVersion",
        "sourceRevision",
        "archiveSha256",
        "goVersion",
        "goSumSha256",
        "gatewayBinarySha256",
        "authBinarySha256",
    }
    if (
        not isinstance(value, dict)
        or set(value) != expected
        or value["schemaVersion"] != 1
        or value["sourceRevision"] != REVISION
        or value["archiveSha256"] != ARCHIVE_SHA
        or value["goVersion"] != GO_VERSION
    ):
        fail("invalidBuildReceipt")
    for key in ("goSumSha256", "gatewayBinarySha256", "authBinarySha256"):
        if (
            not isinstance(value[key], str)
            or len(value[key]) != 64
            or any(c not in "0123456789abcdef" for c in value[key])
        ):
            fail("invalidBuildReceipt")
    return value


def validate_target_build_receipt(
    path: pathlib.Path, target_binary: pathlib.Path
) -> dict:
    value = _read_private_json(path, 4096, "invalidTargetBuildReceipt")
    expected = {
        "schemaVersion",
        "sourceRevision",
        "sourceArchiveSha256",
        "targetPatchSha256",
        "targetBinarySha256",
        "witnessSchemaVersion",
    }
    if (
        set(value) != expected
        or value.get("schemaVersion") != 1
        or value.get("sourceRevision") != TARGET_REVISION
        or value.get("sourceArchiveSha256") != TARGET_ARCHIVE_SHA
        or value.get("targetPatchSha256") != TARGET_PATCH_SHA
        or value.get("witnessSchemaVersion") != 2
    ):
        fail("invalidTargetBuildReceipt")
    for key in ("sourceArchiveSha256", "targetPatchSha256", "targetBinarySha256"):
        if not isinstance(value.get(key), str) or not _HEX64.fullmatch(value[key]):
            fail("invalidTargetBuildReceipt")
    if sha256(target_binary) != value["targetBinarySha256"]:
        fail("targetBinaryHashMismatch")
    return value


def validate_full_target_build_receipt(
    path: pathlib.Path, target_binary: pathlib.Path
) -> dict:
    value = _read_private_json(path, 4096, "invalidTargetBuildReceipt")
    expected = {
        "schemaVersion", "sourceRevision", "sourceArchiveSha256",
        "targetPatchSha256", "sourceManifestSha256", "cmakeArgumentsSha256",
        "shadowBinarySha256", "xfreerdpBinarySha256", "witnessSchemaVersion",
        "deviceName",
    }
    if (
        set(value) != expected
        or value.get("schemaVersion") != 1
        or value.get("sourceRevision") != TARGET_REVISION
        or value.get("sourceArchiveSha256") != TARGET_ARCHIVE_SHA
        or value.get("targetPatchSha256") != TARGET_PATCH_SHA
        or value.get("sourceManifestSha256") != TARGET_SOURCE_MANIFEST_SHA
        or value.get("witnessSchemaVersion") != 2
        or value.get("deviceName") != "LrnXfer"
    ):
        fail("invalidTargetBuildReceipt")
    for key in (
        "sourceArchiveSha256", "targetPatchSha256", "sourceManifestSha256",
        "cmakeArgumentsSha256", "shadowBinarySha256", "xfreerdpBinarySha256",
    ):
        if not isinstance(value.get(key), str) or not _HEX64.fullmatch(value[key]):
            fail("invalidTargetBuildReceipt")
    if sha256(target_binary) != value["shadowBinarySha256"]:
        fail("targetBinaryHashMismatch")
    return value


def _openssl_md4(openssl: pathlib.Path, password: str) -> bytes:
    result = subprocess.run(
        [str(openssl), "dgst", "-provider", "legacy", "-md4", "-binary"],
        input=password.encode("utf-16le"), stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, check=False, timeout=10,
    )
    if result.returncode != 0 or len(result.stdout) != 16:
        fail("targetCredentialSetupFailed")
    return result.stdout


def _journal_process(
    state: dict, kind: str, process: OwnedProcess, journal: pathlib.Path
) -> None:
    state["processes"].append(
        {"kind": kind, "pid": process.pid, "start": process.start}
    )
    write_cleanup_state(journal, state)


def _journal_setup(state: dict, item: str, journal: pathlib.Path) -> None:
    state["setup"].append(item)
    write_cleanup_state(journal, state)


def cleanup_state(state: dict) -> None:
    state = _validate_cleanup_state(state)
    failed = False
    for process in reversed(state["processes"]):
        stat_path = pathlib.Path(f"/proc/{process['pid']}/stat")
        try:
            current = stat_path.read_text().split()[21]
        except (FileNotFoundError, IndexError):
            continue
        if current != process["start"]:
            failed = True
            continue
        try:
            terminated = sudo_status(["/bin/kill", "-TERM", "--", f"-{process['pid']}"])
            if terminated.returncode not in (0, 1):
                fail("cleanupFailed")
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    current = stat_path.read_text().split()[21]
                except (FileNotFoundError, IndexError):
                    break
                if current != process["start"]:
                    fail("cleanupIdentityChanged")
                time.sleep(0.05)
            else:
                killed = sudo_status(["/bin/kill", "-KILL", "--", f"-{process['pid']}"])
                if killed.returncode not in (0, 1):
                    fail("cleanupFailed")
        except BaseException:
            failed = True
    if "firewall" in state["setup"]:
        try:
            rule = [
                "OUTPUT",
                "-d",
                f"{state['targetIp']}/32",
                "-p",
                "tcp",
                "--dport",
                str(state["targetPort"]),
                "-m",
                "comment",
                "--comment",
                state["firewallComment"],
                "-j",
                "REJECT",
                "--reject-with",
                "tcp-reset",
            ]
            present = sudo_status(["/usr/sbin/iptables", "-C", *rule])
            if present.returncode == 0:
                sudo(["/usr/sbin/iptables", "-D", *rule])
            elif present.returncode != 1:
                fail("cleanupFailed")
        except BaseException:
            failed = True
    if "link" in state["setup"]:
        try:
            present = sudo_status(
                ["/usr/sbin/ip", "link", "show", "dev", state["hostIf"]]
            )
            if present.returncode == 0:
                sudo(["/usr/sbin/ip", "link", "del", state["hostIf"]])
            elif present.returncode != 1:
                fail("cleanupFailed")
        except BaseException:
            failed = True
    if "ns" in state["setup"]:
        try:
            listed = (
                sudo(["/usr/sbin/ip", "netns", "list"])
                .stdout.decode("ascii", "strict")
                .splitlines()
            )
            exists = any(
                line.split(maxsplit=1)[0] == state["namespace"]
                for line in listed
                if line.strip()
            )
            if exists:
                pids = (
                    sudo(["/usr/sbin/ip", "netns", "pids", state["namespace"]])
                    .stdout.decode("ascii", "strict")
                    .split()
                )
                for pid in pids:
                    if not pid.isdigit():
                        fail("cleanupIdentityChanged")
                    sudo(["/bin/kill", "-KILL", pid])
                sudo(["/usr/sbin/ip", "netns", "del", state["namespace"]])
        except BaseException:
            failed = True
    if failed:
        fail("cleanupFailed")


def cleanup_command(args) -> None:
    require_owned_linux()
    workspace = pathlib.Path(args.workspace)
    private_dir(workspace)
    journal = canonical_under(pathlib.Path(args.cleanup_state), workspace)
    state = read_cleanup_state(journal)
    cleanup_state(state)
    destroy_private_file(journal)
    print(
        json.dumps(
            {"state": "cleaned", "featureAccepted": False},
            sort_keys=True,
            separators=(",", ":"),
        )
    )


def prepare_workspace_cleanup(args) -> None:
    """Restore removal permission only within this exact owned disposable root."""
    require_owned_linux()
    workspace = pathlib.Path(args.workspace)
    private_dir(workspace)
    for current, directories, files in os.walk(workspace, topdown=False, followlinks=False):
        parent = pathlib.Path(current)
        for name in files:
            path = parent / name
            info = path.lstat()
            if info.st_uid != os.getuid():
                fail("cleanupOwnershipChanged")
            if stat.S_ISLNK(info.st_mode):
                continue
            if not stat.S_ISREG(info.st_mode):
                fail("cleanupTypeChanged")
            os.chmod(path, 0o600, follow_symlinks=False)
        for name in directories:
            path = parent / name
            info = path.lstat()
            if info.st_uid != os.getuid():
                fail("cleanupOwnershipChanged")
            if stat.S_ISLNK(info.st_mode):
                continue
            if not stat.S_ISDIR(info.st_mode):
                fail("cleanupTypeChanged")
            os.chmod(path, 0o700, follow_symlinks=False)
    os.chmod(workspace, 0o700, follow_symlinks=False)
    print(json.dumps({"state": "cleanupPrepared"}, separators=(",", ":")))


def run(args) -> None:
    require_owned_linux()
    workspace = pathlib.Path(args.workspace)
    private_dir(workspace)
    validate_test_identity(args.expected_test_class, args.expected_test_name)
    if (
        not 1 <= args.gateway_port <= 65535
        or not 1 <= args.target_port <= 65535
        or args.gateway_port == args.target_port
        or not 1 <= args.client_timeout <= 1800
    ):
        fail("invalidBounds")
    receipt = validate_build_receipt(
        canonical_under(pathlib.Path(args.build_receipt), workspace)
    )
    gateway = canonical_under(pathlib.Path(args.gateway_binary), workspace)
    auth = canonical_under(pathlib.Path(args.auth_binary), workspace)
    private_regular(gateway, executable=True)
    private_regular(auth, executable=True)
    if (
        sha256(gateway) != receipt["gatewayBinarySha256"]
        or sha256(auth) != receipt["authBinarySha256"]
    ):
        fail("binaryHashMismatch")
    openssl = pathlib.Path("/usr/bin/openssl")
    trusted_executable(openssl)
    for tool in (
        "/usr/sbin/ip",
        "/usr/sbin/iptables",
        "/usr/bin/setpriv",
        "/usr/bin/env",
        "/bin/kill",
    ):
        trusted_executable(pathlib.Path(tool))
    client_argv = read_command(
        canonical_under(pathlib.Path(args.client_command), workspace)
    )
    real_shadow = getattr(args, "shadow_binary", None) is not None
    if real_shadow:
        target_binary = canonical_under(pathlib.Path(args.shadow_binary), workspace)
        target_argv = []
    else:
        target_argv = read_command(
            canonical_under(pathlib.Path(args.target_command), workspace)
        )
        target_binary = canonical_under(pathlib.Path(target_argv[0]), workspace)
    private_regular(target_binary, executable=True)
    if real_shadow:
        validate_full_target_build_receipt(
            canonical_under(pathlib.Path(args.freerdp_build_receipt), workspace),
            target_binary,
        )
    else:
        validate_target_build_receipt(
            canonical_under(pathlib.Path(args.target_build_receipt), workspace),
            target_binary,
        )
    run_dir = workspace / "run"
    run_dir.mkdir(mode=0o700)
    private_dir(run_dir)
    token = secrets.token_hex(3)
    state = CleanupState.create(token, args.gateway_port, args.target_port)
    ns = state["namespace"]
    host_if = state["hostIf"]
    ns_if = state["nsIf"]
    host_ip = state["hostIp"]
    target_ip = state["targetIp"]
    target_port = args.target_port
    journal = run_dir / "cleanup-state.json"
    write_cleanup_state(journal, state)
    nonce = secrets.token_hex(32)
    gateway_user = "gw_" + secrets.token_hex(8)
    gateway_password = random_secret(32)
    target_user = "target_" + secrets.token_hex(8)
    target_domain = "LARENOR"
    target_password = random_secret(32)
    auth_socket = run_dir / "auth.sock"
    gateway_cert = run_dir / "gateway.pem"
    gateway_key = run_dir / "gateway.key"
    session_key = random_secret()
    session_enc = random_secret()
    paa_sign = random_secret()
    paa_enc = random_secret()
    auth_cfg = run_dir / "auth.yaml"
    gw_cfg = run_dir / "gateway.yaml"
    processes = []
    primary = None
    public = None
    relay = None
    target_identity = run_dir / "target-identity.json"
    target_witness = run_dir / "target-witness.json"
    target_home = run_dir / "target-home"
    target_config = target_home / ".config" / "freerdp" / "shadow"
    target_cert = target_config / "shadow.crt" if real_shadow else canonical_under(
        pathlib.Path(args.target_cert), workspace
    )
    target_key = target_config / "shadow.key"
    target_sam = run_dir / "target.sam"
    if not real_shadow:
        private_regular(target_cert)
    secret_files = [
        auth_cfg,
        gw_cfg,
        gateway_key,
        gateway_cert,
        target_identity,
        target_witness,
    ]
    cleanup_dirs = []
    if real_shadow:
        secret_files.extend([target_cert, target_key, target_sam])
        cleanup_dirs.extend([target_config, target_config.parent, target_home / ".config", target_home])
    previous_handlers = {
        sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)
    }

    def interrupted(signum, frame):
        raise FixtureError("interrupted")

    for sig in previous_handlers:
        signal.signal(sig, interrupted)
    try:
        if real_shadow:
            target_config.mkdir(parents=True, mode=0o700)
            cp = bounded_run(
                [
                    str(openssl), "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-days", "1", "-subj", f"/CN={target_ip}", "-addext",
                    f"subjectAltName=IP:{target_ip}", "-keyout", str(target_key),
                    "-out", str(target_cert),
                ],
                timeout=30,
            )
            if cp.returncode:
                fail("certificateCreateFailed")
            os.chmod(target_cert, 0o600)
            os.chmod(target_key, 0o600)
            nt_hash = _openssl_md4(openssl, target_password)
            write_private(
                target_sam,
                f"{target_user}:{target_domain}::{nt_hash.hex()}:::\n",
            )
        cp = bounded_run(
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
                "/CN=10.0.2.2",
                "-addext",
                "subjectAltName=IP:10.0.2.2",
                "-keyout",
                str(gateway_key),
                "-out",
                str(gateway_cert),
            ],
            timeout=30,
        )
        if cp.returncode:
            fail("certificateCreateFailed")
        os.chmod(gateway_cert, 0o600)
        os.chmod(gateway_key, 0o600)
        write_private(
            auth_cfg,
            f"Users:\n  - Username: {gateway_user}\n    Password: {gateway_password}\n",
        )
        write_private(
            target_identity,
            json.dumps(
                {
                    "schemaVersion": 1,
                    "username": target_user,
                    "domain": target_domain,
                    "password": target_password,
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n",
        )
        private_regular(target_witness, absent=True)
        write_private(
            gw_cfg,
            f"""Server:\n  Authentication:\n    - ntlm\n  AuthSocket: {auth_socket}\n  BasicAuthTimeout: 5\n  Tls: enable\n  CertFile: {gateway_cert}\n  KeyFile: {gateway_key}\n  GatewayAddress: 10.0.2.2:{args.gateway_port}\n  BindAddress: {target_ip}\n  Port: {args.gateway_port}\n  Hosts:\n    - {target_ip}:{target_port}\n  HostSelection: roundrobin\n  AllowPrivateDestinations: false\n  SessionKey: {session_key}\n  SessionEncryptionKey: {session_enc}\n  SessionStore: cookie\nCaps:\n  TokenAuth: false\n  IdleTimeout: 2\n  RedirectAll: false\n  DisableRedirect: false\n  EnableClipboard: false\n  EnablePrinter: false\n  EnablePort: false\n  EnablePnp: false\n  EnableDrive: true\nSecurity:\n  PAATokenSigningKey: {paa_sign}\n  PAATokenEncryptionKey: {paa_enc}\n""",
        )
        sudo(["/usr/sbin/ip", "netns", "add", ns])
        _journal_setup(state, "ns", journal)
        sudo(
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
        _journal_setup(state, "link", journal)
        sudo(["/usr/sbin/ip", "link", "set", ns_if, "netns", ns])
        sudo(["/usr/sbin/ip", "addr", "add", f"{host_ip}/30", "dev", host_if])
        sudo(["/usr/sbin/ip", "link", "set", host_if, "up"])
        sudo(
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
        sudo(
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
        sudo(
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
        if real_shadow:
            xvfb_binary = pathlib.Path("/usr/bin/Xvfb")
            trusted_executable(xvfb_binary)
            display_number = 90 + secrets.randbelow(30)
            display = f":{display_number}"
            display_socket = pathlib.Path(f"/tmp/.X11-unix/X{display_number}")
            if display_socket.exists() or display_socket.is_symlink():
                fail("displayAlreadyOwned")
            xvfb = OwnedProcess(
                [str(xvfb_binary), display, "-screen", "0", "1024x768x24",
                 "-nolisten", "tcp", "-noreset", "-ac"],
                cwd=run_dir,
            )
            processes.append(xvfb)
            _journal_process(state, "xvfb", xvfb, journal)
            wait_path(display_socket, time.monotonic() + 10)
            target_argv = [
                f"HOME={target_home}", f"XDG_CONFIG_HOME={target_home / '.config'}",
                f"DISPLAY={display}", *target_argv, str(target_binary),
                f"/port:{target_port}", f"/bind-address:{target_ip}", "/sec:nla",
                f"/sam-file:{target_sam}", "/log-level:OFF", "/may-view", "/may-interact",
            ]
        target_cmd = [
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
            f"LARENOR_F62_TARGET_HOST={target_ip}",
            f"LARENOR_F62_TARGET_PORT={target_port}",
            f"LARENOR_F62_TARGET_IDENTITY={target_identity}",
            f"LARENOR_F62_TARGET_USERNAME={target_user}",
            f"LARENOR_F62_TARGET_DOMAIN={target_domain}",
            f"LARENOR_F62_TARGET_NONCE={nonce}",
            f"LARENOR_F62_TARGET_WITNESS={target_witness}",
            f"LARENOR_F62_EXPECT_UPLOAD_SHA256={expected_upload_sha256(nonce)}",
            f"LARENOR_F62_EXPECT_OUTBOUND_SHA256={expected_outbound_sha256(nonce)}",
            *target_argv,
        ]
        target = OwnedProcess(["/usr/bin/sudo", "-n", *target_cmd], cwd=workspace)
        processes.append(target)
        _journal_process(state, "target", target, journal)
        wait_tcp(target_ip, target_port, time.monotonic() + 15)
        configured_pin = tls_pin(openssl, target_cert)
        observed_pin = live_tls_pin(openssl, target_ip, target_port, run_dir)
        if configured_pin != observed_pin:
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
        sudo(rule)
        _journal_setup(state, "firewall", journal)
        require_tcp_blocked(target_ip, target_port)
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
        auth_process = OwnedProcess(
            [*ns_prefix, str(auth), "-c", str(auth_cfg), "-s", str(auth_socket)],
            cwd=run_dir,
            capture=True,
        )
        processes.append(auth_process)
        _journal_process(state, "auth", auth_process, journal)
        wait_path(auth_socket, time.monotonic() + 10)
        gateway_process = OwnedProcess(
            [*ns_prefix, str(gateway), "-c", str(gw_cfg)], cwd=run_dir, capture=True
        )
        processes.append(gateway_process)
        _journal_process(state, "gateway", gateway_process, journal)
        relay = TcpRelay(args.gateway_port, target_ip, args.gateway_port)
        wait_tls(args.gateway_port, time.monotonic() + 15)
        descriptor = run_dir / "private-session.json"
        witness = run_dir / "private-witness.json"
        secret_files.extend([descriptor, witness])
        private_regular(witness, absent=True)
        write_private(
            descriptor,
            json.dumps(
                {
                    "schemaVersion": 2,
                    "nonce": nonce,
                    "testClass": args.expected_test_class,
                    "testName": args.expected_test_name,
                    "gatewayHost": "10.0.2.2",
                    "gatewayPort": args.gateway_port,
                    "gatewayUsername": gateway_user,
                    "gatewayPassword": gateway_password,
                    "gatewayDomain": "LARENOR",
                    "gatewayPin": tls_pin(openssl, gateway_cert),
                    "targetHost": target_ip,
                    "targetPort": target_port,
                    "targetUsername": target_user,
                    "targetDomain": target_domain,
                    "targetPassword": target_password,
                    "targetPin": observed_pin,
                    "expectedUploadSha256": expected_upload_sha256(nonce),
                    "expectedOutboundSha256": expected_outbound_sha256(nonce),
                    "witnessPath": str(witness),
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n",
        )
        env = dict(os.environ)
        env["LARENOR_F62_RDGW_DESCRIPTOR"] = str(descriptor)
        client = OwnedProcess(client_argv, cwd=workspace, env=env)
        processes.append(client)
        _journal_process(state, "client", client, journal)
        try:
            code = client.proc.wait(args.client_timeout)
        except subprocess.TimeoutExpired:
            fail("clientTimeout")
        if code != 0:
            fail("clientFailed")
        client_facts = validate_client_witness(
            witness, nonce, args.expected_test_class, args.expected_test_name
        )
        wait_path(target_witness, time.monotonic() + 10)
        target_facts = validate_target_witness(target_witness, nonce)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and (
            not auth_observed(auth_process.bounded_output(), gateway_user)
            or not target_connect_observed(
                gateway_process.bounded_output(), target_ip, target_port
            )
        ):
            time.sleep(0.05)
        facts = {
            "gatewayPinMatched": client_facts["gatewayPinMatched"],
            "targetPinMatched": client_facts["targetPinMatched"],
            "gatewayAuthObserved": auth_observed(
                auth_process.bounded_output(), gateway_user
            ),
            "configuredTargetExact": target_connect_observed(
                gateway_process.bounded_output(), target_ip, target_port
            ),
            "directTargetBlocked": client_facts["directTargetBlocked"],
            "targetConnectedThroughGateway": target_facts["nlaAuthenticated"]
            and target_connect_observed(
                gateway_process.bounded_output(), target_ip, target_port
            ),
            "frameAcknowledged": client_facts["frameAcknowledged"],
            "safUploadMatched": target_facts["uploadSha256"]
            == expected_upload_sha256(nonce),
            "safDownloadCommitted": client_facts["safReadbackSha256"]
            == target_facts["outboundSha256"],
            "sessionDrained": client_facts["nativeDrainConfirmed"]
            and target_facts["cleanClose"],
            "ownersRetired": client_facts["ownersRetired"],
        }
        if not acceptance_complete(facts):
            fail("acceptanceIncomplete")
        public = {
            **receipt,
            "schemaVersion": 2,
            "testClass": client_facts["testClass"],
            "testName": client_facts["testName"],
            "tests": client_facts["tests"],
            "failures": 0,
            "errors": 0,
            "skipped": 0,
            **facts,
            "featureAccepted": False,
            "scope": "ownedRdGatewaySafPrepared",
        }
        if set(public) != RECEIPT_KEYS:
            fail("invalidPublicReceipt")
    except BaseException as error:
        primary = error
    finally:
        cleanup_ok = True
        if relay is not None:
            try:
                relay.close()
            except BaseException:
                cleanup_ok = False
        for p in reversed(processes):
            try:
                p.close()
            except BaseException:
                cleanup_ok = False
        if "firewall" in state["setup"]:
            try:
                sudo(
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
                sudo(["/usr/sbin/ip", "link", "del", host_if])
            except BaseException:
                cleanup_ok = False
        if "ns" in state["setup"]:
            try:
                pids = (
                    sudo(["/usr/sbin/ip", "netns", "pids", ns])
                    .stdout.decode("ascii", "strict")
                    .split()
                )
                for pid in pids:
                    sudo(["/bin/kill", "-KILL", pid])
                sudo(["/usr/sbin/ip", "netns", "del", ns])
            except BaseException:
                cleanup_ok = False
        for path in secret_files:
            try:
                destroy_private_file(path)
            except BaseException:
                cleanup_ok = False
        for directory in cleanup_dirs:
            try:
                directory.rmdir()
            except BaseException:
                cleanup_ok = False
        try:
            remove_owned_endpoint(auth_socket)
        except BaseException:
            cleanup_ok = False
        if cleanup_ok:
            try:
                destroy_private_file(journal)
            except BaseException:
                cleanup_ok = False
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
        if cleanup_ok:
            try:
                run_dir.rmdir()
            except BaseException:
                cleanup_ok = False
    if primary is not None:
        raise primary
    if not cleanup_ok:
        fail("cleanupFailed")
    if public is None:
        fail("acceptanceIncomplete")
    out = absent_output(pathlib.Path(args.public_receipt), workspace)
    out.write_text(json.dumps(public, sort_keys=True, separators=(",", ":")) + "\n")
    os.chmod(out, 0o600)
    print(
        json.dumps(
            {
                "state": "ownedEffectsObserved",
                "receiptSha256": sha256(out),
                "featureAccepted": False,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )


def self_test() -> None:
    import unittest

    class Tests(unittest.TestCase):
        def test_closed_client_witness(self):
            with tempfile.TemporaryDirectory() as d:
                p = pathlib.Path(d) / "w"
                n = "a" * 64
                c = "com.example.OwnedTest"
                m = "connectsThroughGateway"
                p.write_text(
                    json.dumps(
                        {
                            "schemaVersion": 2,
                            "nonce": n,
                            "testClass": c,
                            "testName": m,
                            "tests": 1,
                            "failures": 0,
                            "errors": 0,
                            "skipped": 0,
                            "directTargetBlocked": True,
                            "gatewayPinMatched": True,
                            "targetPinMatched": True,
                            "frameAcknowledged": True,
                            "nativeDrainConfirmed": True,
                            "safReadbackSha256": expected_outbound_sha256(n),
                            "ownersRetired": True,
                        }
                    )
                )
                os.chmod(p, 0o600)
                self.assertTrue(
                    validate_client_witness(p, n, c, m)["nativeDrainConfirmed"]
                )

        def test_extra_rejected(self):
            with tempfile.TemporaryDirectory() as d:
                p = pathlib.Path(d) / "w"
                p.write_text("{}")
                os.chmod(p, 0o600)
                with self.assertRaises(FixtureError):
                    validate_client_witness(
                        p, "a" * 64, "com.example.OwnedTest", "connectsThroughGateway"
                    )

        def test_receipt_is_failure_closed(self):
            self.assertIn("gatewayAuthObserved", RECEIPT_KEYS)
            self.assertIn("safUploadMatched", RECEIPT_KEYS)
            self.assertIn("safDownloadCommitted", RECEIPT_KEYS)
            self.assertNotIn("gatewayPassword", RECEIPT_KEYS)
            self.assertNotIn("targetHost", RECEIPT_KEYS)
            self.assertNotIn("nonce", RECEIPT_KEYS)

        def test_secrets_distinct(self):
            self.assertNotEqual(random_secret(), random_secret())

        def test_build_receipt_rejects_extra(self):
            with tempfile.TemporaryDirectory() as d:
                p = pathlib.Path(d) / "r"
                p.write_text(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "sourceRevision": REVISION,
                            "archiveSha256": ARCHIVE_SHA,
                            "goVersion": GO_VERSION,
                            "goSumSha256": "a" * 64,
                            "gatewayBinarySha256": "b" * 64,
                            "authBinarySha256": "c" * 64,
                            "extra": True,
                        }
                    )
                )
                os.chmod(p, 0o600)
                with self.assertRaises(FixtureError):
                    validate_build_receipt(p)

        def test_bounded_command_output(self):
            cp = bounded_run(
                [
                    str(pathlib.Path(sys.executable).resolve()),
                    "-c",
                    'import sys;sys.stdout.write("x"*70000);sys.stderr.write("y"*70000)',
                ],
                timeout=10,
            )
            self.assertEqual(cp.returncode, 0)
            self.assertEqual(len(cp.stdout), 65536)
            self.assertEqual(len(cp.stderr), 65536)

        def test_payload_blind_relay_and_cleanup(self):
            server = socket.socket()
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            server.settimeout(5)

            def echo():
                connection, _ = server.accept()
                data = connection.recv(16)
                connection.sendall(data)
                connection.close()
                server.close()

            echo_thread = threading.Thread(target=echo)
            echo_thread.start()
            relay = TcpRelay(0, "127.0.0.1", server.getsockname()[1])
            with socket.create_connection(
                ("127.0.0.1", relay.listen_port), timeout=5
            ) as client:
                client.sendall(b"opaque")
                self.assertEqual(client.recv(16), b"opaque")
            relay.close()
            echo_thread.join(5)
            self.assertFalse(echo_thread.is_alive())

        def test_publication_follows_cleanup(self):
            source = pathlib.Path(__file__).read_text()
            start = source.index("def run(args) -> None:")
            end = source.index("\ndef self_test() -> None:")
            body = " ".join(source[start:end].split())
            self.assertLess(body.index("finally:"), body.index("out = absent_output"))
            self.assertIn("AllowPrivateDestinations: false", body)
            self.assertIn('"-I", "OUTPUT"', body)
            self.assertIn("relay = TcpRelay", body)
            self.assertIn('"netns", "exec", ns', body)
            self.assertIn('"-m", "comment", "--comment"', body)

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Tests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="command", required=True)
    b = sp.add_parser("build")
    b.add_argument("--workspace", required=True)
    b.add_argument("--archive", required=True)
    b.add_argument("--go", required=True)
    r = sp.add_parser("run")
    r.add_argument("--workspace", required=True)
    r.add_argument("--build-receipt", required=True)
    r.add_argument("--gateway-binary", required=True)
    r.add_argument("--auth-binary", required=True)
    r.add_argument("--target-command", required=True)
    r.add_argument("--target-build-receipt", required=True)
    r.add_argument("--client-command", required=True)
    r.add_argument("--target-cert", required=True)
    r.add_argument("--gateway-port", type=int, required=True)
    r.add_argument("--target-port", type=int, default=3390)
    r.add_argument("--client-timeout", type=int, default=900)
    r.add_argument("--expected-test-class", required=True)
    r.add_argument("--expected-test-name", required=True)
    r.add_argument("--public-receipt", required=True)
    ra = sp.add_parser("run-android")
    ra.add_argument("--workspace", required=True)
    ra.add_argument("--build-receipt", required=True)
    ra.add_argument("--gateway-binary", required=True)
    ra.add_argument("--auth-binary", required=True)
    ra.add_argument("--shadow-binary", required=True)
    ra.add_argument("--freerdp-build-receipt", required=True)
    ra.add_argument("--client-command", required=True)
    ra.add_argument("--gateway-port", type=int, required=True)
    ra.add_argument("--target-port", type=int, default=3390)
    ra.add_argument("--client-timeout", type=int, default=900)
    ra.add_argument("--expected-test-class", required=True)
    ra.add_argument("--expected-test-name", required=True)
    ra.add_argument("--public-receipt", required=True)
    ra.set_defaults(target_command=None, target_build_receipt=None, target_cert=None)
    c = sp.add_parser("cleanup")
    c.add_argument("--workspace", required=True)
    c.add_argument("--cleanup-state", required=True)
    pc = sp.add_parser("prepare-cleanup")
    pc.add_argument("--workspace", required=True)
    sp.add_parser("self-test")
    args = ap.parse_args()
    try:
        if args.command == "build":
            build(args)
        elif args.command in ("run", "run-android"):
            run(args)
        elif args.command == "cleanup":
            cleanup_command(args)
        elif args.command == "prepare-cleanup":
            prepare_workspace_cleanup(args)
        else:
            self_test()
    except (FixtureError, ValueError, json.JSONDecodeError, UnicodeError, OSError) as e:
        stage = (
            e.args[0] if isinstance(e, FixtureError) and e.args else "fixtureFailure"
        )
        print(
            json.dumps(
                {"state": "failed", "stage": stage, "featureAccepted": False},
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        raise SystemExit(2)


if __name__ == "__main__":
    main()
