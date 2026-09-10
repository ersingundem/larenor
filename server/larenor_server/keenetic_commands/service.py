"""In-process command authority. The default effect never opens a network path."""

import math
import secrets
import threading
import time
import uuid
from dataclasses import dataclass

from pydantic import ValidationError

from ..errors import ApiError
from .models import CommandPreview, CommandReceipt, CommandRequest, SecondConfirmation, TargetState


PREVIEW_TTL = 60.0
SECOND_TTL = 30.0
EFFECT_TTL = 10.0
MAX_PREVIEWS = 32
MAX_PER_ACTOR = 4
MAX_RECEIPTS = 128

RISK = {
    "guest_wifi_enable": "low",
    "guest_wifi_disable": "low",
    "client_internet_pause": "medium",
    "client_internet_resume": "medium",
    "wan_reconnect": "high",
}
RESULT = {
    "guest_wifi_enable": "enabled",
    "guest_wifi_disable": "disabled",
    "client_internet_pause": "paused",
    "client_internet_resume": "allowed",
    "wan_reconnect": "online",
}


class KeeneticEffectError(Exception):
    def __init__(self, code="keenetic_effect_failed", *, uncertain=False):
        super().__init__(code)
        self.code = code
        self.uncertain = uncertain


class UnavailableKeeneticEffect:
    """Packaged safe default: in-memory failure only, with no DNS/socket code."""

    def __call__(self, _command, _guard):
        raise KeeneticEffectError("keenetic_effect_unavailable")


@dataclass
class _Pending:
    actor_id: str
    actor_revision: int
    body: CommandRequest
    preview: CommandPreview
    created: float
    second_token: str | None = None
    second_created: float | None = None


class KeeneticCommandAuthority:
    def __init__(self, *, authorize, observe, effect=None, clock=time.monotonic):
        self._authorize = authorize
        self._observe = observe
        self._effect = effect or UnavailableKeeneticEffect()
        self._clock = clock
        self._last_clock = None
        self._lock = threading.RLock()
        self._previews = {}
        self._requests = {}
        self._request_ids = {}
        self._receipts = {}

    def _discard_pending(self, pending):
        self._previews.pop(pending.preview.id, None)
        self._requests.pop((pending.actor_id, pending.body.idempotencyKey), None)
        self._request_ids.pop((pending.actor_id, pending.body.requestId), None)

    def _discard_receipt(self, identity):
        self._receipts.pop(identity, None)
        actor_id, preview_id = identity
        for pending in tuple(self._requests.values()):
            if pending.actor_id == actor_id and pending.preview.id == preview_id:
                self._discard_pending(pending)
                break

    def _now(self):
        now = self._clock()
        if type(now) not in (int, float) or not math.isfinite(now):
            raise ApiError("server_unavailable", 503)
        if self._last_clock is not None and now < self._last_clock:
            self._previews.clear()
            self._requests.clear()
            self._request_ids.clear()
            raise ApiError("server_unavailable", 503)
        self._last_clock = now
        for identity, pending in list(self._previews.items()):
            if now - pending.created >= PREVIEW_TTL:
                self._discard_pending(pending)
        return now

    @staticmethod
    def _actor(actor):
        if (
            getattr(actor, "role", None) != "admin"
            or getattr(actor, "disabled", False)
            or getattr(actor, "must_change_password", False)
            or not getattr(actor, "session_current", True)
        ):
            raise ApiError("forbidden", 403)

    @staticmethod
    def _same(left, right):
        try:
            return TargetState.model_validate(left) == TargetState.model_validate(right)
        except ValidationError:
            raise ApiError("keenetic_command_changed", 409) from None

    def _guard(self, actor, body):
        self._actor(actor)
        if actor.revision != body.expectedUserRevision:
            raise ApiError("keenetic_command_changed", 409)
        self._authorize(actor, body.target, "write")
        current = TargetState.model_validate(self._observe(body.target))
        if not self._same(current, body.target):
            raise ApiError("keenetic_command_changed", 409)
        return current

    def preview(self, actor, body):
        body = CommandRequest.model_validate(body)
        with self._lock:
            now = self._now()
            self._actor(actor)
            key = (actor.id, body.idempotencyKey)
            old = self._requests.get(key)
            if old is not None:
                if old.body != body:
                    raise ApiError("idempotency_conflict", 409)
                receipt = self._receipts.get((actor.id, old.preview.id))
                if receipt is not None:
                    return {"receipt": receipt.model_dump()}
                return {"preview": old.preview.model_dump()}
            request_key = (actor.id, body.requestId)
            if request_key in self._request_ids:
                raise ApiError("idempotency_conflict", 409)
            if len(self._previews) >= MAX_PREVIEWS or sum(
                pending.actor_id == actor.id for pending in self._previews.values()
            ) >= MAX_PER_ACTOR:
                raise ApiError("keenetic_command_limit", 429)
            self._guard(actor, body)
            preview = CommandPreview(
                id=uuid.uuid4().hex,
                confirmToken=secrets.token_urlsafe(32),
                requestId=body.requestId,
                action=body.action,
                risk=RISK[body.action],
                status="accepted",
                target=body.target,
                expiresInMs=60000,
            )
            pending = _Pending(actor.id, actor.revision, body, preview, now)
            self._previews[preview.id] = pending
            self._requests[key] = pending
            self._request_ids[request_key] = pending
            return {"preview": preview.model_dump()}

    def _pending_or_receipt(self, actor, preview_id):
        receipt = self._receipts.get((actor.id, preview_id))
        if receipt is not None:
            return None, {"receipt": receipt.model_dump()}
        pending = self._previews.get(preview_id)
        if pending is None or pending.actor_id != actor.id:
            raise ApiError("keenetic_preview_invalid", 409)
        return pending, None

    def _finish(self, pending, status, code, transitions):
        receipt = CommandReceipt(
            requestId=pending.body.requestId,
            action=pending.body.action,
            target=pending.body.target,
            status=status,
            code=code,
            transitions=transitions,
        )
        self._previews.pop(pending.preview.id, None)
        while len(self._receipts) >= MAX_RECEIPTS:
            self._discard_receipt(next(iter(self._receipts)))
        self._receipts[(pending.actor_id, pending.preview.id)] = receipt
        return {"receipt": receipt.model_dump()}

    def cancel(self, actor, preview_id):
        with self._lock:
            self._now()
            self._actor(actor)
            pending, result = self._pending_or_receipt(actor, preview_id)
            if result is not None:
                return result
            self._authorize(actor, pending.body.target, "write")
            return self._finish(pending, "cancelled", "cancelled", ["accepted", "cancelled"])

    def confirm(self, actor, preview_id, token):
        with self._lock:
            now = self._now()
            self._actor(actor)
            pending, result = self._pending_or_receipt(actor, preview_id)
            if result is not None:
                return result
            if pending.actor_revision != actor.revision:
                raise ApiError("keenetic_command_changed", 409)
            if pending.preview.risk == "high" and pending.second_token is None:
                if not secrets.compare_digest(token, pending.preview.confirmToken):
                    raise ApiError("keenetic_confirmation_invalid", 409)
                pending.second_token = secrets.token_urlsafe(32)
                pending.second_created = now
                return {"confirmation": SecondConfirmation(
                    token=pending.second_token, risk="high", expiresInMs=30000
                ).model_dump()}
            expected = pending.second_token or pending.preview.confirmToken
            if not secrets.compare_digest(token, expected):
                raise ApiError("keenetic_confirmation_invalid", 409)
            if pending.second_created is not None and now - pending.second_created >= SECOND_TTL:
                self._discard_pending(pending)
                raise ApiError("keenetic_preview_invalid", 409)

            # Consume the token before the first possible effect. No exception can
            # make this preview executable again.
            self._previews.pop(preview_id, None)
            started = now
            dispatched = False
            try:
                self._guard(actor, pending.body)

                def guard():
                    if self._clock() - started >= EFFECT_TTL:
                        raise KeeneticEffectError("keenetic_effect_timeout", uncertain=True)
                    self._guard(actor, pending.body)

                dispatched = True
                self._effect(pending.body, guard)
                if self._clock() - started >= EFFECT_TTL:
                    raise KeeneticEffectError("keenetic_effect_timeout", uncertain=True)
                self._actor(actor)
                if actor.revision != pending.body.expectedUserRevision:
                    raise ApiError("keenetic_command_changed", 409)
                self._authorize(actor, pending.body.target, "write")
                observed = TargetState.model_validate(self._observe(pending.body.target))
                if (
                    observed.coreId != pending.body.target.coreId
                    or observed.homeId != pending.body.target.homeId
                    or observed.resourceId != pending.body.target.resourceId
                    or observed.resourceRevision != pending.body.target.resourceRevision
                    or observed.aclRevision != pending.body.target.aclRevision
                    or observed.bindingId != pending.body.target.bindingId
                    or observed.bindingRevision != pending.body.target.bindingRevision
                    or observed.serviceId != pending.body.target.serviceId
                    or observed.serviceRevision != pending.body.target.serviceRevision
                    or observed.firmwareVersion != pending.body.target.firmwareVersion
                    or observed.firmwareRevision != pending.body.target.firmwareRevision
                    or observed.targetKind != pending.body.target.targetKind
                    or observed.targetId != pending.body.target.targetId
                    or observed.stateRevision <= pending.body.target.stateRevision
                    or observed.value != RESULT[pending.body.action]
                ):
                    raise KeeneticEffectError("keenetic_result_unknown", uncertain=True)
                return self._finish(pending, "succeeded", "succeeded", ["accepted", "executing", "succeeded"])
            except KeeneticEffectError as error:
                status = "unknown" if error.uncertain else "failed"
                return self._finish(pending, status, error.code, ["accepted", "executing", status])
            except ApiError:
                if not dispatched:
                    raise
                # Authorization/revision changed after dispatch may mean the router
                # changed even though Core can no longer verify it.
                return self._finish(pending, "unknown", "keenetic_result_unknown", ["accepted", "executing", "unknown"])
            except Exception:
                return self._finish(pending, "unknown", "keenetic_effect_unknown", ["accepted", "executing", "unknown"])
