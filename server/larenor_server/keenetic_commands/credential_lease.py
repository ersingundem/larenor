"""Short-lived encrypted service binding leases for a Keenetic worker."""

import base64
import hashlib
import json
import math
import secrets
from typing import Literal
from urllib.parse import urlsplit

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import Field, ValidationError

from ..errors import ApiError
from ..home_resources.models import FrozenModel
from .models import TargetState


_AAD = b"larenor-keenetic-credential-lease-v1"
_MAX_LEASES = 128


class KeeneticLeaseError(ValueError):
    def __init__(self):
        super().__init__("keenetic_lease_invalid")


class KeeneticCredentialLease(FrozenModel):
    schemaVersion: Literal[1]
    token: str = Field(
        min_length=80,
        max_length=16384,
        pattern=r"^[A-Za-z0-9_-]+$",
        repr=False,
    )


def _now(clock):
    value = clock()
    if type(value) not in {int, float} or not math.isfinite(value):
        raise KeeneticLeaseError()
    return float(value)


def _encode(value):
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _decode(value):
    if not isinstance(value, str) or not value or len(value) > 16384:
        raise KeeneticLeaseError()
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except Exception:
        raise KeeneticLeaseError() from None
    if _encode(raw) != value:
        raise KeeneticLeaseError()
    return raw


class KeeneticCredentialLeaseIssuer:
    def __init__(self, services, key, *, clock):
        if not isinstance(key, bytes) or len(key) != 32 or not callable(clock):
            raise KeeneticLeaseError()
        self._services = services
        self._cipher = AESGCM(key)
        self._clock = clock
        self._last_clock = None

    def issue(self, actor, expected, *, worker_id, ttl_seconds=10):
        try:
            expected = TargetState.model_validate(expected)
            if (
                not isinstance(worker_id, str)
                or len(worker_id) != 32
                or any(char not in "0123456789abcdef" for char in worker_id)
                or type(ttl_seconds) is not int
                or not 1 <= ttl_seconds <= 30
            ):
                raise ValueError
            now = _now(self._clock)
            if now < 0 or self._last_clock is not None and now < self._last_clock:
                raise ValueError
            self._last_clock = now
            connection = self._services.connection(
                actor, expected.serviceId, expected.serviceRevision
            )
            endpoint = urlsplit(connection.base_url)
            if (
                connection.kind != "keenetic"
                or connection.id != expected.serviceId
                or connection.revision != expected.serviceRevision
                or set(connection.credentials) != {"username", "password"}
                or endpoint.scheme not in {"http", "https"}
                or endpoint.hostname is None
                or endpoint.username is not None
                or endpoint.password is not None
                or endpoint.path not in {"", "/"}
                or endpoint.query
                or endpoint.fragment
                or not all(isinstance(connection.credentials[key], str)
                           and connection.credentials[key]
                           for key in ("username", "password"))
            ):
                raise ValueError
            payload = {
                "version": 1,
                "workerId": worker_id,
                "issuedAt": now,
                "expiresAt": now + ttl_seconds,
                "nonce": secrets.token_hex(16),
                "target": expected.model_dump(mode="json"),
                "service": {
                    "id": connection.id,
                    "revision": connection.revision,
                    "baseUrl": connection.base_url,
                    "username": connection.credentials["username"],
                    "password": connection.credentials["password"],
                },
            }
            plain = json.dumps(
                payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            if len(plain) > 8192:
                raise ValueError
            nonce = secrets.token_bytes(12)
            token = _encode(nonce + self._cipher.encrypt(nonce, plain, _AAD))
            return KeeneticCredentialLease(schemaVersion=1, token=token)
        except (ApiError, AttributeError, KeyError, TypeError, ValueError, KeeneticLeaseError):
            raise KeeneticLeaseError() from None


class LeasedServiceConnection:
    """Mutable private buffers are overwritten when the lease is released."""

    __slots__ = ("service_id", "service_revision", "_buffers", "_closed")

    def __init__(self, service_id, service_revision, endpoint, username, password):
        self.service_id = service_id
        self.service_revision = service_revision
        self._buffers = tuple(bytearray(value.encode("utf-8")) for value in (
            endpoint, username, password
        ))
        self._closed = False

    def __repr__(self):
        return "LeasedServiceConnection(<private>)"

    def _text(self, index):
        if self._closed:
            raise KeeneticLeaseError()
        try:
            return self._buffers[index].decode("utf-8")
        except UnicodeDecodeError:
            raise KeeneticLeaseError() from None

    def endpoint_text(self):
        return self._text(0)

    def username_text(self):
        return self._text(1)

    def password_text(self):
        return self._text(2)

    def close(self):
        if not self._closed:
            for buffer in self._buffers:
                buffer[:] = b"\0" * len(buffer)
            self._closed = True

    def __enter__(self):
        if self._closed:
            raise KeeneticLeaseError()
        return self

    def __exit__(self, *_):
        self.close()


class KeeneticCredentialLeaseVerifier:
    def __init__(self, key, *, worker_id, clock):
        if (
            not isinstance(key, bytes)
            or len(key) != 32
            or not isinstance(worker_id, str)
            or len(worker_id) != 32
            or any(char not in "0123456789abcdef" for char in worker_id)
            or not callable(clock)
        ):
            raise KeeneticLeaseError()
        self._cipher = AESGCM(key)
        self._worker_id = worker_id
        self._clock = clock
        self._last_clock = None
        self._spent = set()

    def open(self, lease, expected):
        try:
            lease = KeeneticCredentialLease.model_validate(lease)
            expected = TargetState.model_validate(expected)
            now = _now(self._clock)
            if now < 0 or self._last_clock is not None and now < self._last_clock:
                raise ValueError
            self._last_clock = now
            digest = hashlib.sha256(lease.token.encode("ascii")).digest()
            if digest in self._spent or len(self._spent) >= _MAX_LEASES:
                raise ValueError
            raw = _decode(lease.token)
            if len(raw) < 29:
                raise ValueError
            nonce, ciphertext = raw[:12], raw[12:]
            plain = self._cipher.decrypt(nonce, ciphertext, _AAD)
            if len(plain) > 8192:
                raise ValueError
            payload = json.loads(plain.decode("utf-8"))
            if (
                type(payload) is not dict
                or set(payload) != {
                    "version", "workerId", "issuedAt", "expiresAt", "nonce",
                    "target", "service",
                }
                or payload["version"] != 1
                or payload["workerId"] != self._worker_id
                or type(payload["issuedAt"]) not in {int, float}
                or type(payload["expiresAt"]) not in {int, float}
                or not payload["issuedAt"] <= now < payload["expiresAt"]
                or not 0 < payload["expiresAt"] - payload["issuedAt"] <= 30
                or not isinstance(payload["nonce"], str)
                or not _full_hex(payload["nonce"], 32)
                or TargetState.model_validate(payload["target"]) != expected
            ):
                raise ValueError
            service = payload["service"]
            endpoint = urlsplit(service.get("baseUrl", "")) if isinstance(service, dict) else None
            if (
                type(service) is not dict
                or set(service) != {"id", "revision", "baseUrl", "username", "password"}
                or service["id"] != expected.serviceId
                or service["revision"] != expected.serviceRevision
                or not all(isinstance(service[key], str) for key in (
                    "baseUrl", "username", "password"
                ))
                or endpoint.scheme not in {"http", "https"}
                or endpoint.hostname is None
                or endpoint.username is not None
                or endpoint.password is not None
                or endpoint.path not in {"", "/"}
                or endpoint.query
                or endpoint.fragment
            ):
                raise ValueError
            result = LeasedServiceConnection(
                service["id"], service["revision"], service["baseUrl"],
                service["username"], service["password"],
            )
            self._spent.add(digest)
            return result
        except (
            InvalidTag, UnicodeDecodeError, json.JSONDecodeError, TypeError,
            ValueError, ValidationError, KeeneticLeaseError,
        ):
            raise KeeneticLeaseError() from None


def _full_hex(value, length):
    return (
        len(value) == length
        and all(char in "0123456789abcdef" for char in value)
    )
