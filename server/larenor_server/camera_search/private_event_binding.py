"""Opaque, expiring event authority for private transformations across restart.

Only a recently searched event can mint a seal. Provider paths and credentials
remain inside the Frigate adapter; existing share ciphertext has its own access
policy and does not need the original event to survive provider retention.
"""

import base64
import hashlib
import hmac
import json
import re
import secrets

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError
from .models import CameraEvidenceLink, CameraSearchRequest

MAX_TTL_SECONDS = 7 * 86400
MAX_CLIP_BYTES = 64 * 1024 * 1024
_IDENTITY = re.compile(r"[0-9a-f]{32}\Z")
_EVENT = re.compile(r"[A-Za-z0-9_.-]{1,128}\Z")


class FrigatePrivateEventBindings:
    def _binding_cipher(self):
        key = hmac.new(self.key, b"private-event-binding-v1", hashlib.sha256).digest()
        return AESGCM(key)

    def _binding_aad(self):
        return ("private-event-binding-v1:" + self.core_id + ":" + self.home_id).encode()

    def _open_binding(self, seal):
        try:
            if (not isinstance(seal, str) or not 64 <= len(seal) <= 8192
                    or re.fullmatch(r"[A-Za-z0-9_-]+", seal) is None):
                raise ValueError
            data = base64.b64decode(seal + "=" * (-len(seal) % 4), altchars=b"-_", validate=True)
            plain = self._binding_cipher().decrypt(data[:12], data[12:], self._binding_aad())
            value = json.loads(plain)
            if type(value) is not dict or set(value) != {
                "schemaVersion", "evidence", "native", "query", "ownerId",
                "accountRevision", "homeRevision", "sourceRevision",
                "serviceDigest", "cameraFingerprint", "issuedAtMs", "expiresAtMs",
            } or value["schemaVersion"] != 1:
                raise ValueError
            evidence = CameraEvidenceLink.model_validate(value["evidence"])
            if (evidence.coreId, evidence.homeId) != (self.core_id, self.home_id):
                raise ValueError
            if (not isinstance(value["native"], str) or not _EVENT.fullmatch(value["native"])
                    or not isinstance(value["ownerId"], str) or not _IDENTITY.fullmatch(value["ownerId"])
                    or any(type(value[key]) is not int or value[key] < 1 for key in (
                        "accountRevision", "homeRevision", "sourceRevision"))
                    or any(not isinstance(value[key], str)
                           or not re.fullmatch(r"[0-9a-f]{64}", value[key])
                           for key in ("serviceDigest", "cameraFingerprint"))
                    or any(type(value[key]) is not int or value[key] < 0
                           for key in ("issuedAtMs", "expiresAtMs"))
                    or not 0 < value["expiresAtMs"] - value["issuedAtMs"] <= MAX_TTL_SECONDS * 1000
                    or value["issuedAtMs"] > int(self.clock() * 1000)
                    or value["expiresAtMs"] <= int(self.clock() * 1000)):
                raise ValueError
            self._binding_query(value)  # Validate the closed query, never an arbitrary URL.
            return value, evidence
        except Exception:
            raise ApiError("private_event_binding_invalid", 409) from None

    @staticmethod
    def _binding_query(value):
        evidence = CameraEvidenceLink.model_validate(value["evidence"])
        return CameraSearchRequest(schemaVersion=1, query=value["query"],
            expectedIndexRevision=value["sourceRevision"], startMs=evidence.capturedAtMs,
            endMs=evidence.capturedAtMs + 86400000, cameraIds=[evidence.cameraId], pageSize=1)

    def _camera_fingerprint(self, actor, camera_id):
        _raw, _service, resources, _authority = self._live(actor, self.core_id, self.home_id)
        if camera_id not in resources:
            raise ApiError("forbidden", 403)
        # _facts fingerprints the current resource, ACL, binding and HA service.
        return hashlib.sha256(repr(resources[camera_id][1]).encode()).hexdigest()

    def _public_binding(self, value, seal):
        return {"schemaVersion": 1, "evidence": CameraEvidenceLink.model_validate(value["evidence"]),
                "seal": seal,
                "cameraRevision": int(hmac.new(self.key,
                    value["cameraFingerprint"].encode(), hashlib.sha256).hexdigest()[:13], 16) + 1,
                "sourceRevision": value["sourceRevision"], "expiresAtMs": value["expiresAtMs"]}

    def _binding_context(self, core, actor, value, cancelled):
        def check_cancelled():
            if cancelled():
                raise ApiError("request_cancelled", 408)
        check_cancelled()
        evidence = CameraEvidenceLink.model_validate(value["evidence"])
        raw, service, authority, mapping, token, semantic, source_guard = self._prepare(
            actor, self.core_id, self.home_id)
        if (authority.role != "admin" or authority.accountId != value["ownerId"]
                or authority.accountRevision != value["accountRevision"]
                or authority.homeRevision != value["homeRevision"]
                or raw["revision"] != value["sourceRevision"]
                or evidence.cameraId not in mapping
                or self._service_digest(service).hex() != value["serviceDigest"]
                or self._camera_fingerprint(actor, evidence.cameraId) != value["cameraFingerprint"]):
            raise ApiError("revision_conflict", 409)
        def guard():
            check_cancelled()
            if value["expiresAtMs"] <= int(self.clock() * 1000):
                raise ApiError("private_event_binding_invalid", 409)
            source_guard()
        guard()
        return raw, service, authority, mapping, token, semantic, guard

    def _verify_bound_event(self, value, context):
        raw, service, authority, mapping, token, _semantic, guard = context
        current = self._get(service, "/api/events/" + value["native"], guard, token)
        if type(current) is not dict or current.get("id") != value["native"]:
            raise ApiError("revision_conflict", 409)
        matches, _ = self._matches([current], mapping, authority, raw["revision"],
            self._binding_query(value), True, service)
        if len(matches) != 1 or matches[0].evidence != CameraEvidenceLink.model_validate(value["evidence"]):
            raise ApiError("revision_conflict", 409)
        guard()

    def private_event_binding(self, core, actor, core_id, home_id, camera_id, event_id,
                              *, ttl_seconds=MAX_TTL_SECONDS, cancelled=lambda: False):
        if cancelled():
            raise ApiError("request_cancelled", 408)
        if (core_id, home_id) != (self.core_id, self.home_id):
            raise ApiError("not_found", 404)
        if type(ttl_seconds) is not int or not 1 <= ttl_seconds <= MAX_TTL_SECONDS:
            raise ApiError("invalid_request")
        core.auth.rate_limit([("private_event_binding", actor.id, 60)])
        with self._budget():
            raw, service, authority, mapping, _token, _semantic, guard = self._prepare(actor, core_id, home_id)
            with self._lock:
                saved = self._evidence.get((actor.id, actor.family_id, event_id))
            if (saved is None or saved[4] < self.clock() or authority.role != "admin"
                    or saved[0] != service.id or saved[1] != raw["revision"]
                    or saved[3].cameraId != camera_id or camera_id not in mapping):
                raise ApiError("revision_conflict", 409)
            now = int(self.clock() * 1000)
            value = {"schemaVersion": 1, "evidence": saved[3].model_dump(mode="json"),
                "native": saved[2], "query": saved[5], "ownerId": actor.id,
                "accountRevision": authority.accountRevision, "homeRevision": authority.homeRevision,
                "sourceRevision": raw["revision"], "serviceDigest": self._service_digest(service).hex(),
                "cameraFingerprint": self._camera_fingerprint(actor, camera_id),
                "issuedAtMs": now, "expiresAtMs": now + ttl_seconds * 1000}
            self._verify_bound_event(value, self._binding_context(core, actor, value, cancelled))
            guard()
            nonce = secrets.token_bytes(12)
            seal = base64.urlsafe_b64encode(nonce + self._binding_cipher().encrypt(nonce,
                json.dumps(value, sort_keys=True, separators=(",", ":")).encode(), self._binding_aad()
            )).decode().rstrip("=")
            return self._public_binding(value, seal)

    def authorize_private_event_binding(self, core, actor, seal, *, cancelled=lambda: False):
        with self._budget():
            value, _evidence = self._open_binding(seal)
            context = self._binding_context(core, actor, value, cancelled)
            context[-1]()
            return self._public_binding(value, seal)

    def read_private_event_clip(self, core, actor, seal, max_bytes, *, cancelled=lambda: False):
        if type(max_bytes) is not int or not 24 <= max_bytes <= MAX_CLIP_BYTES:
            raise ApiError("invalid_request")
        with self._budget():
            value, _evidence = self._open_binding(seal)
            context = self._binding_context(core, actor, value, cancelled)
            self._verify_bound_event(value, context)
            _raw, service, authority, mapping, token, _semantic, guard = context
            response = self._request(service, "GET", "/api/events/" + value["native"] + "/clip.mp4",
                guard, token=token, max_bytes=max_bytes)
            mime = [v.split(";")[0].strip().lower() for k, v in response.headers if k.lower() == "content-type"]
            if (mime != ["video/mp4"] or not 24 <= len(response.body) <= max_bytes
                    or response.body[4:8] != b"ftyp"
                    or not 16 <= int.from_bytes(response.body[:4], "big") <= len(response.body)):
                raise ApiError("camera_search_source_unavailable", 503)
            fresh = self._binding_context(core, actor, value, cancelled)
            if fresh[2] != authority or fresh[3] != mapping:
                raise ApiError("revision_conflict", 409)
            self._verify_bound_event(value, fresh)
            fresh[-1]()
            return response.body
