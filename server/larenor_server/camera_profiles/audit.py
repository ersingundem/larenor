"""Bounded tamper-evident audit chain for camera profile decisions and effects."""

import hashlib
import hmac
import json
import secrets
import re

from ..errors import ApiError, StartupError
from .models import CameraAuditEvent


ZERO = "0" * 64


def _canonical(value) -> bytes:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("ascii")


class TamperEvidentCameraAudit:
    def __init__(self, *, key: bytes, coreId: str, homeId: str, maxEvents: int = 4096,
                 chainId: str | None = None):
        if (not isinstance(key, bytes) or len(key) < 32 or type(maxEvents) is not int
                or not 1 <= maxEvents <= 16_384
                or not re.fullmatch(r"[0-9a-f]{32}", coreId)
                or not re.fullmatch(r"[0-9a-f]{32}", homeId)):
            raise ValueError("invalid_audit_settings")
        self._key = key
        self._core_id = coreId
        self._home_id = homeId
        self._max_events = maxEvents
        self._chain_id = chainId or secrets.token_hex(16)
        self._events: list[CameraAuditEvent] = []
        self._head = ZERO

    def _tag(self):
        return hmac.new(
            self._key,
            b"larenor-camera-profile-audit-state-v1\0" + _canonical([
                self._core_id, self._home_id, self._chain_id, len(self._events), self._head
            ]),
            hashlib.sha256,
        ).hexdigest()

    def ensure_capacity(self, count):
        if type(count) is not int or count < 0 or len(self._events) + count > self._max_events:
            raise ApiError("camera_profile_audit_limit", 429)

    def append(self, *, kind, profileId, profileRevision, actorAccountId, requestId,
               status, payloadHash, atMs):
        if len(self._events) >= self._max_events:
            raise ApiError("camera_profile_audit_limit", 429)
        body = {
            "schemaVersion": 1,
            "sequence": len(self._events) + 1,
            "kind": kind,
            "coreId": self._core_id,
            "homeId": self._home_id,
            "profileId": profileId,
            "profileRevision": profileRevision,
            "actorAccountId": actorAccountId,
            "requestId": requestId,
            "status": status,
            "payloadHash": payloadHash,
            "atMs": atMs,
            "previousHash": self._head,
        }
        entry_hash = hashlib.sha256(
            b"larenor-camera-profile-audit-event-v1\0" + _canonical(body)
        ).hexdigest()
        event = CameraAuditEvent(**body, entryHash=entry_hash)
        self._events.append(event)
        self._head = entry_hash
        return event

    def events(self):
        return list(self._events)

    def export(self):
        return {
            "schemaVersion": 1,
            "chainId": self._chain_id,
            "events": [item.model_dump(mode="json") for item in self._events],
            "headHash": self._head,
            "headTag": self._tag(),
        }

    @classmethod
    def restore(cls, raw, *, key, coreId, homeId, maxEvents=4096):
        try:
            if not isinstance(raw, dict) or set(raw) != {
                "schemaVersion", "chainId", "events", "headHash", "headTag"
            } or raw["schemaVersion"] != 1:
                raise ValueError
            chain_id = raw["chainId"]
            if not isinstance(chain_id, str) or len(chain_id) != 32 or any(
                char not in "0123456789abcdef" for char in chain_id
            ):
                raise ValueError
            events = [CameraAuditEvent.model_validate(item) for item in raw["events"]]
            if len(events) > maxEvents:
                raise ValueError
            restored = cls(key=key, coreId=coreId, homeId=homeId,
                           maxEvents=maxEvents, chainId=chain_id)
            previous = ZERO
            for index, event in enumerate(events, 1):
                body = event.model_dump(mode="json", exclude={"entryHash"})
                expected = hashlib.sha256(
                    b"larenor-camera-profile-audit-event-v1\0" + _canonical(body)
                ).hexdigest()
                if (event.sequence != index or event.coreId != coreId or event.homeId != homeId
                        or event.previousHash != previous
                        or not hmac.compare_digest(event.entryHash, expected)):
                    raise ValueError
                restored._events.append(event)
                restored._head = event.entryHash
                previous = event.entryHash
            if raw["headHash"] != restored._head or not hmac.compare_digest(
                raw["headTag"], restored._tag()
            ):
                raise ValueError
            return restored
        except (KeyError, TypeError, ValueError):
            raise StartupError("camera_profile_audit_invalid") from None
