#!/usr/bin/env python3
"""Owned Ubuntu 24.04 Sunshine host for the F60 packaged-Android gate.

This module deliberately stops at the host boundary.  It creates an ephemeral
Sunshine instance that a separate packaged-Android orchestrator can pair with.
It never accepts a caller-selected endpoint, process identifier, release, or
API route and it never turns host readiness into streaming acceptance.
"""

from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass, field
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple
import urllib.parse
import urllib.request
import urllib.error
import uuid


SUNSHINE_TAG = "v2026.914.233613"
SUNSHINE_ASSET = "sunshine_2026.914.233613-1+ubuntu24.04_amd64.deb"
SUNSHINE_PACKAGE_VERSION = "2026.914.233613-1+ubuntu24.04"
SUNSHINE_SHA256 = "c38e9c705f650f8705f61702717e99bec34044c5028fcb8f23a08fe041292c21"
SUNSHINE_ASSET_BYTES = 11_001_782
SUNSHINE_URL = (
    "https://github.com/LizardByte/Sunshine/releases/download/"
    "v2026.914.233613/sunshine_2026.914.233613-1%2Bubuntu24.04_amd64.deb"
)
API_HOST = "127.0.0.1"
API_PORT = 47990
GAMESTREAM_PORT = 47989
DISPLAY = ":99"
OS_RELEASE = Path("/usr/lib/os-release")
OWNED_MDNS_NAME = "Larenor-F60-Owned"
MAX_RELEASE_BYTES = 16 * 1024 * 1024
MAX_API_BYTES = 1024 * 1024
MAX_MDNS_BYTES = 64 * 1024
START_TIMEOUT_SECONDS = 30
STOP_TIMEOUT_SECONDS = 5
_PAIRING_ID = re.compile(r"[0-9A-Fa-f]{32}\Z")
_CLIENT_NAME_BYTES = 128
_ALLOWED_RELEASE_HOSTS = frozenset(
    {
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    }
)


class HostFailure(RuntimeError):
    """A secret-free, fail-closed owned-host error."""


def _pairs(values: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in values:
        if key in result:
            raise HostFailure("Sunshine API response contains duplicate keys")
        result[key] = value
    return result


def _regular_nofollow(path: Path, *, maximum: int) -> bytes:
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise HostFailure("owned fixture file identity is invalid")
        if not 0 <= info.st_size <= maximum:
            raise HostFailure("owned fixture file size is invalid")
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(str(path), flags)
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                raise HostFailure("owned fixture file changed during read")
            chunks: List[bytes] = []
            remaining = maximum + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(65536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            if len(data) > maximum:
                raise HostFailure("owned fixture file size is invalid")
            return data
        finally:
            os.close(descriptor)
    except HostFailure:
        raise
    except OSError as error:
        raise HostFailure("owned fixture file is unavailable") from error


def _os_release(path: Path) -> Dict[str, str]:
    raw = _regular_nofollow(path, maximum=16 * 1024)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise HostFailure("host operating-system identity is invalid") from error
    values: Dict[str, str] = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Z_][A-Z0-9_]*", key) or key in values:
            raise HostFailure("host operating-system identity is invalid")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def require_owned_runner(
    environment: Mapping[str, str],
    *,
    os_release: Path = OS_RELEASE,
    machine: Optional[str] = None,
    platform_name: Optional[str] = None,
) -> None:
    """Refuse household, self-hosted, non-Linux, and non-Ubuntu-24.04 hosts."""

    if (
        environment.get("GITHUB_ACTIONS") != "true"
        or environment.get("RUNNER_ENVIRONMENT") != "github-hosted"
    ):
        raise HostFailure("F60 Sunshine fixture requires a GitHub-hosted runner")
    if (platform_name or sys.platform) != "linux":
        raise HostFailure("F60 Sunshine fixture requires Ubuntu 24.04")
    actual_machine = (machine or platform.machine()).lower()
    if actual_machine not in {"x86_64", "amd64"}:
        raise HostFailure("F60 Sunshine fixture requires x86_64")
    identity = _os_release(os_release)
    if identity.get("ID") != "ubuntu" or identity.get("VERSION_ID") != "24.04":
        raise HostFailure("F60 Sunshine fixture requires Ubuntu 24.04")


def _write_private(path: Path, data: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(str(path), flags, 0o600)
        try:
            view = memoryview(data)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise OSError("short write")
                view = view[written:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.chmod(path, 0o600, follow_symlinks=False)
    except OSError as error:
        raise HostFailure("private fixture material could not be written") from error


@dataclass(frozen=True)
class HostMaterial:
    root: Path
    config: Path
    apps: Path
    credentials: Path
    state: Path
    certificate: Path
    private_key: Path
    runtime: Path
    home: Path
    logs: Path


class PrivateWorkspace:
    def __init__(self, root: Path, identity: Tuple[int, int]):
        self.root = root
        self._identity = identity
        self._closed = False

    @classmethod
    def create(cls, parent: Path) -> "PrivateWorkspace":
        if not parent.is_absolute():
            raise HostFailure("fixture workspace parent must be absolute")
        try:
            parent_info = parent.lstat()
            if stat.S_ISLNK(parent_info.st_mode) or not stat.S_ISDIR(parent_info.st_mode):
                raise HostFailure("fixture workspace parent identity is invalid")
            if parent_info.st_uid != os.getuid():
                raise HostFailure("fixture workspace parent owner is invalid")
            root = Path(tempfile.mkdtemp(prefix="larenor-f60-sunshine-", dir=str(parent)))
            os.chmod(root, 0o700)
            info = root.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                raise HostFailure("private fixture workspace identity is invalid")
            return cls(root, (info.st_dev, info.st_ino))
        except HostFailure:
            raise
        except OSError as error:
            raise HostFailure("private fixture workspace is unavailable") from error

    def write_host_material(
        self,
        *,
        username: str,
        password: str,
        stream_profile: bool = False,
    ) -> HostMaterial:
        _validate_client_name(username)
        if not isinstance(password, str) or not 16 <= len(password) <= 256:
            raise HostFailure("private web credential is invalid")
        home = self.root / "home"
        runtime = self.root / "runtime"
        logs = self.root / "logs"
        for directory in (home, runtime, logs):
            directory.mkdir(mode=0o700)
            os.chmod(directory, 0o700)
        config = self.root / "sunshine.conf"
        apps = self.root / "apps.json"
        credentials = self.root / "web-credentials.json"
        state = self.root / "sunshine-state.json"
        certificate = self.root / "sunshine-cert.pem"
        private_key = self.root / "sunshine-key.pem"
        config_text = "".join(
            (
                "locale = en\n",
                "min_log_level = 1\n",
                "system_tray = disabled\n",
                "notify_pre_releases = disabled\n",
                "capture = x11\n",
                "encoder = software\n",
                "sw_preset = ultrafast\n",
                "hevc_mode = 1\n",
                "av1_mode = 1\n",
                "min_threads = 2\n",
                "max_bitrate = 2000\n",
                "address_family = ipv4\n",
                "bind_address = 0.0.0.0\n",
                "port = 47989\n",
                "upnp = disabled\n",
                "origin_web_ui_allowed = pc\n",
                "sunshine_name = " + OWNED_MDNS_NAME + "\n",
                "keyboard = " + ("enabled" if stream_profile else "disabled") + "\n",
                "mouse = " + ("enabled" if stream_profile else "disabled") + "\n",
                "controller = disabled\n",
                "file_apps = " + str(apps) + "\n",
                "credentials_file = " + str(credentials) + "\n",
                "file_state = " + str(state) + "\n",
                "pkey = " + str(private_key) + "\n",
                "cert = " + str(certificate) + "\n",
                "log_path = " + str(logs / "sunshine.log") + "\n",
            )
        )
        _write_private(config, config_text.encode("utf-8"))
        _write_private(
            apps,
            json.dumps(
                {"env": {}, "apps": [{"name": "Desktop"}]},
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8"),
        )
        _write_private(credentials, b"{}\n")
        _write_private(state, b"{}\n")
        return HostMaterial(
            root=self.root,
            config=config,
            apps=apps,
            credentials=credentials,
            state=state,
            certificate=certificate,
            private_key=private_key,
            runtime=runtime,
            home=home,
            logs=logs,
        )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            info = self.root.lstat()
            if stat.S_ISLNK(info.st_mode) or (info.st_dev, info.st_ino) != self._identity:
                raise HostFailure("private fixture workspace changed before cleanup")
            shutil.rmtree(self.root)
        except FileNotFoundError:
            return
        except HostFailure:
            raise
        except OSError as error:
            raise HostFailure("private fixture workspace cleanup failed") from error


def _download_verified(
    url: str,
    destination: Path,
    *,
    expected_sha256: str,
    max_bytes: int,
    opener: Callable[..., Any] = urllib.request.urlopen,
) -> None:
    if urllib.parse.urlsplit(url).scheme != "https":
        raise HostFailure("Sunshine release URL is invalid")
    request = urllib.request.Request(url, headers={"User-Agent": "larenor-f60-owned-host/1"})
    digest = hashlib.sha256()
    total = 0
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor: Optional[int] = None
    try:
        with opener(request, timeout=30) as response:
            final = urllib.parse.urlsplit(response.geturl())
            if final.scheme != "https" or final.hostname not in _ALLOWED_RELEASE_HOSTS:
                raise HostFailure("Sunshine release redirect is invalid")
            if getattr(response, "status", 200) != 200:
                raise HostFailure("Sunshine release download failed")
            length = response.headers.get("Content-Length")
            if length is not None:
                try:
                    declared = int(length)
                except ValueError as error:
                    raise HostFailure("Sunshine release length is invalid") from error
                if not 1 <= declared <= max_bytes:
                    raise HostFailure("Sunshine release length is invalid")
            descriptor = os.open(str(destination), flags, 0o600)
            while True:
                chunk = response.read(min(65536, max_bytes - total + 1))
                if not chunk:
                    break
                total += len(chunk)
                if total > max_bytes:
                    raise HostFailure("Sunshine release exceeds the download bound")
                digest.update(chunk)
                view = memoryview(chunk)
                while view:
                    written = os.write(descriptor, view)
                    if written <= 0:
                        raise OSError("short write")
                    view = view[written:]
            os.fsync(descriptor)
        if total <= 0 or digest.hexdigest() != expected_sha256:
            raise HostFailure("Sunshine release digest does not match the pinned asset")
        os.chmod(destination, 0o600, follow_symlinks=False)
    except HostFailure:
        try:
            destination.unlink(missing_ok=True)
        except OSError:
            pass
        raise
    except (OSError, urllib.error.URLError) as error:
        try:
            destination.unlink(missing_ok=True)
        except OSError:
            pass
        raise HostFailure("Sunshine release acquisition failed") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)


def acquire_release(workspace: PrivateWorkspace) -> Path:
    package = workspace.root / SUNSHINE_ASSET
    _download_verified(
        SUNSHINE_URL,
        package,
        expected_sha256=SUNSHINE_SHA256,
        max_bytes=MAX_RELEASE_BYTES,
    )
    if package.stat().st_size != SUNSHINE_ASSET_BYTES:
        package.unlink(missing_ok=True)
        raise HostFailure("Sunshine release size does not match the pinned asset")
    return package


def install_release(package: Path, *, runner: Callable[..., Any] = subprocess.run) -> None:
    raw = _regular_nofollow(package, maximum=MAX_RELEASE_BYTES)
    if len(raw) != SUNSHINE_ASSET_BYTES or hashlib.sha256(raw).hexdigest() != SUNSHINE_SHA256:
        raise HostFailure("Sunshine package identity is invalid")
    try:
        install = runner(
            [
                "/usr/bin/sudo",
                "/usr/bin/apt-get",
                "install",
                "--yes",
                "--no-install-recommends",
                str(package),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=300,
        )
        if install.returncode != 0:
            raise HostFailure("pinned Sunshine package installation failed")
        query = runner(
            ["/usr/bin/dpkg-query", "--show", "--showformat=${Version}", "sunshine"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        if query.returncode != 0 or query.stdout != SUNSHINE_PACKAGE_VERSION:
            raise HostFailure("installed Sunshine package identity does not match")
    except HostFailure:
        raise
    except (OSError, subprocess.TimeoutExpired) as error:
        raise HostFailure("pinned Sunshine package installation failed") from error


def _validate_client_name(value: str) -> None:
    if not isinstance(value, str):
        raise HostFailure("owned client name is invalid")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeError as error:
        raise HostFailure("owned client name is invalid") from error
    if not 1 <= size <= _CLIENT_NAME_BYTES or any(ord(character) < 32 for character in value):
        raise HostFailure("owned client name is invalid")


def _pairing_id(value: str) -> None:
    if not isinstance(value, str) or _PAIRING_ID.fullmatch(value) is None:
        raise HostFailure("owned pairing identifier is invalid")


def _uuid(value: str) -> None:
    if not isinstance(value, str) or len(value) != 36:
        raise HostFailure("owned client identifier is invalid")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise HostFailure("owned client identifier is invalid") from error
    if str(parsed).lower() != value.lower():
        raise HostFailure("owned client identifier is invalid")


def pinned_ssl_context(certificate: Path) -> ssl.SSLContext:
    raw = _regular_nofollow(certificate, maximum=64 * 1024)
    if b"-----BEGIN CERTIFICATE-----" not in raw:
        raise HostFailure("Sunshine TLS certificate is invalid")
    try:
        context = ssl.create_default_context(cafile=str(certificate))
    except (OSError, ssl.SSLError) as error:
        raise HostFailure("Sunshine TLS certificate is invalid") from error
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context


@dataclass(repr=False)
class SunshineApi:
    username: str
    password: str
    certificate: Path
    connection_factory: Callable[..., Any] = http.client.HTTPSConnection
    ssl_context_factory: Callable[[Path], Any] = pinned_ssl_context
    timeout_seconds: float = 10.0

    def __post_init__(self) -> None:
        _validate_client_name(self.username)
        if not isinstance(self.password, str) or not 1 <= len(self.password) <= 256:
            raise HostFailure("private web credential is invalid")
        if not 0 < self.timeout_seconds <= 15:
            raise HostFailure("Sunshine API timeout is invalid")

    def __repr__(self) -> str:
        return "<SunshineApi pinned-local-client>"

    def _request(self, method: str, path: str, body: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
        allowed = {
            ("GET", "/api/pin"),
            ("DELETE", "/api/pin"),
            ("POST", "/api/pin"),
            ("GET", "/api/clients/list"),
            ("POST", "/api/clients/unpair"),
        }
        if (method, path) not in allowed:
            raise HostFailure("Sunshine API operation is not allowed")
        encoded = None
        if body is not None:
            encoded = json.dumps(body, separators=(",", ":"), sort_keys=True).encode("utf-8")
            if len(encoded) > 1024:
                raise HostFailure("Sunshine API request is too large")
        authorization = base64.b64encode(
            (self.username + ":" + self.password).encode("utf-8")
        ).decode("ascii")
        headers = {
            "Accept": "application/json",
            "Authorization": "Basic " + authorization,
            "Connection": "close",
            "User-Agent": "larenor-f60-owned-host/1",
        }
        if encoded is not None:
            headers["Content-Type"] = "application/json"
        connection = self.connection_factory(
            API_HOST,
            API_PORT,
            timeout=self.timeout_seconds,
            context=self.ssl_context_factory(self.certificate),
        )
        try:
            connection.request(method, path, body=encoded, headers=headers)
            response = connection.getresponse()
            declared = response.getheader("Content-Length")
            if declared is not None:
                try:
                    length = int(declared)
                except ValueError as error:
                    raise HostFailure("Sunshine API response length is invalid") from error
                if not 0 <= length <= MAX_API_BYTES:
                    raise HostFailure("Sunshine API response is too large")
            raw = response.read(MAX_API_BYTES + 1)
            if response.status != 200:
                raise HostFailure("Sunshine API request failed")
            if len(raw) > MAX_API_BYTES:
                raise HostFailure("Sunshine API response is too large")
            try:
                value = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs)
            except HostFailure:
                raise
            except (UnicodeError, json.JSONDecodeError) as error:
                raise HostFailure("Sunshine API response is invalid") from error
            if not isinstance(value, dict):
                raise HostFailure("Sunshine API response is invalid")
            return value
        except HostFailure:
            raise
        except (OSError, http.client.HTTPException, ssl.SSLError) as error:
            raise HostFailure("Sunshine API request is unavailable") from error
        finally:
            connection.close()

    @staticmethod
    def _pairings(value: Mapping[str, Any]) -> List[Dict[str, str]]:
        if set(value) != {"pairings"} or not isinstance(value["pairings"], list):
            raise HostFailure("Sunshine pending-pairing response is invalid")
        if len(value["pairings"]) > 64:
            raise HostFailure("Sunshine pending-pairing response is too large")
        result: List[Dict[str, str]] = []
        seen = set()
        for item in value["pairings"]:
            if not isinstance(item, dict) or set(item) != {"id", "name", "address"}:
                raise HostFailure("Sunshine pending-pairing response is invalid")
            pairing_id, name, address = item["id"], item["name"], item["address"]
            _pairing_id(pairing_id)
            _validate_client_name(name)
            if not isinstance(address, str) or len(address) > 64:
                raise HostFailure("Sunshine pending-pairing response is invalid")
            try:
                ipaddress.ip_address(address.split("%", 1)[0])
            except ValueError as error:
                raise HostFailure("Sunshine pending-pairing response is invalid") from error
            if pairing_id in seen:
                raise HostFailure("Sunshine pending-pairing response is invalid")
            seen.add(pairing_id)
            result.append({"id": pairing_id, "name": name})
        return result

    @staticmethod
    def _status(value: Mapping[str, Any]) -> None:
        if set(value) != {"status"} or value.get("status") is not True:
            raise HostFailure("Sunshine API operation was not confirmed")

    def pending_pairing(self, expected_name: str) -> Optional[str]:
        _validate_client_name(expected_name)
        matches = [
            item["id"]
            for item in self._pairings(self._request("GET", "/api/pin"))
            if item["name"] == expected_name
        ]
        if len(matches) > 1:
            raise HostFailure("more than one owned pending pairing exists")
        return matches[0] if matches else None

    def approve_pairing(self, pairing_id: str, pin: str, name: str) -> None:
        _pairing_id(pairing_id)
        _validate_client_name(name)
        if not isinstance(pin, str) or re.fullmatch(r"[0-9]{4}", pin) is None:
            raise HostFailure("owned pairing PIN is invalid")
        self._status(
            self._request(
                "POST",
                "/api/pin",
                {"pairing_id": pairing_id, "pin": pin, "name": name},
            )
        )

    def cancel_pairing(self, pairing_id: str) -> None:
        _pairing_id(pairing_id)
        self._status(
            self._request("DELETE", "/api/pin", {"pairing_id": pairing_id})
        )

    def _clients(self) -> List[Dict[str, Any]]:
        value = self._request("GET", "/api/clients/list")
        if set(value) != {"named_certs", "status"} or value.get("status") is not True:
            raise HostFailure("Sunshine client-list response is invalid")
        clients = value["named_certs"]
        if not isinstance(clients, list) or len(clients) > 256:
            raise HostFailure("Sunshine client-list response is invalid")
        result: List[Dict[str, Any]] = []
        seen = set()
        for item in clients:
            if not isinstance(item, dict) or set(item) != {"name", "uuid", "enabled"}:
                raise HostFailure("Sunshine client-list response is invalid")
            _validate_client_name(item["name"])
            _uuid(item["uuid"])
            if not isinstance(item["enabled"], bool) or item["uuid"].lower() in seen:
                raise HostFailure("Sunshine client-list response is invalid")
            seen.add(item["uuid"].lower())
            result.append(dict(item))
        return result

    def owned_client_uuid(self, expected_name: str) -> str:
        _validate_client_name(expected_name)
        matches = [
            item["uuid"]
            for item in self._clients()
            if item["name"] == expected_name and item["enabled"] is True
        ]
        if len(matches) != 1:
            raise HostFailure("owned paired client identity is unavailable")
        return matches[0]

    def require_owned_client_present(self, expected_name: str, client_uuid: str) -> None:
        _validate_client_name(expected_name)
        _uuid(client_uuid)
        matches = [
            item
            for item in self._clients()
            if item["uuid"].lower() == client_uuid.lower()
            and item["name"] == expected_name
            and item["enabled"] is True
        ]
        if len(matches) != 1:
            raise HostFailure("owned paired client identity changed")

    def unpair_owned(self, client_uuid: str) -> None:
        _uuid(client_uuid)
        self._status(
            self._request("POST", "/api/clients/unpair", {"uuid": client_uuid})
        )

    def require_client_absent(self, expected_name: str) -> None:
        _validate_client_name(expected_name)
        if any(item["name"] == expected_name for item in self._clients()):
            raise HostFailure("owned paired client is still present")


def _sunshine_mdns_instance_name(hostname: Optional[str] = None) -> str:
    if hostname is None:
        try:
            hostname = socket.gethostname()
        except OSError as error:
            raise HostFailure("owned runner hostname is unavailable") from error
    if not isinstance(hostname, str):
        raise HostFailure("owned runner hostname is invalid")
    try:
        source = hostname.encode("ascii")[:63]
    except UnicodeEncodeError as error:
        raise HostFailure("owned runner hostname is invalid") from error
    instance = bytearray()
    for value in source:
        if value == 0x20:
            instance.append(0x2D)
        elif (
            0x30 <= value <= 0x39
            or 0x41 <= value <= 0x5A
            or 0x61 <= value <= 0x7A
            or value == 0x2D
        ):
            instance.append(value)
        else:
            break
    return instance.decode("ascii") if instance else "Sunshine"


def verify_mdns(
    raw: str,
    *,
    expected_name: Optional[str] = None,
    expected_interface: Optional[str] = None,
) -> Dict[str, Any]:
    if not isinstance(raw, str) or len(raw.encode("utf-8")) > MAX_MDNS_BYTES:
        raise HostFailure("Sunshine mDNS observation is invalid")
    if expected_name is None:
        expected_name = _sunshine_mdns_instance_name()
    if not isinstance(expected_name, str) or not expected_name:
        raise HostFailure("Sunshine mDNS observation is invalid")
    if expected_interface is not None and re.fullmatch(
        r"[A-Za-z0-9_.-]{1,15}", expected_interface
    ) is None:
        raise HostFailure("Sunshine mDNS observation is invalid")
    resolved = set()
    for line in raw.splitlines():
        fields = line.split(";")
        if len(fields) < 9 or fields[0] != "=":
            continue
        if expected_interface is not None and fields[1] != expected_interface:
            continue
        if (
            fields[4] == "_nvstream._tcp"
            and fields[5] == "local"
            and fields[3] != expected_name
        ):
            raise HostFailure("Sunshine mDNS observation is invalid")
        if (
            fields[3] != expected_name
            or fields[4] != "_nvstream._tcp"
            or fields[5] != "local"
        ):
            continue
        try:
            address = ipaddress.ip_address(fields[7].split("%", 1)[0])
            port = int(fields[8])
        except (ValueError, IndexError) as error:
            raise HostFailure("Sunshine mDNS observation is invalid") from error
        if address.is_unspecified or address.is_multicast or port != GAMESTREAM_PORT:
            raise HostFailure("Sunshine mDNS observation is invalid")
        hostname = fields[6]
        if (
            not isinstance(hostname, str)
            or not 1 <= len(hostname) <= 253
            or any(ord(character) < 33 for character in hostname)
        ):
            raise HostFailure("Sunshine mDNS observation is invalid")
        resolved.add((fields[3], fields[4], fields[5], hostname, port))
    if len(resolved) != 1:
        raise HostFailure("exactly one Sunshine mDNS service was not observed")
    return {"service": "_nvstream._tcp", "port": GAMESTREAM_PORT}


def _default_interface(route: Path = Path("/proc/net/route")) -> str:
    raw = _regular_nofollow(route, maximum=64 * 1024)
    try:
        lines = raw.decode("ascii").splitlines()
    except UnicodeDecodeError as error:
        raise HostFailure("owned runner network identity is invalid") from error
    matches = []
    for line in lines[1:]:
        fields = line.split()
        if len(fields) < 4 or fields[1] != "00000000":
            continue
        interface = fields[0]
        try:
            flags = int(fields[3], 16)
        except ValueError as error:
            raise HostFailure("owned runner network identity is invalid") from error
        if flags & 0x1 and re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", interface):
            matches.append(interface)
    if len(set(matches)) != 1:
        raise HostFailure("owned runner default network interface is unavailable")
    return matches[0]


@dataclass(frozen=True)
class ProcessPlan:
    name: str
    argv: Tuple[str, ...]
    log: Path
    environment: Mapping[str, str] = field(repr=False)


def process_plans(material: HostMaterial) -> Tuple[ProcessPlan, ...]:
    environment = {
        "DISPLAY": DISPLAY,
        "HOME": str(material.home),
        "LANG": "C.UTF-8",
        "PATH": "/usr/bin:/bin",
        "PULSE_SERVER": "unix:" + str(material.runtime / "pulse/native"),
        "XDG_CONFIG_HOME": str(material.root / "xdg-config"),
        "XDG_RUNTIME_DIR": str(material.runtime),
    }
    return (
        ProcessPlan(
            "pulseaudio",
            (
                "/usr/bin/pulseaudio",
                "--daemonize=no",
                "--exit-idle-time=-1",
                "--disallow-exit=yes",
            ),
            material.logs / "pulseaudio.log",
            environment,
        ),
        ProcessPlan(
            "xvfb",
            (
                "/usr/bin/Xvfb",
                DISPLAY,
                "-screen",
                "0",
                "1280x720x24",
                "-nolisten",
                "tcp",
                "-noreset",
            ),
            material.logs / "xvfb.log",
            environment,
        ),
        ProcessPlan(
            "sunshine",
            ("/usr/bin/sunshine", str(material.config)),
            material.logs / "sunshine-process.log",
            environment,
        ),
    )


def _private_runtime_probe_commands(
    material: HostMaterial,
) -> Tuple[Tuple[str, Tuple[str, ...], Mapping[str, str]], ...]:
    base_environment = {
        "HOME": str(material.home),
        "LANG": "C.UTF-8",
        "PATH": "/usr/bin:/bin",
        "XDG_RUNTIME_DIR": str(material.runtime),
    }
    return (
        (
            "pulseaudio",
            (
                "/usr/bin/pactl",
                "--server",
                "unix:" + str(material.runtime / "pulse/native"),
                "info",
            ),
            base_environment,
        ),
        (
            "xvfb",
            ("/usr/bin/xdpyinfo", "-display", DISPLAY),
            {**base_environment, "DISPLAY": DISPLAY},
        ),
    )


def _wait_private_runtime(
    name: str,
    argv: Sequence[str],
    environment: Mapping[str, str],
    processes: "OwnedProcesses",
    *,
    runner: Callable[..., Any] = subprocess.run,
    monotonic: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> None:
    deadline = monotonic() + START_TIMEOUT_SECONDS
    while monotonic() < deadline:
        processes.require_alive()
        try:
            completed = runner(
                list(argv),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=2,
                env=dict(environment),
            )
            if completed.returncode == 0:
                return
        except (OSError, subprocess.TimeoutExpired):
            pass
        sleeper(0.1)
    raise HostFailure("owned " + name + " runtime did not become ready")


class OwnedProcesses:
    def __init__(self) -> None:
        self._items: List[Tuple[str, Any, Optional[Any]]] = []
        self._closed = False

    def add(self, name: str, process: Any, log_handle: Optional[Any] = None) -> None:
        if self._closed or not isinstance(name, str) or not name:
            raise HostFailure("owned process registration is invalid")
        self._items.append((name, process, log_handle))

    def spawn(self, plan: ProcessPlan) -> Any:
        try:
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(str(plan.log), flags, 0o600)
            log_handle = os.fdopen(descriptor, "wb", buffering=0)
            process = subprocess.Popen(
                list(plan.argv),
                stdin=subprocess.DEVNULL,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                cwd=str(plan.log.parent.parent),
                env=dict(plan.environment),
                close_fds=True,
                start_new_session=True,
            )
            self.add(plan.name, process, log_handle)
            return process
        except (OSError, subprocess.SubprocessError) as error:
            raise HostFailure("owned " + plan.name + " process could not start") from error

    def require_alive(self) -> None:
        if not self._items or any(process.poll() is not None for _, process, _ in self._items):
            raise HostFailure("owned host process exited before readiness")

    def stop_sunshine(self) -> None:
        """Stop only the exact Sunshine process group registered by this fixture."""

        matches = [item for item in self._items if item[0] == "sunshine"]
        if len(matches) != 1:
            raise HostFailure("owned Sunshine process identity is invalid")
        _, process, _ = matches[0]
        pid = getattr(process, "pid", None)
        if type(pid) is not int or pid <= 1 or process.poll() is not None:
            raise HostFailure("owned Sunshine process identity is invalid")
        try:
            group = os.getpgid(pid)
            if group != pid:
                raise HostFailure("owned Sunshine process group identity is invalid")
            os.killpg(group, signal.SIGTERM)
            try:
                process.wait(timeout=STOP_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                os.killpg(group, signal.SIGKILL)
                process.wait(timeout=STOP_TIMEOUT_SECONDS)
            if process.poll() is None:
                raise HostFailure("owned Sunshine process did not stop")
        except ProcessLookupError as error:
            raise HostFailure("owned Sunshine process identity is invalid") from error
        except HostFailure:
            raise
        except (OSError, subprocess.SubprocessError) as error:
            raise HostFailure("owned Sunshine process cleanup failed") from error

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        failure = False
        for _, process, handle in reversed(self._items):
            try:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=STOP_TIMEOUT_SECONDS)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=STOP_TIMEOUT_SECONDS)
            except (OSError, subprocess.SubprocessError):
                failure = True
            finally:
                if handle is not None:
                    try:
                        handle.close()
                    except OSError:
                        failure = True
        if failure:
            raise HostFailure("owned host process cleanup failed")


def _generate_certificate(material: HostMaterial) -> str:
    command = [
        "/usr/bin/openssl",
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-sha256",
        "-days",
        "1",
        "-subj",
        "/CN=127.0.0.1",
        "-addext",
        "subjectAltName=IP:127.0.0.1,DNS:localhost",
        "-keyout",
        str(material.private_key),
        "-out",
        str(material.certificate),
    ]
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=20,
            env={"PATH": "/usr/bin:/bin"},
        )
        if completed.returncode != 0:
            raise HostFailure("owned Sunshine TLS identity generation failed")
        os.chmod(material.private_key, 0o600, follow_symlinks=False)
        os.chmod(material.certificate, 0o600, follow_symlinks=False)
        raw = _regular_nofollow(material.certificate, maximum=64 * 1024)
        der = ssl.PEM_cert_to_DER_cert(raw.decode("ascii"))
        return hashlib.sha256(der).hexdigest()
    except HostFailure:
        raise
    except (OSError, UnicodeError, ValueError, ssl.SSLError, subprocess.TimeoutExpired) as error:
        raise HostFailure("owned Sunshine TLS identity generation failed") from error


def _configure_credentials(material: HostMaterial, username: str, password: str) -> None:
    try:
        completed = subprocess.run(
            [
                "/usr/bin/sunshine",
                str(material.config),
                "--creds",
                username,
                password,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=20,
            env={
                "HOME": str(material.home),
                "PATH": "/usr/bin:/bin",
                "XDG_CONFIG_HOME": str(material.root / "xdg-config"),
                "XDG_RUNTIME_DIR": str(material.runtime),
            },
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise HostFailure("Sunshine private web credential setup failed") from error
    if completed.returncode != 0:
        raise HostFailure("Sunshine private web credential setup failed")


def _wait_api(api: SunshineApi, processes: OwnedProcesses) -> None:
    deadline = time.monotonic() + START_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        processes.require_alive()
        try:
            api._clients()
            return
        except HostFailure:
            time.sleep(0.1)
    raise HostFailure("Sunshine pinned API did not become ready")


def _observe_mdns() -> Dict[str, Any]:
    interface = _default_interface()
    output: Any
    try:
        completed = subprocess.run(
            [
                "/usr/bin/avahi-browse",
                "--parsable",
                "--resolve",
                "--terminate",
                "--no-db-lookup",
                "_nvstream._tcp",
            ],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
            env={"LANG": "C.UTF-8", "PATH": "/usr/bin:/bin"},
        )
        if completed.returncode != 0:
            raise HostFailure("Sunshine mDNS browser failed")
        output = completed.stdout
    except subprocess.TimeoutExpired as error:
        output = error.stdout
    except OSError as error:
        raise HostFailure("Sunshine mDNS observation is unavailable") from error
    if isinstance(output, bytes):
        try:
            output = output.decode("utf-8")
        except UnicodeDecodeError as error:
            raise HostFailure("Sunshine mDNS observation is invalid") from error
    if not isinstance(output, str) or len(output.encode("utf-8")) > MAX_MDNS_BYTES:
        raise HostFailure("Sunshine mDNS observation is unavailable")
    if not output:
        raise HostFailure("Sunshine mDNS observation is empty")
    return verify_mdns(
        output,
        expected_name=_sunshine_mdns_instance_name(),
        expected_interface=interface,
    )


@dataclass(repr=False)
class OwnedSunshineHost:
    workspace: PrivateWorkspace
    material: HostMaterial
    processes: OwnedProcesses
    api: SunshineApi
    username: str = field(repr=False)
    password: str = field(repr=False)
    tls_fingerprint: str
    mdns: Mapping[str, Any]

    @classmethod
    def start(
        cls,
        *,
        environment: Mapping[str, str] = os.environ,
        stream_profile: bool = False,
    ) -> "OwnedSunshineHost":
        require_owned_runner(environment)
        if os.geteuid() == 0:
            raise HostFailure("F60 Sunshine fixture must run as the hosted runner user")
        runner_temp = environment.get("RUNNER_TEMP")
        if not runner_temp:
            raise HostFailure("GitHub-hosted runner temp directory is unavailable")
        workspace = PrivateWorkspace.create(Path(runner_temp))
        processes = OwnedProcesses()
        try:
            package = acquire_release(workspace)
            install_release(package)
            username = "f60-" + secrets.token_hex(6)
            password = secrets.token_urlsafe(32)
            material = workspace.write_host_material(
                username=username,
                password=password,
                stream_profile=stream_profile,
            )
            tls_fingerprint = _generate_certificate(material)
            _configure_credentials(material, username, password)
            plans = process_plans(material)
            processes.spawn(plans[0])
            pulse_probe, xvfb_probe = _private_runtime_probe_commands(material)
            _wait_private_runtime(*pulse_probe, processes)
            processes.spawn(plans[1])
            _wait_private_runtime(*xvfb_probe, processes)
            processes.spawn(plans[2])
            processes.require_alive()
            api = SunshineApi(
                username=username,
                password=password,
                certificate=material.certificate,
            )
            _wait_api(api, processes)
            mdns = _observe_mdns()
            processes.require_alive()
            return cls(
                workspace=workspace,
                material=material,
                processes=processes,
                api=api,
                username=username,
                password=password,
                tls_fingerprint=tls_fingerprint,
                mdns=mdns,
            )
        except BaseException:
            try:
                processes.close()
            finally:
                workspace.close()
            raise

    def public_readiness(self) -> Dict[str, Any]:
        self.processes.require_alive()
        return {
            "schemaVersion": 1,
            "provider": "Sunshine",
            "providerTag": SUNSHINE_TAG,
            "packageSha256": SUNSHINE_SHA256,
            "platform": "ubuntu24.04-amd64",
            "capture": "x11",
            "encoder": "software",
            "codec": "h264",
            "tlsCertificateSha256": self.tls_fingerprint,
            "mdns": dict(self.mdns),
            "state": "host_ready",
            "streamAccepted": False,
        }

    def close(self) -> None:
        process_error = None
        try:
            self.processes.close()
        except HostFailure as error:
            process_error = error
        self.workspace.close()
        if process_error is not None:
            raise process_error

    def __enter__(self) -> "OwnedSunshineHost":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Probe an owned pinned Sunshine host; this is not stream acceptance."
    )
    parser.add_argument(
        "--readiness-only",
        action="store_true",
        help="start, observe, emit a secret-free host-ready receipt, and clean up",
    )
    def interrupted(_signum: int, _frame: Any) -> None:
        raise KeyboardInterrupt

    previous_term = signal.signal(signal.SIGTERM, interrupted)
    previous_interrupt = signal.signal(signal.SIGINT, interrupted)
    try:
        try:
            require_owned_runner(os.environ)
            arguments = parser.parse_args(argv)
            if not arguments.readiness_only:
                raise HostFailure("--readiness-only is required")
            with OwnedSunshineHost.start() as owned:
                print(json.dumps(owned.public_readiness(), separators=(",", ":"), sort_keys=True))
            return 0
        except HostFailure as error:
            print("F60 owned Sunshine host: " + str(error), file=sys.stderr)
            return 2
        except KeyboardInterrupt:
            print("F60 owned Sunshine host: interrupted", file=sys.stderr)
            return 130
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_interrupt)


if __name__ == "__main__":
    raise SystemExit(main())
