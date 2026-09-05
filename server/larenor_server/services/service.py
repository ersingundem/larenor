from collections.abc import Mapping
from contextlib import contextmanager
from dataclasses import dataclass, field
import json
import re
import secrets
from types import MappingProxyType
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..auth import AuthService, Principal
from ..config import Settings
from ..database import Database
from ..errors import ApiError, StartupError
from .models import CreateServiceRequest, ServiceVerification, StoredService, UpdateServiceRequest


MAX_SERVICES = 128
MAX_AUDIT_EVENTS = 10000
NEVER = {"state": "never", "checkedAt": None, "version": None}


@dataclass(frozen=True)
class ServiceConnection:
    id: str
    name: str
    kind: str
    base_url: str
    revision: int
    credentials: Mapping[str, str] = field(repr=False)


class ServiceManagement:
    def __init__(self, db: Database, auth: AuthService, settings: Settings, key: bytes):
        self.db, self.auth, self.settings = db, auth, settings
        self._cipher = AESGCM(key)

    @staticmethod
    def _aad(service_id: str, revision: int) -> bytes:
        return f"larenor:service-connections:schema=1:id={service_id}:revision={revision}".encode("ascii")

    @staticmethod
    def _identity(service_id: str, revision: int | None = None):
        if (not isinstance(service_id, str) or not re.fullmatch(r"[0-9a-f]{32}", service_id) or
                revision is not None and (type(revision) is not int or not 1 <= revision <= 2**63 - 1)):
            raise ApiError("invalid_request")

    def _assert_admin(self, connection, actor: Principal):
        self.auth.assert_current(connection, actor)
        if actor.must_change_password:
            raise ApiError("password_change_required", 403)
        if actor.role != "admin":
            raise ApiError("forbidden", 403)

    @contextmanager
    def _read(self, actor: Principal):
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            yield connection

    @contextmanager
    def _mutation(self, actor: Principal, action: str, target_id: str):
        error = None
        with self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            connection.execute("SAVEPOINT service_action")
            try:
                yield connection
            except ApiError as caught:
                connection.execute("ROLLBACK TO service_action")
                error = caught
            connection.execute("RELEASE service_action")
            connection.execute("INSERT INTO service_audit(event,action,status,timestamp,actor_id,target_id) VALUES(?,?,?,?,?,?)",
                               (f"admin.service.{action}", action, "denied" if error else "success",
                                self.settings.clock(), actor.id, target_id))
            connection.execute("DELETE FROM service_audit WHERE id IN (SELECT id FROM service_audit ORDER BY id DESC LIMIT -1 OFFSET ?)",
                               (MAX_AUDIT_EVENTS,))
        if error:
            raise error

    def _decode(self, row) -> dict:
        try:
            self._identity(row["id"], row["revision"])
            if len(row["ciphertext"]) > 32768:
                raise ValueError()
            plain = self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row["id"], row["revision"]))
            return StoredService.model_validate_json(plain).model_dump()
        except (InvalidTag, ValueError, TypeError, ApiError):
            raise ApiError("service_unavailable", 503) from None

    def _save(self, connection, service_id: str, revision: int, record: dict):
        nonce = secrets.token_bytes(12)
        encoded = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ciphertext = self._cipher.encrypt(nonce, encoded, self._aad(service_id, revision))
        connection.execute("INSERT INTO service_connections(id,revision,nonce,ciphertext) VALUES(?,?,?,?) "
                           "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,nonce=excluded.nonce,ciphertext=excluded.ciphertext",
                           (service_id, revision, nonce, ciphertext))

    def _record(self, connection, service_id: str, expected_revision: int | None = None):
        self._identity(service_id, expected_revision)
        row = connection.execute("SELECT * FROM service_connections WHERE id=?", (service_id,)).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        record = self._decode(row)
        if expected_revision is not None and row["revision"] != expected_revision:
            raise ApiError("revision_conflict", 409)
        return row, record

    @staticmethod
    def _public(service_id: str, revision: int, record: dict) -> dict:
        return {"id": service_id, "revision": revision, "name": record["name"], "kind": record["kind"],
                "baseUrl": record["baseUrl"], "credentialKeys": sorted(record["credentials"]),
                "verification": dict(record["verification"])}

    @staticmethod
    def _private(row, record) -> ServiceConnection:
        return ServiceConnection(id=row["id"], revision=row["revision"], name=record["name"], kind=record["kind"],
                                 base_url=record["baseUrl"], credentials=MappingProxyType(dict(record["credentials"])))

    def validate_storage(self):
        try:
            self.configured_connections()
        except ApiError:
            raise StartupError("invalid_services_storage") from None

    def configured_connections(self) -> tuple[ServiceConnection, ...]:
        """Trusted packaged workers only; never expose credentials through an API."""
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            rows = connection.execute("SELECT * FROM service_connections ORDER BY id LIMIT ?", (MAX_SERVICES + 1,)).fetchall()
            if len(rows) > MAX_SERVICES:
                raise ApiError("service_unavailable", 503)
            return tuple(self._private(row, self._decode(row)) for row in rows)

    def connection(self, actor: Principal, service_id: str, expected_revision: int | None = None) -> ServiceConnection:
        with self._read(actor) as connection:
            row, record = self._record(connection, service_id, expected_revision)
            return self._private(row, record)

    def list(self, actor: Principal) -> dict:
        with self._read(actor) as connection:
            rows = connection.execute("SELECT * FROM service_connections ORDER BY id LIMIT ?", (MAX_SERVICES + 1,)).fetchall()
            if len(rows) > MAX_SERVICES:
                raise ApiError("service_unavailable", 503)
            records = [self._public(row["id"], row["revision"], self._decode(row)) for row in rows]
        return {"services": sorted(records, key=lambda item: (item["name"].casefold(), item["id"]))}

    def create(self, actor: Principal, body: CreateServiceRequest) -> dict:
        service_id = uuid.uuid4().hex
        record = {**body.model_dump(), "verification": dict(NEVER)}
        with self._mutation(actor, "create", service_id) as connection:
            if connection.execute("SELECT COUNT(*) FROM service_connections").fetchone()[0] >= MAX_SERVICES:
                raise ApiError("service_limit_reached", 409)
            self._save(connection, service_id, 1, record)
        return {"service": self._public(service_id, 1, record)}

    def update(self, actor: Principal, service_id: str, body: UpdateServiceRequest) -> dict:
        self._identity(service_id, body.expectedRevision)
        with self._mutation(actor, "update", service_id) as connection:
            row, record = self._record(connection, service_id, body.expectedRevision)
            changed_endpoint = body.baseUrl != record["baseUrl"]
            if changed_endpoint and body.credentials is None:
                raise ApiError("service_credentials_required")
            credentials = record["credentials"] if body.credentials is None else dict(body.credentials)
            changed_connection = changed_endpoint or credentials != record["credentials"]
            changed = changed_connection or body.name != record["name"]
            revision = row["revision"]
            if changed:
                if revision >= 2**63 - 1:
                    raise ApiError("revision_conflict", 409)
                revision += 1
                record = {**record, "name": body.name, "baseUrl": body.baseUrl, "credentials": credentials,
                          "verification": dict(NEVER) if changed_connection else record["verification"]}
                self._save(connection, service_id, revision, record)
        return {"service": self._public(service_id, revision, record)}

    def delete(self, actor: Principal, service_id: str, expected_revision: int) -> None:
        self._identity(service_id, expected_revision)
        with self._mutation(actor, "delete", service_id) as connection:
            self._record(connection, service_id, expected_revision)
            connection.execute("DELETE FROM service_connections WHERE id=?", (service_id,))

    def record_verification(self, actor: Principal, service_id: str, expected_revision: int, *,
                            state: str, version: str | None = None) -> dict:
        self._identity(service_id, expected_revision)
        try:
            verification = ServiceVerification(state=state, checkedAt=utc(self.settings.clock()), version=version).model_dump()
        except ValidationError:
            raise ApiError("invalid_request") from None
        with self._mutation(actor, "check", service_id) as connection:
            row, record = self._record(connection, service_id, expected_revision)
            if version is not None and any(secret in version for secret in record["credentials"].values()):
                verification["version"] = None
            record = {**record, "verification": verification}
            self._save(connection, service_id, row["revision"], record)
        return {"service": self._public(service_id, row["revision"], record)}
