"""Bounded, read-only Home Assistant automation trace observations."""

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import re

from ..errors import ApiError
from ..home_assistant.read_only_websocket import (
    HomeAssistantReadOnlyWebSocket,
    HomeAssistantWebSocketError,
)
from ..home_resources.models import ActorFacts


_ENTITY = re.compile(r"automation\.[a-z0-9_]{1,117}\Z")
_OPAQUE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")


def _canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"),
        ensure_ascii=True, allow_nan=False,
    ).encode("ascii")


def _timestamp(value):
    if type(value) is not str or not 1 <= len(value) <= 40:
        raise ValueError
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError
    return round(parsed.astimezone(timezone.utc).timestamp() * 1000)


@dataclass(frozen=True)
class AutomationTraceObservation:
    resource_id: str
    resource_revision: int
    binding_id: str
    binding_revision: int
    service_id: str
    service_revision: int
    entity_id: str
    registry_unique_id: str
    run_id: str
    context_id: str
    occurred_at_ms: int
    trace_digest: str

    def evidence(self):
        return {
            "provider": "home_assistant_trace",
            "resourceId": self.resource_id,
            "resourceRevision": self.resource_revision,
            "bindingId": self.binding_id,
            "bindingRevision": self.binding_revision,
            "serviceId": self.service_id,
            "serviceRevision": self.service_revision,
            "entityId": self.entity_id,
            "registryUniqueId": self.registry_unique_id,
            "runId": self.run_id,
            "contextId": self.context_id,
            "traceDigest": self.trace_digest,
        }


class HomeAssistantAutomationTraceObserver:
    """Read one retained trace through an existing authorized HA binding."""

    def __init__(self, adapter_provider, clock, *, websocket_factory=None):
        self._adapter_provider = adapter_provider
        self._clock = clock
        self._websocket_factory = websocket_factory or HomeAssistantReadOnlyWebSocket

    def _prepared(self, actor, resource_id):
        adapter = self._adapter_provider()
        scope = adapter.resources.scope
        with adapter._tx(
            actor, scope.coreId, scope.homeId, admin=True, consume_rate_limit=False
        ) as (connection, facts):
            fingerprint, row, _ref, binding, service = adapter._facts(
                connection, facts, resource_id
            )
            if binding is None or _ENTITY.fullmatch(binding.entityId) is None:
                raise ApiError("automation_trial_trace_source_unsupported", 409)
            service = adapter.services._authenticated_home_assistant_connection(
                connection, service.id, service.revision
            )
            resource_revision = row["revision"]

        def guard():
            adapter._fresh(
                actor, scope.coreId, scope.homeId, resource_id, fingerprint,
                None, lambda: False, admin=True, consume_rate_limit=False,
                authority_guard=lambda connection: (
                    adapter.services._authenticated_home_assistant_connection(
                        connection, service.id, service.revision
                    )
                ),
            )

        return binding, service, resource_revision, guard

    def assert_current_in(self, connection, actor, observation):
        adapter = self._adapter_provider()
        adapter.auth.assert_current(connection, actor)
        adapter.resources._check_context(
            connection,
            adapter.resources.scope.coreId,
            adapter.resources.scope.homeId,
        )
        adapter.resources._state(connection)
        account = connection.execute(
            "SELECT * FROM users WHERE id=?", (actor.id,)
        ).fetchone()
        if account is None:
            raise ApiError("invalid_session", 401)
        facts = ActorFacts(
            userId=account["id"], revision=account["revision"],
            role=account["role"], disabled=bool(account["disabled"]),
            mustChangePassword=bool(account["must_change_password"]),
            sessionCurrent=True,
        )
        try:
            _fingerprint, row, _ref, binding, service = adapter._facts(
                connection, facts, observation.resource_id
            )
            service = adapter.services._authenticated_home_assistant_connection(
                connection, service.id, service.revision
            )
        except (AttributeError, TypeError):
            raise ApiError("automation_trial_trace_source_changed", 409) from None
        if (
            row["revision"] != observation.resource_revision
            or binding.id != observation.binding_id
            or binding.revision != observation.binding_revision
            or binding.entityId != observation.entity_id
            or service.id != observation.service_id
            or service.revision != observation.service_revision
        ):
            raise ApiError("automation_trial_trace_source_changed", 409)

    @staticmethod
    def _registry_entry(entries, entity_id):
        matches = [item for item in entries if item.get("entity_id") == entity_id]
        if len(matches) != 1:
            raise ApiError("automation_trial_trace_source_changed", 409)
        item = matches[0]
        unique_id = item.get("unique_id")
        platform = item.get("platform")
        if (
            type(unique_id) is not str
            or _OPAQUE.fullmatch(unique_id) is None
            or platform != "automation"
            or item.get("disabled_by") is not None
        ):
            raise ApiError("automation_trial_trace_source_unsupported", 409)
        return unique_id

    @staticmethod
    def _summary(item, item_id, starts_at_ms, ends_at_ms, now_ms):
        try:
            run_id = item["run_id"]
            timestamp = item["timestamp"]
            occurred_at_ms = _timestamp(timestamp["start"])
            if (
                item.get("domain") != "automation"
                or item.get("item_id") != item_id
                or item.get("state") != "stopped"
                or item.get("not_triggered") is True
                or type(run_id) is not str
                or _OPAQUE.fullmatch(run_id) is None
                or type(timestamp) is not dict
                or timestamp.get("finish") is None
                or not starts_at_ms <= occurred_at_ms < ends_at_ms
                or occurred_at_ms > now_ms + 30_000
            ):
                return None
            _timestamp(timestamp["finish"])
            return occurred_at_ms, run_id
        except (KeyError, TypeError, ValueError, OverflowError):
            return None

    def latest(self, actor, resource_id, starts_at_ms, ends_at_ms):
        binding, service, resource_revision, guard = self._prepared(
            actor, resource_id
        )
        try:
            with self._websocket_factory(service).session(
                timeout=8.0, before_io=guard, after_io=guard,
            ) as session:
                unique_id = self._registry_entry(
                    session.list_entity_registry(), binding.entityId
                )
                candidates = [
                    value for item in session.list_automation_traces(unique_id)
                    if (value := self._summary(
                        item, unique_id, starts_at_ms, ends_at_ms,
                        round(float(self._clock()) * 1000),
                    )) is not None
                ]
                if not candidates:
                    raise ApiError("automation_trial_trace_history_empty", 409)
                occurred_at_ms, run_id = max(candidates)
                detail = session.get_automation_trace(unique_id, run_id)
                guard()
        except ApiError:
            raise
        except HomeAssistantWebSocketError as error:
            code = (
                "automation_trial_trace_unsupported"
                if error.code == "unsupported"
                else "automation_trial_trace_unavailable"
            )
            raise ApiError(code, 503) from None
        try:
            context = detail["context"]
            if (
                detail.get("domain") != "automation"
                or detail.get("item_id") != unique_id
                or detail.get("run_id") != run_id
                or type(context) is not dict
                or type(context.get("id")) is not str
                or _OPAQUE.fullmatch(context["id"]) is None
                or self._summary(
                    detail, unique_id, starts_at_ms, ends_at_ms,
                    round(float(self._clock()) * 1000),
                ) != (occurred_at_ms, run_id)
            ):
                raise ValueError
            digest = hashlib.sha256(
                b"larenor-ha-automation-trace-v1\0" + _canonical(detail)
            ).hexdigest()
        except (KeyError, TypeError, ValueError, OverflowError, UnicodeError):
            raise ApiError("automation_trial_trace_invalid", 502) from None
        return AutomationTraceObservation(
            resource_id=resource_id,
            resource_revision=resource_revision,
            binding_id=binding.id,
            binding_revision=binding.revision,
            service_id=service.id,
            service_revision=service.revision,
            entity_id=binding.entityId,
            registry_unique_id=unique_id,
            run_id=run_id,
            context_id=context["id"],
            occurred_at_ms=occurred_at_ms,
            trace_digest=digest,
        )
