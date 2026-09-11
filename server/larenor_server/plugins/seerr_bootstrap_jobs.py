"""Encrypted durable Seerr bootstrap intent over one verified Jellyfin source."""

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import os
import re
import secrets
import sqlite3
import stat
import time
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .seerr_bootstrap_job_models import (
    CreateSeerrBootstrapRequest,
    PrivateSeerrBootstrapPayload,
    SeerrBootstrapJob,
)
from .catalog import load_catalog
from .seerr_bootstrap_executor import (
    SeerrBootstrapExecutionError,
    SeerrBootstrapExecutionResult,
)
from .seerr_bootstrap_models import PrivateSeerrBootstrap
from .seerr_bootstrap_models import PrivateSeerrArrBinding
from .stack_plan import verify_media_stack_plan


MAX_BOOTSTRAPS = 256
MAX_CIPHERTEXT = 8192
_BINDING = (
    "id",
    "sequence",
    "revision",
    "actor_id",
    "actor_revision",
    "family_id",
    "request_id",
    "installation_id",
    "installation_revision",
    "source_bootstrap_id",
    "source_bootstrap_revision",
    "state",
    "phase",
    "error_code",
    "created_at",
    "updated_at",
)


@dataclass(frozen=True, repr=False)
class _PrivateView:
    credential: str
    sourceBootstrapId: str
    sourceBootstrapRevision: int
    api_key: str | None

    def __repr__(self):
        return "_PrivateView(<private>)"


def _identifier(value):
    if type(value) is not str or re.fullmatch(r"[0-9a-f]{32}", value) is None:
        raise ApiError("invalid_request")


def _request(value):
    try:
        if isinstance(value, CreateSeerrBootstrapRequest):
            value = value.model_dump(mode="python")
        return CreateSeerrBootstrapRequest.model_validate(value)
    except (ValidationError, ValueError, TypeError, AttributeError):
        raise ApiError("invalid_request") from None


class SeerrBootstrapManagement:
    def __init__(
        self,
        db,
        auth,
        settings,
        key,
        installations,
        jellyfin_bootstraps,
        arr_configurations=None,
    ):
        self.db, self.auth, self.settings = db, auth, settings
        self.installations = installations
        self.jellyfin_bootstraps = jellyfin_bootstraps
        self.arr_configurations = arr_configurations
        self._cipher = AESGCM(key)

    def _assert_admin(self, connection, actor):
        return self.installations._assert_admin(connection, actor)

    @staticmethod
    def _aad(row):
        return b"larenor:media:seerr-bootstraps:schema=1:" + json.dumps(
            {key: row[key] for key in _BINDING},
            sort_keys=True,
            separators=(",", ":"),
        ).encode("ascii")

    @staticmethod
    def _public(row, payload=None):
        try:
            return SeerrBootstrapJob.model_validate(
                {
                    "id": row["id"],
                    "requestId": row["request_id"],
                    "installationId": row["installation_id"],
                    "sourceBootstrapId": row["source_bootstrap_id"],
                    "sourceBootstrapRevision": row["source_bootstrap_revision"],
                    "serviceId": "seerr",
                    "revision": row["revision"],
                    "state": row["state"],
                    "phase": row["phase"],
                    "errorCode": row["error_code"],
                    "installAvailable": False,
                    "convergencePhase": (
                        payload.convergencePhase if payload is not None else "queued"
                    ),
                    "arrWired": bool(
                        payload is not None and payload.arrInstanceIds is not None
                    ),
                    "initialized": bool(payload is not None and payload.initialized),
                    "createdAt": utc(row["created_at"]),
                    "updatedAt": utc(row["updated_at"]),
                }
            ).model_dump()
        except (ValidationError, ValueError, TypeError, AttributeError):
            raise ApiError("seerr_bootstrap_storage_unavailable", 503) from None

    def _decode(self, row):
        try:
            if (
                len(row["nonce"]) != 12
                or not 16 <= len(row["ciphertext"]) <= MAX_CIPHERTEXT
                or any(
                    type(row[key]) is not int or not 1 <= row[key] <= 2**63 - 2
                    for key in (
                        "sequence",
                        "revision",
                        "actor_revision",
                        "installation_revision",
                        "source_bootstrap_revision",
                    )
                )
                or any(
                    type(row[key]) is not str
                    or re.fullmatch(r"[0-9a-f]{32}", row[key]) is None
                    for key in (
                        "id",
                        "actor_id",
                        "family_id",
                        "request_id",
                        "installation_id",
                        "source_bootstrap_id",
                    )
                )
            ):
                raise ValueError()
            payload = PrivateSeerrBootstrapPayload.model_validate_json(
                self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row))
            )
            private = payload.private
            if (
                private.sourceBootstrapId != row["source_bootstrap_id"]
                or private.sourceBootstrapRevision != row["source_bootstrap_revision"]
            ):
                raise ValueError()
            self._public(row, payload)
            return payload
        except (
            InvalidTag,
            ValidationError,
            ValueError,
            TypeError,
            AttributeError,
            KeyError,
            OverflowError,
        ):
            raise ApiError("seerr_bootstrap_storage_unavailable", 503) from None

    def _validate_row(self, connection, row):
        payload = self._decode(row)
        private = payload.private
        installation = connection.execute(
            "SELECT * FROM media_installations WHERE id=?", (row["installation_id"],)
        ).fetchone()
        source = connection.execute(
            "SELECT * FROM media_service_bootstraps WHERE id=?",
            (row["source_bootstrap_id"],),
        ).fetchone()
        try:
            if installation is None or source is None:
                raise ValueError()
            installed = self.installations._decode(installation)
            source_private = self.jellyfin_bootstraps._decode(source)
            source_installation = connection.execute(
                "SELECT * FROM media_installations WHERE id=?",
                (source["installation_id"],),
            ).fetchone()
            if (
                source_installation is None
                or installation["revision"] != row["installation_revision"]
                or installation["state"] != "container_started"
                or installation["phase"] != "complete"
                or installed.request.serviceId != "seerr"
                or source["revision"] != row["source_bootstrap_revision"]
                or source["state"] not in {"wiring_partial", "succeeded"}
                or source["credentials_configured"] != 1
                or source_private.readback is None
                or source_installation["preparation_id"] != installation["preparation_id"]
                or any(
                    item != row[column]
                    for item, column in (
                        (installation["actor_id"], "actor_id"),
                        (installation["actor_revision"], "actor_revision"),
                        (installation["family_id"], "family_id"),
                        (source["actor_id"], "actor_id"),
                        (source["actor_revision"], "actor_revision"),
                        (source["family_id"], "family_id"),
                    )
                )
            ):
                raise ValueError()
            if private.arrBindings:
                self._validate_arr_bindings(connection, installation, private.arrBindings)
            return payload
        except (ApiError, ValidationError, ValueError, TypeError, AttributeError):
            raise ApiError("seerr_bootstrap_storage_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                rows = connection.execute(
                    "SELECT * FROM media_seerr_bootstraps LIMIT ?", (MAX_BOOTSTRAPS + 1,)
                ).fetchall()
                if len(rows) > MAX_BOOTSTRAPS:
                    raise ValueError()
                for row in rows:
                    self._validate_row(connection, row)
        except (ApiError, ValueError, sqlite3.Error):
            raise StartupError("invalid_media_seerr_bootstraps_storage") from None

    def create(self, actor, body):
        body = _request(body)
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            previous = connection.execute(
                "SELECT * FROM media_seerr_bootstraps WHERE actor_id=? AND request_id=?",
                (actor.id, body.requestId),
            ).fetchone()
            if previous is not None:
                if (
                    previous["installation_id"] != body.installationId
                    or previous["installation_revision"]
                    != body.expectedInstallationRevision
                    or previous["source_bootstrap_id"] != body.sourceBootstrapId
                    or previous["source_bootstrap_revision"]
                    != body.expectedSourceBootstrapRevision
                ):
                    raise ApiError("seerr_bootstrap_conflict", 409)
                self._validate_row(connection, previous)
                return {"bootstrap": self._public(previous, self._decode(previous))}
            installation = connection.execute(
                "SELECT * FROM media_installations WHERE id=?", (body.installationId,)
            ).fetchone()
            source = connection.execute(
                "SELECT * FROM media_service_bootstraps WHERE id=?",
                (body.sourceBootstrapId,),
            ).fetchone()
            if installation is None:
                raise ApiError("seerr_installation_changed", 409)
            if source is None or source["revision"] != body.expectedSourceBootstrapRevision:
                raise ApiError("seerr_bootstrap_source_changed", 409)
            try:
                installed = self.installations._decode(installation)
                source_private = self.jellyfin_bootstraps._decode(source)
                source_installation = connection.execute(
                    "SELECT * FROM media_installations WHERE id=?",
                    (source["installation_id"],),
                ).fetchone()
                if (
                    installation["revision"] != body.expectedInstallationRevision
                    or installation["state"] != "container_started"
                    or installation["phase"] != "complete"
                    or installed.request.serviceId != "seerr"
                    or source_installation is None
                    or source_installation["preparation_id"]
                    != installation["preparation_id"]
                    or source["state"] not in {"wiring_partial", "succeeded"}
                    or source["credentials_configured"] != 1
                    or source_private.readback is None
                    or any(
                        value != expected
                        for value, expected in (
                            (installation["actor_id"], actor.id),
                            (installation["actor_revision"], actor_revision),
                            (installation["family_id"], actor.family_id),
                            (source["actor_id"], actor.id),
                            (source["actor_revision"], actor_revision),
                            (source["family_id"], actor.family_id),
                        )
                    )
                ):
                    raise ValueError()
            except (ApiError, ValidationError, ValueError, TypeError, AttributeError):
                code = (
                    "seerr_installation_changed"
                    if installed.request.serviceId != "seerr"
                    else "seerr_bootstrap_source_changed"
                ) if "installed" in locals() else "seerr_installation_changed"
                raise ApiError(code, 409) from None
            if connection.execute(
                "SELECT 1 FROM media_seerr_bootstraps WHERE installation_id=?",
                (body.installationId,),
            ).fetchone() is not None:
                raise ApiError("seerr_bootstrap_conflict", 409)
            if connection.execute(
                "SELECT COUNT(*) FROM media_seerr_bootstraps"
            ).fetchone()[0] >= MAX_BOOTSTRAPS:
                raise ApiError("seerr_bootstrap_limit_reached", 409)
            now = int(self.settings.clock())
            row = {
                "id": uuid.uuid4().hex,
                "sequence": connection.execute(
                    "SELECT COALESCE(MAX(sequence),0)+1 FROM media_seerr_bootstraps"
                ).fetchone()[0],
                "revision": 1,
                "actor_id": actor.id,
                "actor_revision": actor_revision,
                "family_id": actor.family_id,
                "request_id": body.requestId,
                "installation_id": body.installationId,
                "installation_revision": body.expectedInstallationRevision,
                "source_bootstrap_id": body.sourceBootstrapId,
                "source_bootstrap_revision": body.expectedSourceBootstrapRevision,
                "state": "queued",
                "phase": "queued",
                "error_code": None,
                "created_at": now,
                "updated_at": now,
            }
            private = PrivateSeerrBootstrapPayload(
                private=PrivateSeerrBootstrap(
                    credential=secrets.token_urlsafe(48),
                    sourceBootstrapId=body.sourceBootstrapId,
                    sourceBootstrapRevision=body.expectedSourceBootstrapRevision,
                )
            )
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce, private.model_dump_json().encode("utf-8"), self._aad(row)
            )
            if len(ciphertext) > MAX_CIPHERTEXT:
                raise ApiError("seerr_bootstrap_storage_unavailable", 503)
            connection.execute(
                "INSERT INTO media_seerr_bootstraps("
                + ",".join(_BINDING)
                + ",nonce,ciphertext) VALUES("
                + ",".join("?" for _ in range(len(_BINDING) + 2))
                + ")",
                (*[row[key] for key in _BINDING], nonce, ciphertext),
            )
            stored = connection.execute(
                "SELECT * FROM media_seerr_bootstraps WHERE id=?", (row["id"],)
            ).fetchone()
            self._validate_row(connection, stored)
            return {"bootstrap": self._public(stored, self._decode(stored))}

    def _find(self, connection, identifier):
        row = connection.execute(
            "SELECT * FROM media_seerr_bootstraps WHERE id=?", (identifier,)
        ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        self._validate_row(connection, row)
        return row

    def get(self, actor, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            row = self._find(connection, identifier)
            return {"bootstrap": self._public(row, self._decode(row))}

    def list(self, actor, *, before=None, limit=10):
        if (
            type(limit) is not int
            or not 1 <= limit <= 10
            or before is not None
            and (type(before) is not int or not 1 <= before <= 2**63 - 1)
        ):
            raise ApiError("invalid_request")
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            rows = connection.execute(
                "SELECT * FROM media_seerr_bootstraps WHERE sequence<? "
                "ORDER BY sequence DESC LIMIT ?",
                (before or 2**63 - 1, limit + 1),
            ).fetchall()
            for row in rows:
                self._validate_row(connection, row)
            return {
                "bootstraps": [self._public(row, self._decode(row)) for row in rows[:limit]],
                "nextBefore": rows[limit - 1]["sequence"] if len(rows) > limit else None,
            }

    def private_payload(self, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            payload = self._decode(self._find(connection, identifier))
            return _PrivateView(
                credential=payload.private.credential,
                sourceBootstrapId=payload.private.sourceBootstrapId,
                sourceBootstrapRevision=payload.private.sourceBootstrapRevision,
                api_key=payload.apiKey,
            )

    def _save(self, connection, row, payload):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, payload.model_dump_json().encode("utf-8"), self._aad(row)
        )
        if len(ciphertext) > MAX_CIPHERTEXT:
            raise ApiError("seerr_bootstrap_storage_unavailable", 503)
        self._decode(dict(row) | {"nonce": nonce, "ciphertext": ciphertext})
        connection.execute(
            "UPDATE media_seerr_bootstraps SET "
            + ",".join(key + "=?" for key in _BINDING)
            + ",nonce=?,ciphertext=? WHERE id=?",
            (*[row[key] for key in _BINDING], nonce, ciphertext, row["id"]),
        )

    def _transition(
        self,
        connection,
        row,
        payload,
        *,
        state,
        error=None,
        api_key=None,
        convergence_phase=None,
        arr_instance_ids=None,
        initialized=None,
    ):
        changed = dict(row)
        changed.update(
            revision=row["revision"] + 1,
            state=state,
            phase="bootstrapping" if state == "running" else "complete",
            error_code=error,
            updated_at=max(row["updated_at"], int(self.settings.clock())),
        )
        value = payload.model_copy(
            update={
                "apiKey": payload.apiKey if api_key is None else api_key,
                "convergencePhase": convergence_phase
                or ("bootstrap" if state == "running" else payload.convergencePhase),
                "arrInstanceIds": (
                    payload.arrInstanceIds
                    if arr_instance_ids is None
                    else tuple(arr_instance_ids)
                ),
                "initialized": payload.initialized if initialized is None else initialized,
            }
        )
        self._save(connection, changed, value)
        return {"bootstrap": self._public(changed, value)}

    def _dispatch_authorized(self, connection, row):
        current = connection.execute(
            "SELECT u.revision,u.role,u.disabled,u.must_change_password,"
            "f.revoked_at,f.expires_at FROM users u JOIN session_families f "
            "ON f.user_id=u.id WHERE u.id=? AND f.id=?",
            (row["actor_id"], row["family_id"]),
        ).fetchone()
        return bool(
            current
            and current["revision"] == row["actor_revision"]
            and current["role"] == "admin"
            and not current["disabled"]
            and not current["must_change_password"]
            and current["revoked_at"] is None
            and current["expires_at"] > self.settings.clock()
        )

    def _current_arr_bindings(self, connection, installation):
        if self.arr_configurations is None:
            raise ValueError()
        rows = connection.execute(
            "SELECT * FROM media_arr_configurations WHERE preparation_id=? "
            "AND service_id IN ('radarr','sonarr') ORDER BY service_id",
            (installation["preparation_id"],),
        ).fetchall()
        if len(rows) != 2 or tuple(row["service_id"] for row in rows) != (
            "radarr",
            "sonarr",
        ):
            raise ValueError()
        bindings = []
        policy = {
            "radarr": ("/media/movies", 4),
            "sonarr": ("/media/tv", 5),
        }
        for row in rows:
            payload = self.arr_configurations._validate_row(connection, row)
            if row["state"] != "succeeded" or payload.receipt is None:
                raise ValueError()
            root, profile = policy[row["service_id"]]
            bindings.append(
                PrivateSeerrArrBinding(
                    serviceId=row["service_id"],
                    configurationId=row["id"],
                    configurationRevision=row["revision"],
                    resourceRevision=payload.receipt.revision,
                    serviceRevision=row["revision"],
                    configurationDigest=payload.receipt.configurationDigest,
                    hostname="larenor-" + payload.receipt.resourceId,
                    apiKey=payload.private.apiKey,
                    rootPath=root,
                    profileId=profile,
                    profileName="HD-1080p",
                )
            )
        return tuple(bindings)

    def _validate_arr_bindings(self, connection, installation, bindings):
        if self._current_arr_bindings(connection, installation) != tuple(bindings):
            raise ValueError()

    def _execution_inputs(self, connection, row):
        payload = self._validate_row(connection, row)
        installation = connection.execute(
            "SELECT * FROM media_installations WHERE id=?", (row["installation_id"],)
        ).fetchone()
        installed = self.installations._decode(installation)
        catalog = load_catalog()
        if catalog.digest != self.installations.preparations.plugins._catalog.digest:
            raise ValueError()
        bindings = payload.private.arrBindings
        if not bindings:
            bindings = self._current_arr_bindings(connection, installation)
            payload = payload.model_copy(
                update={
                    "private": payload.private.model_copy(
                        update={"arrBindings": bindings}
                    )
                }
            )
            self._save(connection, row, payload)
        else:
            self._validate_arr_bindings(connection, installation, bindings)
        return payload, verify_media_stack_plan(installed.plan, catalog)

    def _gate_locked(self, connection, row):
        if not self._dispatch_authorized(connection, row):
            return False
        try:
            _payload, plan = self._execution_inputs(connection, row)
            return (
                plan.coreId == self.installations.preparations.context.coreId
                and plan.homeId == self.installations.preparations.context.homeId
            )
        except (ApiError, ValueError, TypeError, AttributeError, OSError):
            return False

    def _gate(self, identifier):
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                row = self._find(connection, identifier)
                return row["state"] == "running" and self._gate_locked(connection, row)
        except (ApiError, ValueError, TypeError, AttributeError, OSError):
            return False

    @contextmanager
    def _dispatch_lock(self):
        descriptor = None
        try:
            descriptor = os.open(
                self.settings.data_dir / ".media-seerr-bootstraps.lock",
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                0o600,
            )
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_nlink != 1
            ):
                raise ApiError("seerr_bootstrap_storage_unavailable", 503)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield False
                return
            yield True
        except OSError:
            raise ApiError("seerr_bootstrap_storage_unavailable", 503) from None
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def tick(self):
        with self._dispatch_lock() as acquired:
            if not acquired:
                return None
            with self.db.transaction() as connection:
                row = connection.execute(
                    "SELECT * FROM media_seerr_bootstraps "
                    "WHERE state IN ('queued','running') "
                    "ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END,sequence LIMIT 1"
                ).fetchone()
                if row is None:
                    return None
                payload = self._decode(row)
                if row["state"] == "running":
                    return self._transition(
                        connection,
                        row,
                        payload,
                        state="needs_attention",
                        error="seerr_bootstrap_interrupted",
                    )
                if not self._gate_locked(connection, row):
                    return self._transition(
                        connection,
                        row,
                        payload,
                        state="needs_attention",
                        error="seerr_bootstrap_authority_changed",
                    )
                if self.backend is None:
                    return self._transition(
                        connection,
                        row,
                        payload,
                        state="failed",
                        error="seerr_bootstrap_worker_unavailable",
                    )
                payload, plan = self._execution_inputs(connection, row)
                self._transition(connection, row, payload, state="running")
                identifier = row["id"]
            try:
                result = self.backend.bootstrap_seerr(
                    identifier,
                    plan,
                    payload.private,
                    deadline=time.monotonic() + 60.0,
                    gate=lambda: self._gate(identifier),
                )
                if (
                    type(result) is not SeerrBootstrapExecutionResult
                    or result.arr_wiring is None
                ):
                    raise SeerrBootstrapExecutionError(
                        "invalid_seerr_bootstrap_execution", uncertain_effect=True
                    )
            except SeerrBootstrapExecutionError as failure:
                error = (
                    "invalid_seerr_bootstrap_result"
                    if failure.code == "invalid_seerr_bootstrap_execution"
                    else failure.code
                )
                state = (
                    "needs_attention"
                    if failure.uncertain_effect
                    or bool(failure.completed_steps)
                    or error
                    in {
                        "seerr_bootstrap_authority_changed",
                        "seerr_bootstrap_endpoint_changed",
                        "seerr_bootstrap_peer_changed",
                    }
                    else "failed"
                )
                with self.db.transaction() as connection:
                    row = self._find(connection, identifier)
                    phase = (
                        "arr_wiring"
                        if "session_destroyed" in failure.completed_steps
                        else "bootstrap"
                    )
                    return self._transition(
                        connection,
                        row,
                        self._decode(row),
                        state=state,
                        error=error,
                        api_key=failure.api_key,
                        convergence_phase=phase,
                    )
            except (OSError, ValueError, TypeError, AttributeError, RuntimeError):
                with self.db.transaction() as connection:
                    row = self._find(connection, identifier)
                    return self._transition(
                        connection,
                        row,
                        self._decode(row),
                        state="needs_attention",
                        error="seerr_bootstrap_worker_unavailable",
                    )
            with self.db.transaction() as connection:
                row = self._find(connection, identifier)
                return self._transition(
                    connection,
                    row,
                    self._decode(row),
                    state="succeeded",
                    api_key=result.api_key,
                    convergence_phase="initialize",
                    arr_instance_ids=result.arr_wiring.instance_ids,
                )
