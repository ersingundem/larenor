"""Revision-bound admin configuration and read-only Thread diagnostics."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import sqlite3
import stat
import threading
from typing import Literal

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import Field

from ..errors import ApiError, StartupError
from ..home_resources.models import FrozenModel, Identity, Revision
from .thread_diagnostics import (
    HomeAssistantThreadDiagnosticsTransport,
    ThreadDiagnosticsError,
)

MAGIC = b"LARENOR-THREAD-DIAGNOSTICS-1\0"
AAD = b"larenor:thread-diagnostics-binding:v1"
MAX_STATE_BYTES = 16 * 1024


class ThreadServiceOption(FrozenModel):
    schemaVersion: Literal[1]
    serviceId: Identity
    serviceRevision: Revision
    name: str = Field(min_length=1, max_length=80)


class ThreadDiagnosticsBinding(FrozenModel):
    schemaVersion: Literal[1]
    revision: Revision
    coreId: Identity
    homeId: Identity
    serviceId: Identity
    serviceRevision: Revision


class ThreadDiagnosticsBindingInput(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Revision | None
    serviceId: Identity
    expectedServiceRevision: Revision


class ThreadDiagnosticsConfiguration(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    binding: ThreadDiagnosticsBinding | None
    services: list[ThreadServiceOption] = Field(max_length=128)


class ThreadDatasetSummary(FrozenModel):
    schemaVersion: Literal[1]
    datasetId: Identity
    networkName: str = Field(min_length=1, max_length=64)
    channel: int = Field(ge=11, le=26)
    preferred: bool
    source: str = Field(min_length=1, max_length=64)


class ThreadRouterSummary(FrozenModel):
    schemaVersion: Literal[1]
    routerId: Identity
    networkName: str | None = Field(default=None, max_length=64)
    brand: str | None = Field(default=None, max_length=64)
    modelName: str | None = Field(default=None, max_length=64)
    threadVersion: str | None = Field(default=None, max_length=32)
    vendorName: str | None = Field(default=None, max_length=64)
    unconfigured: bool | None


class ThreadDiagnosticsSnapshot(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    bindingRevision: Revision
    serviceId: Identity
    serviceRevision: Revision
    capturedAtMs: int = Field(ge=0, le=2**63 - 1)
    readOnly: Literal[True]
    datasets: list[ThreadDatasetSummary] = Field(max_length=64)
    routers: list[ThreadRouterSummary] = Field(max_length=128)


class _BindingStore:
    def __init__(self, path, key):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._key = hmac.new(
            key, b"thread-diagnostics-binding-v1", hashlib.sha256
        ).digest()
        self.output_key = hmac.new(
            key, b"thread-diagnostics-output-v1", hashlib.sha256
        ).digest()
        self._cipher = AESGCM(self._key)
        if self.path.exists():
            self.load()

    def load(self):
        if not self.path.exists():
            return None
        try:
            descriptor = os.open(
                self.path,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            with os.fdopen(descriptor, "rb") as stream:
                metadata = os.fstat(stream.fileno())
                if (
                    not stat.S_ISREG(metadata.st_mode)
                    or not 1 <= metadata.st_size <= MAX_STATE_BYTES
                ):
                    raise ValueError
                payload = stream.read(MAX_STATE_BYTES + 1)
            start = len(MAGIC)
            if (
                not payload.startswith(MAGIC)
                or len(payload) <= start + 28
                or len(payload) > MAX_STATE_BYTES
            ):
                raise ValueError
            plain = self._cipher.decrypt(
                payload[start : start + 12], payload[start + 12 :], AAD
            )
            value = ThreadDiagnosticsBinding.model_validate_json(plain)
            if value.model_dump_json().encode() != plain:
                raise ValueError
            return value
        except (InvalidTag, OSError, ValueError, TypeError):
            raise StartupError("thread_diagnostics_storage_invalid") from None

    def save(self, value):
        temporary = None
        try:
            plain = value.model_dump_json().encode()
            if not 1 <= len(plain) <= MAX_STATE_BYTES:
                raise ValueError
            nonce = secrets.token_bytes(12)
            payload = MAGIC + nonce + self._cipher.encrypt(nonce, plain, AAD)
            temporary = self.path.with_name(
                f".{self.path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
            )
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
                0o600,
            )
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            os.chmod(self.path, 0o600)
            directory = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except (OSError, ValueError, TypeError):
            raise ApiError("thread_diagnostics_unavailable", 503) from None
        finally:
            if temporary is not None:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass


class ThreadDiagnosticsService:
    def __init__(self, db, auth, services, context, key, data_dir, *, transport=None):
        self._db = db
        self._auth = auth
        self._services_resolver = services if callable(services) else lambda: services
        self._core_id = context.coreId
        self._home_id = context.homeId
        self._store = _BindingStore(
            Path(data_dir) / "thread-diagnostics-binding.state", key
        )
        self._lock = threading.RLock()
        self._binding = self._store.load()
        if self._binding is not None and (
            self._binding.coreId != self._core_id
            or self._binding.homeId != self._home_id
        ):
            raise StartupError("thread_diagnostics_storage_invalid")
        self._transport = transport or HomeAssistantThreadDiagnosticsTransport

    @property
    def _services(self):
        services = self._services_resolver()
        if not callable(getattr(services, "list", None)):
            raise ApiError("thread_diagnostics_unavailable", 503)
        return services

    def _admin(self, connection, actor):
        self._auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT role,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if row is None:
            raise ApiError("invalid_session", 401)
        if row["disabled"] or row["must_change_password"]:
            raise ApiError("forbidden", 403)
        if row["role"] != "admin":
            raise ApiError("forbidden", 403)

    def _connection(self, connection, service_id, service_revision):
        row, record = self._services._record(
            connection, service_id, service_revision
        )
        if (
            record["kind"] != "home_assistant"
            or set(record["credentials"]) != {"token"}
            or record["verification"]["state"] != "authenticated"
        ):
            raise ApiError("thread_diagnostics_binding_changed", 409)
        return self._services._private(row, record)

    def configuration(self, actor):
        public = self._services.list(actor)["services"]
        options = [
            ThreadServiceOption(
                schemaVersion=1,
                serviceId=value["id"],
                serviceRevision=value["revision"],
                name=value["name"],
            )
            for value in public
            if value["kind"] == "home_assistant"
            and value["credentialKeys"] == ["token"]
            and value["verification"]["state"] == "authenticated"
        ]
        with self._lock:
            binding = self._binding
        return ThreadDiagnosticsConfiguration(
            schemaVersion=1,
            coreId=self._core_id,
            homeId=self._home_id,
            binding=binding,
            services=options,
        )

    def configure(self, actor, raw):
        try:
            body = ThreadDiagnosticsBindingInput.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            with self._db.transaction() as connection:
                self._admin(connection, actor)
                self._connection(
                    connection, body.serviceId, body.expectedServiceRevision
                )
                with self._lock:
                    current = self._binding
                    if (current is None) != (body.expectedRevision is None):
                        raise ApiError("revision_conflict", 409)
                    if current is not None and current.revision != body.expectedRevision:
                        raise ApiError("revision_conflict", 409)
                    revision = 1 if current is None else current.revision + 1
                    if revision > 2**63 - 1:
                        raise ApiError("revision_conflict", 409)
                    binding = ThreadDiagnosticsBinding(
                        schemaVersion=1,
                        revision=revision,
                        coreId=self._core_id,
                        homeId=self._home_id,
                        serviceId=body.serviceId,
                        serviceRevision=body.expectedServiceRevision,
                    )
                    self._store.save(binding)
                    self._binding = binding
                    return binding
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("thread_diagnostics_unavailable", 503) from None

    def _live(self, actor, expected):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            self._admin(connection, actor)
            service = self._connection(
                connection, expected.serviceId, expected.serviceRevision
            )
        with self._lock:
            if self._binding != expected:
                raise ApiError("thread_diagnostics_binding_changed", 409)
        return service

    def observe(self, actor, core_id, home_id):
        if (core_id, home_id) != (self._core_id, self._home_id):
            raise ApiError("not_found", 404)
        with self._lock:
            binding = self._binding
        if binding is None:
            raise ApiError("thread_diagnostics_not_configured", 409)
        service = self._live(actor, binding)

        def guard():
            try:
                current = self._live(actor, binding)
            except ApiError:
                raise ThreadDiagnosticsError("authority_changed") from None
            if (
                current.id,
                current.revision,
                current.base_url,
            ) != (service.id, service.revision, service.base_url):
                raise ThreadDiagnosticsError("authority_changed")

        try:
            raw = self._transport(service).observe(
                before_io=guard,
                after_io=guard,
            )
        except ThreadDiagnosticsError as error:
            if error.code == "authority_changed":
                raise ApiError("thread_diagnostics_binding_changed", 409) from None
            if error.code == "unauthorized":
                raise ApiError("thread_diagnostics_unauthorized", 502) from None
            if error.code == "unsupported":
                raise ApiError("thread_diagnostics_unsupported", 409) from None
            raise ApiError("thread_diagnostics_unavailable", 503) from None

        def opaque(kind, value):
            return hmac.new(
                self._store.output_key,
                f"{kind}:{value}".encode(),
                hashlib.sha256,
            ).hexdigest()[:32]

        return ThreadDiagnosticsSnapshot(
            schemaVersion=1,
            coreId=self._core_id,
            homeId=self._home_id,
            bindingRevision=binding.revision,
            serviceId=binding.serviceId,
            serviceRevision=binding.serviceRevision,
            capturedAtMs=raw.capturedAtMs,
            readOnly=True,
            datasets=[
                ThreadDatasetSummary(
                    schemaVersion=1,
                    datasetId=opaque("dataset", value.datasetId),
                    networkName=value.networkName,
                    channel=value.channel,
                    preferred=value.preferred,
                    source=value.source,
                )
                for value in raw.datasets
            ],
            routers=[
                ThreadRouterSummary(
                    schemaVersion=1,
                    routerId=opaque("router", value.routerId),
                    networkName=value.networkName,
                    brand=value.brand,
                    modelName=value.modelName,
                    threadVersion=value.threadVersion,
                    vendorName=value.vendorName,
                    unconfigured=value.unconfigured,
                )
                for value in raw.routers
            ],
        )
