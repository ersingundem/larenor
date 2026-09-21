"""Bounded HMAC-authenticated comfort audit chain."""

import hashlib
import hmac
import json
import re
import secrets

from ..errors import ApiError, StartupError
from .models import ComfortAuditEvent


ZERO = "0" * 64


def _json(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")


class TamperEvidentComfortAudit:
    def __init__(self, *, key, coreId, homeId, maxEvents=4096, chainId=None):
        if (
            not isinstance(key, bytes)
            or len(key) < 32
            or type(maxEvents) is not int
            or not 1 <= maxEvents <= 16_384
            or not re.fullmatch(r"[0-9a-f]{32}", coreId)
            or not re.fullmatch(r"[0-9a-f]{32}", homeId)
        ):
            raise ValueError("invalid_audit_settings")
        self._key, self._core, self._home = key, coreId, homeId
        self._limit, self._chain = maxEvents, chainId or secrets.token_hex(16)
        self._events, self._head = [], ZERO

    def ensure_capacity(self, count):
        if (
            type(count) is not int
            or count < 0
            or len(self._events) + count > self._limit
        ):
            raise ApiError("comfort_audit_limit", 429)

    def _tag(self):
        return hmac.new(
            self._key,
            b"larenor-comfort-audit-state-v1\0"
            + _json(
                [self._core, self._home, self._chain, len(self._events), self._head]
            ),
            hashlib.sha256,
        ).hexdigest()

    def append(
        self,
        *,
        kind,
        policyId,
        policyRevision,
        actorAccountId,
        requestId,
        status,
        payloadHash,
        atMs,
    ):
        self.ensure_capacity(1)
        body = dict(
            schemaVersion=1,
            sequence=len(self._events) + 1,
            kind=kind,
            coreId=self._core,
            homeId=self._home,
            policyId=policyId,
            policyRevision=policyRevision,
            actorAccountId=actorAccountId,
            requestId=requestId,
            status=status,
            payloadHash=payloadHash,
            atMs=atMs,
            previousHash=self._head,
        )
        digest = hashlib.sha256(
            b"larenor-comfort-audit-event-v1\0" + _json(body)
        ).hexdigest()
        event = ComfortAuditEvent(**body, entryHash=digest)
        self._events.append(event)
        self._head = digest
        return event

    def events(self):
        return list(self._events)

    def export(self):
        return dict(
            schemaVersion=1,
            chainId=self._chain,
            events=[item.model_dump(mode="json") for item in self._events],
            headHash=self._head,
            headTag=self._tag(),
        )

    @classmethod
    def restore(cls, raw, *, key, coreId, homeId, maxEvents=4096):
        try:
            if (
                not isinstance(raw, dict)
                or set(raw)
                != {"schemaVersion", "chainId", "events", "headHash", "headTag"}
                or raw["schemaVersion"] != 1
                or not re.fullmatch(r"[0-9a-f]{32}", raw["chainId"])
            ):
                raise ValueError
            events = [ComfortAuditEvent.model_validate(item) for item in raw["events"]]
            if len(events) > maxEvents:
                raise ValueError
            result = cls(
                key=key,
                coreId=coreId,
                homeId=homeId,
                maxEvents=maxEvents,
                chainId=raw["chainId"],
            )
            previous = ZERO
            for sequence, event in enumerate(events, 1):
                body = event.model_dump(mode="json", exclude={"entryHash"})
                digest = hashlib.sha256(
                    b"larenor-comfort-audit-event-v1\0" + _json(body)
                ).hexdigest()
                if (
                    event.sequence != sequence
                    or event.coreId != coreId
                    or event.homeId != homeId
                    or event.previousHash != previous
                    or not hmac.compare_digest(event.entryHash, digest)
                ):
                    raise ValueError
                result._events.append(event)
                result._head = previous = event.entryHash
            if raw["headHash"] != result._head or not hmac.compare_digest(
                raw["headTag"], result._tag()
            ):
                raise ValueError
            return result
        except (KeyError, TypeError, ValueError):
            raise StartupError("comfort_audit_invalid") from None
