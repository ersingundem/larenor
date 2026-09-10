from dataclasses import dataclass
import re
import threading
import uuid

from ..errors import ApiError
from .models import ConfirmRequest, PowerPreview, PowerReceipt, PreviewRequest, ProxmoxGuestDescriptor
from .storage import PowerReceiptStore


POLICY = {
    "start": ("low", frozenset({"stopped"}), "running"),
    "shutdown": ("moderate", frozenset({"running"}), "stopped"),
    "stop": ("high", frozenset({"running"}), "stopped"),
    "reboot": ("high", frozenset({"running"}), "running"),
    "reset": ("high", frozenset({"running"}), "running"),
    "suspend": ("moderate", frozenset({"running"}), "suspended"),
    "resume": ("low", frozenset({"suspended"}), "running"),
}
MAX_PREVIEWS = 32
MAX_ACTOR_PREVIEWS = 4
PREVIEW_TTL = 60


class UnavailableGuestProvider:
    def resolve(self, _resource_id):
        return None


class UnavailablePowerExecutor:
    def execute(self, _descriptor, _action, _guard):
        raise RuntimeError("packaged_effect_unavailable")


@dataclass
class _PendingPreview:
    public: PowerPreview
    body: PreviewRequest
    actor_id: str
    descriptor: ProxmoxGuestDescriptor
    consumed: bool = False


class ProxmoxPowerAuthority:
    def __init__(self, registry, auth, settings, key, provider=None, executor=None):
        self.registry, self.auth, self.settings = registry, auth, settings
        self.provider = provider or UnavailableGuestProvider()
        self.executor = executor or UnavailablePowerExecutor()
        self.store = PowerReceiptStore(registry.db, settings, key)
        self._previews = {}
        self._lock = threading.Lock()

    def close(self):
        with self._lock:
            self._previews.clear()

    @staticmethod
    def _descriptor(value, resource_id):
        if not isinstance(value, ProxmoxGuestDescriptor) or value.resource_id != resource_id:
            raise ApiError("not_found", 404)
        ids = (value.resource_id,)
        revisions = (value.binding_revision, value.service_revision, value.status_revision)
        if (any(not isinstance(x, str) or not re.fullmatch(r"[0-9a-f]{32}", x) for x in ids)
                or any(not isinstance(x, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", x) for x in (value.binding_id, value.service_id))
                or any(type(x) is not int or not 1 <= x <= 2**63 - 1 for x in revisions)
                or value.guest_kind not in ("qemu", "lxc")
                or value.status not in ("running", "stopped", "suspended", "unavailable")):
            raise ApiError("server_unavailable", 503)
        return value

    @staticmethod
    def _same_descriptor(left, right):
        return left == right

    @staticmethod
    def _id(value):
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{32}", value):
            raise ApiError("invalid_request")

    def _authorize(self, actor, core_id, home_id, resource_id, body):
        if actor.role != "admin":
            raise ApiError("forbidden", 403)
        self.registry.authorize(
            actor, core_id, home_id, resource_id, "write",
            expected_revision=body.expectedResourceRevision,
            expected_acl_revision=body.expectedAclRevision,
            expected_user_revision=body.expectedUserRevision,
        )

    def preview(self, actor, core_id, home_id, resource_id, body):
        body = PreviewRequest.model_validate(body)
        self._authorize(actor, core_id, home_id, resource_id, body)
        if self.store.get(body.requestId) is not None:
            raise ApiError("revision_conflict", 409)
        current = self._descriptor(self.provider.resolve(resource_id), resource_id)
        expected = (
            body.expectedBindingId, body.expectedBindingRevision,
            body.expectedServiceId, body.expectedServiceRevision,
            body.expectedGuestKind, body.expectedCurrentState, body.expectedStatusRevision,
        )
        actual = (
            current.binding_id, current.binding_revision,
            current.service_id, current.service_revision,
            current.guest_kind, current.status, current.status_revision,
        )
        risk, allowed, target = POLICY[body.action]
        if expected != actual or current.status not in allowed:
            raise ApiError("revision_conflict", 409)
        now = self.settings.clock()
        public = PowerPreview(
            id=uuid.uuid4().hex, requestId=body.requestId, action=body.action,
            riskClass=risk, requiresSecondConfirmation=risk == "high",
            guestKind=current.guest_kind, currentState=current.status,
            expectedResultState=target, expiresAt=now + PREVIEW_TTL,
        )
        with self._lock:
            self._purge(now)
            if len(self._previews) >= MAX_PREVIEWS or sum(p.actor_id == actor.id for p in self._previews.values()) >= MAX_ACTOR_PREVIEWS:
                raise ApiError("rate_limited", 429)
            self.store.append_preview(body, current, actor.id, "previewed")
            self._previews[public.id] = _PendingPreview(public, body, actor.id, current)
        return {"preview": public.model_dump()}

    def _purge(self, now):
        self._previews = {key: value for key, value in self._previews.items()
                          if not value.consumed and value.public.expiresAt > now}

    def cancel(self, actor, core_id, home_id, resource_id, preview_id):
        self._id(preview_id)
        with self._lock:
            pending = self._previews.get(preview_id)
            if (pending is None or pending.actor_id != actor.id or pending.consumed
                    or pending.descriptor.resource_id != resource_id
                    or (core_id, home_id) != (self.registry.scope.coreId, self.registry.scope.homeId)):
                raise ApiError("revision_conflict", 409)
            self.store.append_preview(pending.body, pending.descriptor, actor.id, "preview_cancelled")
            pending.consumed = True
            self._previews.pop(preview_id, None)

    def confirm(self, actor, core_id, home_id, resource_id, preview_id, body, *, disconnected=None):
        body = ConfirmRequest.model_validate(body)
        self._id(preview_id)
        with self._lock:
            pending = self._previews.get(preview_id)
            if (pending is None or pending.actor_id != actor.id or pending.consumed
                    or pending.public.expiresAt <= self.settings.clock()):
                self._previews.pop(preview_id, None)
                raise ApiError("revision_conflict", 409)
            pending.consumed = True
            self._previews.pop(preview_id, None)
        if pending.public.requestId != body.requestId:
            raise ApiError("revision_conflict", 409)
        if pending.public.requiresSecondConfirmation and not body.highRiskConfirmed:
            raise ApiError("invalid_request")
        if self.store.get(body.requestId) is not None:
            raise ApiError("revision_conflict", 409)
        self._authorize(actor, core_id, home_id, resource_id, pending.body)
        current = self._descriptor(self.provider.resolve(resource_id), resource_id)
        if not self._same_descriptor(current, pending.descriptor):
            raise ApiError("revision_conflict", 409)
        started = self.settings.clock()
        accepted = self._receipt(pending, "accepted", "accepted", current, started)
        self.store.put(accepted, resource_id, actor.id)
        executing = self._receipt(pending, "executing", "executing", current, started)
        self.store.put(executing, resource_id, actor.id)

        def guard(*, descriptor=True):
            if self.settings.clock() * 1000 > started * 1000 + body.deadlineMs:
                raise TimeoutError()
            if disconnected is not None and disconnected():
                raise ConnectionError()
            with self.registry.db.connection() as connection:
                self.auth.assert_current(connection, actor)
            self._authorize(actor, core_id, home_id, resource_id, pending.body)
            if descriptor:
                observed = self._descriptor(self.provider.resolve(resource_id), resource_id)
                if observed != current:
                    raise RuntimeError("descriptor_changed")

        try:
            bounded = getattr(self.executor, "execute_bounded", None)
            if callable(bounded):
                effect = bounded(
                    current, pending.body.action, guard,
                    preview=pending.body, deadline_ms=body.deadlineMs,
                    continuation_guard=lambda: guard(descriptor=False),
                )
            else:
                effect = self.executor.execute(current, pending.body.action, guard)
            with self.registry.db.connection() as connection:
                self.auth.assert_current(connection, actor)
            self._authorize(actor, core_id, home_id, resource_id, pending.body)
            final = self._descriptor(self.provider.resolve(resource_id), resource_id)
            _risk, _allowed, target = POLICY[pending.body.action]
            success = (effect.outcome == "succeeded" and final.status == target
                       and final.status_revision == current.status_revision + 1
                       and final.binding_id == current.binding_id
                       and final.binding_revision == current.binding_revision
                       and final.service_id == current.service_id
                       and final.service_revision == current.service_revision
                       and self.settings.clock() * 1000 <= started * 1000 + body.deadlineMs)
            if success:
                receipt = self._receipt(
                    pending, "succeeded", "completed", final, started,
                    operation_ref=effect.operation_ref)
            elif effect.outcome == "failed":
                receipt = self._receipt(pending, "failed", "effect_failed", final, started)
            elif effect.outcome == "cancelled":
                receipt = self._receipt(pending, "cancelled", "cancelled", final, started)
            else:
                receipt = self._receipt(
                    pending, "unknown", "outcome_uncertain", final, started,
                    operation_ref=effect.operation_ref,
                )
        except Exception:
            observed = self.provider.resolve(resource_id)
            final = current if not isinstance(observed, ProxmoxGuestDescriptor) else observed
            receipt = self._receipt(pending, "unknown", "outcome_uncertain", final, started)
        self.store.put(receipt, resource_id, actor.id)
        return {"receipt": receipt.model_dump()}

    def _receipt(self, pending, state, code, descriptor, created, *, operation_ref=None):
        return PowerReceipt(
            requestId=pending.body.requestId, action=pending.body.action,
            state=state, resultCode=code, guestState=descriptor.status,
            statusRevision=descriptor.status_revision, causalityVerified=False,
            userRevision=pending.body.expectedUserRevision,
            resourceRevision=pending.body.expectedResourceRevision,
            aclRevision=pending.body.expectedAclRevision,
            bindingRevision=pending.body.expectedBindingRevision,
            serviceRevision=pending.body.expectedServiceRevision,
            operationRef=operation_ref,
            createdAt=created, updatedAt=self.settings.clock(),
        )

    def result(self, actor, core_id, home_id, resource_id, request_id):
        self._id(request_id)
        if actor.role != "admin":
            raise ApiError("forbidden", 403)
        self.registry.get(actor, core_id, home_id, resource_id)
        receipt = self.store.get(request_id, resource_id=resource_id, user_id=actor.id)
        if receipt is None:
            raise ApiError("not_found", 404)
        return {"receipt": receipt.model_dump()}

    def receipt_event_payload(self, request_id):
        receipt = self.store.get(request_id)
        if receipt is None:
            raise ApiError("not_found", 404)
        return {"schemaVersion": 1, "idempotencyKey": receipt.requestId,
                "state": receipt.state, "resultCode": receipt.resultCode}

    def journal(self, actor, core_id, home_id, resource_id, limit):
        if actor.role != "admin":
            raise ApiError("forbidden", 403)
        self.registry.get(actor, core_id, home_id, resource_id)
        return self.store.journal(resource_id, limit)

    def journal_integrity(self, actor, core_id, home_id, resource_id):
        if actor.role != "admin":
            raise ApiError("forbidden", 403)
        self.registry.get(actor, core_id, home_id, resource_id)
        return self.store.integrity()
