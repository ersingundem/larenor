"""Durable offline manifests bound to current account and media authority."""

import base64
import binascii
import hashlib
import hmac
import json
import re
import threading
import time

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from ..plugins.media_playback_models import (
    OfflineMediaChunkReadback,
    PrivateMediaPlaybackAuthority,
)
from .models import (CreateOfflineMediaRequest, OfflineMediaAuthority,
                     OfflineMediaManifest, ReadOfflineMediaChunkRequest,
                     RevokeOfflineMediaRequest,
                     CreateOnlinePlaybackLeaseRequest,
                     OnlinePlaybackLease,
                     UpdateOnlinePlaybackLeaseRequest,
                     UpdateOfflineMediaProgressRequest)

MAX_GRANTS_PER_ACTOR = 32
MAX_TTL = 7 * 24 * 60 * 60
CHUNK_BYTES = 32 * 1024
PLAYBACK_LEASE_TTL = 120
MAX_PLAYBACK_LEASES_PER_ACTOR = 32
MAX_PLAYBACK_LEASES = 256
_RANGE = re.compile(r"bytes=([0-9]{0,20})-([0-9]{0,20})\Z")
_FIELDS = (
    "id", "actor_id", "family_id", "actor_revision", "revision",
    "authority_json", "title", "content_length", "content_sha256",
    "content_type", "chunk_bytes", "downloaded_bytes", "state",
    "expires_at", "created_at", "updated_at", "request_hash",
)


class OfflineMediaService:
    def __init__(self, db, auth, settings, key, context, media_playback):
        self.db, self.auth, self.settings = db, auth, settings
        self._key, self.context = key, context
        self.media_playback = media_playback
        # Online playback leases intentionally do not survive a Core restart.
        # A new process cannot silently resume an old bearer-backed stream.
        self._playback_leases = {}
        self._playback_lock = threading.RLock()

    @staticmethod
    def _json(value):
        return json.dumps(value, sort_keys=True, separators=(",", ":"),
                          allow_nan=False)

    def _tag(self, row):
        payload = self._json({field: row[field] for field in _FIELDS}).encode()
        return hmac.new(self._key, b"larenor-offline-media-v1\0" + payload,
                        hashlib.sha256).hexdigest()

    def _manifest(self, row):
        private = PrivateMediaPlaybackAuthority.model_validate_json(
            row["authority_json"])
        return OfflineMediaManifest(
            grantId=row["id"], revision=row["revision"],
            authority=OfflineMediaAuthority(
                coreId=self.context.coreId, homeId=self.context.homeId,
                accountId=row["actor_id"],
                accountRevision=row["actor_revision"],
                sessionFamilyId=row["family_id"],
                **private.model_dump(mode="python")),
            title=row["title"], contentLength=row["content_length"],
            contentSha256=row["content_sha256"],
            contentType=row["content_type"], chunkBytes=row["chunk_bytes"],
            downloadedBytes=row["downloaded_bytes"], state=row["state"],
            expiresAt=row["expires_at"])

    def _row(self, row):
        if row is None or not hmac.compare_digest(
                row["envelope_tag"], self._tag(row)):
            raise StartupError("offline_media_storage_invalid")
        try:
            PrivateMediaPlaybackAuthority.model_validate_json(
                row["authority_json"])
            self._manifest(row)
        except (ValidationError, ValueError, TypeError):
            raise StartupError("offline_media_storage_invalid") from None
        return row

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM offline_media_grants LIMIT 1025"
                ).fetchall()
                if len(rows) > 1024:
                    raise ValueError()
                for row in rows:
                    self._row(row)
        except (StartupError, ValueError, TypeError):
            raise StartupError("offline_media_storage_invalid") from None

    def _actor_revision(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT revision,disabled,must_change_password FROM users "
            "WHERE id=?", (actor.id,)).fetchone()
        if (row is None or row["disabled"] or row["must_change_password"]
                or actor.must_change_password):
            raise ApiError("invalid_session", 401)
        return row["revision"]

    def _owned(self, connection, actor, grant_id, expected=None,
               *, allow_revoked=False):
        raw = connection.execute(
            "SELECT * FROM offline_media_grants WHERE id=?", (grant_id,)
        ).fetchone()
        if raw is None:
            raise ApiError("not_found", 404)
        row = self._row(raw)
        if row["actor_id"] != actor.id or row["family_id"] != actor.family_id:
            raise ApiError("not_found", 404)
        actor_revision = self._actor_revision(connection, actor)
        if (row["actor_revision"] != actor_revision
                or expected is not None and row["revision"] != expected
                or not allow_revoked and (row["state"] == "revoked"
                    or int(self.settings.clock()) >= row["expires_at"])):
            raise ApiError("offline_media_authority_changed", 409)
        private = PrivateMediaPlaybackAuthority.model_validate_json(
            row["authority_json"])
        if (not allow_revoked
                and self.media_playback._gate(actor, private, actor_revision)
                is not True):
            raise ApiError("offline_media_authority_changed", 409)
        return row

    def create(self, actor, body):
        if type(body) is not CreateOfflineMediaRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        if not now < body.expiresAt <= now + MAX_TTL:
            raise ApiError("invalid_request")
        _authority, observation = self.media_playback.archive._collect(
            actor, body, member=True)
        private = self.media_playback._catalog(actor, body)
        item = next((value for value in observation.jellyfin.items
                     if value.itemId == body.itemId
                     and value.mediaKey == body.mediaKey
                     and value.integrity == "playable"), None)
        if (item is None or item.sizeBytes < 1 or item.contentHash is None
                or item.sizeBytes > body.storageQuotaBytes
                or item.sizeBytes > body.storageAvailableBytes):
            raise ApiError("offline_media_unavailable", 409)
        request_hash = hashlib.sha256(
            body.model_dump_json().encode()).hexdigest()
        with self.db.transaction() as connection:
            actor_revision = self._actor_revision(connection, actor)
            existing = connection.execute(
                "SELECT * FROM offline_media_grants WHERE id=?",
                (body.requestId,)).fetchone()
            if existing is not None:
                existing = self._row(existing)
                if (existing["actor_id"] != actor.id
                        or existing["request_hash"] != request_hash):
                    raise ApiError("offline_media_request_conflict", 409)
                return {"manifest": self._manifest(existing)}
            active = connection.execute(
                "SELECT COUNT(*) AS count FROM offline_media_grants "
                "WHERE actor_id=? AND state!='revoked' AND expires_at>?",
                (actor.id, now)).fetchone()["count"]
            if active >= MAX_GRANTS_PER_ACTOR:
                raise ApiError("offline_media_limit_reached", 429)
            row = {
                "id": body.requestId, "actor_id": actor.id,
                "family_id": actor.family_id,
                "actor_revision": actor_revision, "revision": 1,
                "authority_json": private.model_dump_json(),
                "title": item.title, "content_length": item.sizeBytes,
                "content_sha256": item.contentHash,
                "content_type": "application/octet-stream",
                "chunk_bytes": CHUNK_BYTES, "downloaded_bytes": 0,
                "state": "granted", "expires_at": body.expiresAt,
                "created_at": now, "updated_at": now,
                "request_hash": request_hash,
            }
            row["envelope_tag"] = self._tag(row)
            connection.execute(
                "INSERT INTO offline_media_grants VALUES("
                + ",".join("?" for _ in range(18)) + ")",
                tuple(row[field] for field in _FIELDS)
                + (row["envelope_tag"],))
        return {"manifest": self._manifest(row)}

    def get(self, actor, grant_id):
        with self.db.connection() as connection:
            return {"manifest": self._manifest(
                self._owned(connection, actor, grant_id))}

    def chunk(self, actor, grant_id, body):
        if type(body) is not ReadOfflineMediaChunkRequest:
            raise ApiError("invalid_request")
        with self.db.connection() as connection:
            row = self._owned(
                connection, actor, grant_id, body.expectedRevision)
            if (row["state"] == "complete"
                    or body.offset != row["downloaded_bytes"]
                    or body.offset >= row["content_length"]):
                raise ApiError("offline_media_authority_changed", 409)
            actor_revision = row["actor_revision"]
            private = PrivateMediaPlaybackAuthority.model_validate_json(
                row["authority_json"])
            length = min(
                row["chunk_bytes"], row["content_length"] - body.offset)
        backend = self.media_playback.backend
        reader = getattr(backend, "read_offline_media_chunk", None)
        if not callable(reader):
            raise ApiError("media_playback_worker_unavailable", 503)
        deadline = time.monotonic() + 5

        def gate():
            return (time.monotonic() < deadline
                    and self.media_playback._gate(
                        actor, private, actor_revision))
        try:
            result = reader(
                private, request_id=body.requestId, offset=body.offset,
                length=length, deadline=deadline, gate=gate)
            if (gate() is not True or result.itemId != private.itemId
                    or result.offset != body.offset
                    or result.contentLength != row["content_length"]):
                raise ValueError()
            content = base64.b64decode(result.dataBase64, validate=True)
            if not 1 <= len(content) <= length:
                raise ValueError()
        except ApiError:
            raise
        except (ValueError, TypeError, binascii.Error):
            raise ApiError("media_playback_worker_unavailable", 503) from None
        return content, result.contentType, row["content_sha256"]

    def progress(self, actor, grant_id, body):
        if type(body) is not UpdateOfflineMediaProgressRequest:
            raise ApiError("invalid_request")
        with self.db.transaction() as connection:
            row = dict(self._owned(
                connection, actor, grant_id, body.expectedRevision))
            if (body.downloadedBytes < row["downloaded_bytes"]
                    or body.downloadedBytes > row["content_length"]
                    or body.downloadedBytes == row["content_length"]
                    and body.contentSha256 != row["content_sha256"]
                    or body.downloadedBytes < row["content_length"]
                    and body.contentSha256 is not None):
                raise ApiError("offline_media_integrity_failed", 409)
            row.update(
                revision=row["revision"] + 1,
                downloaded_bytes=body.downloadedBytes,
                state=("complete" if body.downloadedBytes
                       == row["content_length"] else "transferring"),
                updated_at=int(self.settings.clock()))
            row["envelope_tag"] = self._tag(row)
            connection.execute(
                "UPDATE offline_media_grants SET revision=?,downloaded_bytes=?,"
                "state=?,updated_at=?,envelope_tag=? WHERE id=?",
                (row["revision"], row["downloaded_bytes"], row["state"],
                 row["updated_at"], row["envelope_tag"], row["id"]))
        return {"manifest": self._manifest(row)}

    def revoke(self, actor, grant_id, body):
        if type(body) is not RevokeOfflineMediaRequest:
            raise ApiError("invalid_request")
        with self.db.transaction() as connection:
            row = dict(self._owned(
                connection, actor, grant_id, body.expectedRevision,
                allow_revoked=True))
            if row["state"] != "revoked":
                row.update(revision=row["revision"] + 1, state="revoked",
                           updated_at=int(self.settings.clock()))
                row["envelope_tag"] = self._tag(row)
                connection.execute(
                    "UPDATE offline_media_grants SET revision=?,state=?,"
                    "updated_at=?,envelope_tag=? WHERE id=?",
                    (row["revision"], row["state"], row["updated_at"],
                     row["envelope_tag"], row["id"]))
        return {"manifest": self._manifest(row)}

    def _playback_public(self, row):
        private = row["authority"]
        return OnlinePlaybackLease(
            leaseId=row["id"], revision=row["revision"],
            authority=OfflineMediaAuthority(
                coreId=self.context.coreId, homeId=self.context.homeId,
                accountId=row["actor_id"],
                accountRevision=row["actor_revision"],
                sessionFamilyId=row["family_id"],
                **private.model_dump(mode="python")),
            title=row["title"], mediaKind=row["media_kind"],
            runtimeSeconds=row["runtime_seconds"],
            contentLength=row["content_length"],
            contentType="application/octet-stream",
            byteIntegrity="source_bound", supportsByteRanges=True,
            state=row["state"], expiresAt=row["expires_at"],
            restartBehavior="terminal_invalid")

    def _playback_owned(self, actor, lease_id, expected=None, *, terminal=False):
        now = int(self.settings.clock())
        with self._playback_lock:
            stored = self._playback_leases.get(lease_id)
            if (stored is None or stored["actor_id"] != actor.id
                    or stored["family_id"] != actor.family_id):
                raise ApiError("not_found", 404)
            row = dict(stored)
        with self.db.connection() as connection:
            actor_revision = self._actor_revision(connection, actor)
        if (row["actor_revision"] != actor_revision
                or expected is not None and row["revision"] != expected
                or not terminal and (row["state"] != "active"
                                     or now >= row["expires_at"])
                or not terminal and self.media_playback._gate(
                    actor, row["authority"], actor_revision) is not True):
            raise ApiError("offline_media_authority_changed", 409)
        with self._playback_lock:
            current = self._playback_leases.get(lease_id)
            if (current is None or current["state"] != row["state"]
                    or current["revision"] != row["revision"]):
                raise ApiError("offline_media_authority_changed", 409)
        return row

    def _prune_playback(self, now):
        with self._playback_lock:
            expired = [
                key for key, value in self._playback_leases.items()
                if value["expires_at"] <= now
            ]
            for key in expired:
                self._playback_leases.pop(key, None)

    def create_playback_lease(self, actor, body):
        if type(body) is not CreateOnlinePlaybackLeaseRequest:
            raise ApiError("invalid_request")
        now = int(self.settings.clock())
        self._prune_playback(now)
        _current, observation = self.media_playback.archive._collect(
            actor, body, member=True)
        private = self.media_playback._catalog(actor, body)
        item = next((value for value in observation.jellyfin.items
                     if value.itemId == body.itemId
                     and value.mediaKey == body.mediaKey
                     and value.integrity == "playable"), None)
        if item is None or item.sizeBytes < 1:
            raise ApiError("offline_media_unavailable", 409)
        with self.db.connection() as connection:
            actor_revision = self._actor_revision(connection, actor)
        if self.media_playback._gate(actor, private, actor_revision) is not True:
            raise ApiError("offline_media_authority_changed", 409)
        request_hash = hashlib.sha256(
            self._json(body.model_dump(mode="json")).encode()).hexdigest()
        row = {
            "id": body.requestId, "actor_id": actor.id,
            "family_id": actor.family_id, "actor_revision": actor_revision,
            "revision": 1, "authority": private, "title": item.title,
            "media_kind": item.mediaKind,
            "runtime_seconds": item.runtimeSeconds,
            "content_length": item.sizeBytes, "state": "active",
            "expires_at": now + PLAYBACK_LEASE_TTL,
            "request_hash": request_hash, "last_request_id": None,
            "last_request_hash": None,
        }
        with self._playback_lock:
            existing = self._playback_leases.get(body.requestId)
        if existing is not None:
            if (existing["actor_id"] != actor.id
                    or existing["family_id"] != actor.family_id
                    or existing["request_hash"] != request_hash):
                raise ApiError("offline_media_request_conflict", 409)
            current = self._playback_owned(actor, body.requestId)
            return {"lease": self._playback_public(current)}
        backend = self.media_playback.backend
        if not callable(getattr(backend, "read_offline_media_chunk", None)):
            raise ApiError("media_playback_worker_unavailable", 503)
        with self._playback_lock:
            active = sum(
                value["actor_id"] == actor.id
                and value["state"] == "active"
                and value["expires_at"] > now
                for value in self._playback_leases.values())
            if active >= MAX_PLAYBACK_LEASES_PER_ACTOR:
                raise ApiError("offline_media_limit_reached", 429)
            if len(self._playback_leases) >= MAX_PLAYBACK_LEASES:
                raise ApiError("offline_media_limit_reached", 429)
            # A simultaneous identical create returns the exact current lease;
            # a different body can never replace its authority.
            existing = self._playback_leases.get(body.requestId)
            if existing is not None:
                if (existing["actor_id"] != actor.id
                        or existing["family_id"] != actor.family_id
                        or existing["request_hash"] != request_hash):
                    raise ApiError("offline_media_request_conflict", 409)
            else:
                self._playback_leases[body.requestId] = row
        current = self._playback_owned(actor, body.requestId)
        return {"lease": self._playback_public(current)}

    def renew_playback_lease(self, actor, lease_id, body):
        if type(body) is not UpdateOnlinePlaybackLeaseRequest:
            raise ApiError("invalid_request")
        mutation_hash = hashlib.sha256(
            self._json(body.model_dump(mode="json")).encode()).hexdigest()
        with self._playback_lock:
            replay = self._playback_leases.get(lease_id)
            if (replay is not None
                    and replay["actor_id"] == actor.id
                    and replay["family_id"] == actor.family_id
                    and replay["last_request_id"] == body.requestId):
                if replay["last_request_hash"] != mutation_hash:
                    raise ApiError("offline_media_request_conflict", 409)
                current = self._playback_owned(actor, lease_id)
                return {"lease": self._playback_public(current)}
        row = self._playback_owned(actor, lease_id, body.expectedRevision)
        with self._playback_lock:
            current = self._playback_leases.get(lease_id)
            if current is None or current["revision"] != row["revision"]:
                raise ApiError("offline_media_authority_changed", 409)
            current = dict(current)
            current.update(revision=current["revision"] + 1,
                           expires_at=int(self.settings.clock())
                           + PLAYBACK_LEASE_TTL,
                           last_request_id=body.requestId,
                           last_request_hash=mutation_hash)
            self._playback_leases[lease_id] = current
        return {"lease": self._playback_public(current)}

    def retire_playback_lease(self, actor, lease_id, body):
        if type(body) is not UpdateOnlinePlaybackLeaseRequest:
            raise ApiError("invalid_request")
        mutation_hash = hashlib.sha256(
            ("retire\0" + self._json(
                body.model_dump(mode="json"))).encode()).hexdigest()
        with self._playback_lock:
            replay = self._playback_leases.get(lease_id)
            if (replay is not None
                    and replay["actor_id"] == actor.id
                    and replay["family_id"] == actor.family_id
                    and replay["last_request_id"] == body.requestId):
                if replay["last_request_hash"] != mutation_hash:
                    raise ApiError("offline_media_request_conflict", 409)
                current = self._playback_owned(
                    actor, lease_id, terminal=True)
                return {"lease": self._playback_public(current)}
        row = self._playback_owned(
            actor, lease_id, body.expectedRevision, terminal=True)
        with self._playback_lock:
            current = self._playback_leases.get(lease_id)
            if current is None or current["revision"] != row["revision"]:
                raise ApiError("offline_media_authority_changed", 409)
            current = dict(current)
            if current["state"] != "retired":
                current.update(revision=current["revision"] + 1,
                               state="retired",
                               last_request_id=body.requestId,
                               last_request_hash=mutation_hash)
                self._playback_leases[lease_id] = current
        return {"lease": self._playback_public(current)}

    def playback_content(self, actor, lease_id):
        return self._playback_owned(actor, lease_id)

    @staticmethod
    def playback_range(total, value):
        if value is None:
            return 0, total - 1, 200
        match = _RANGE.fullmatch(value)
        if match is None or not any(match.groups()):
            return None
        first, last = match.groups()
        if first:
            start = int(first)
            end = total - 1 if not last else int(last)
            if start >= total or end < start:
                return None
            end = min(end, total - 1)
        else:
            suffix = int(last)
            if suffix < 1:
                return None
            start, end = max(0, total - suffix), total - 1
        return start, end, 206

    def playback_chunk(self, actor, lease_id, offset, length):
        row = self._playback_owned(actor, lease_id)
        if (type(offset) is not int or type(length) is not int
                or offset < 0 or not 1 <= length <= CHUNK_BYTES
                or offset + length > row["content_length"]):
            raise ApiError("invalid_request")
        backend = self.media_playback.backend
        reader = getattr(backend, "read_offline_media_chunk", None)
        if not callable(reader):
            raise ApiError("media_playback_worker_unavailable", 503)
        private = row["authority"]
        deadline = time.monotonic() + 5

        def gate():
            if time.monotonic() >= deadline:
                return False
            try:
                current = self._playback_owned(actor, lease_id)
                return current["authority"] == private
            except ApiError:
                return False

        request_id = hashlib.sha256(
            f"{lease_id}:{offset}:{length}".encode()).hexdigest()[:32]
        try:
            result = reader(
                private, request_id=request_id, offset=offset,
                length=length, deadline=deadline, gate=gate)
            if (type(result) is not OfflineMediaChunkReadback
                    or gate() is not True or result.itemId != private.itemId
                    or result.offset != offset
                    or result.contentLength != row["content_length"]):
                raise ValueError()
            content = base64.b64decode(result.dataBase64, validate=True)
            if not 1 <= len(content) <= length:
                raise ValueError()
            return content
        except ApiError:
            raise
        except (AttributeError, ValueError, TypeError, binascii.Error):
            raise ApiError("media_playback_worker_unavailable", 503) from None
