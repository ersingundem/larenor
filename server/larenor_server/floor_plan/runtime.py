"""Current Core authority adapter for the persistent floor-plan foundation."""

import hashlib
import hmac
import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone

from cryptography.exceptions import InvalidTag

from ..auth import Principal
from ..errors import ApiError
from ..home_assistant import schema as ha_schema
from ..home_resources.models import ActorFacts
from .service import (
    ENTITY_STATES,
    MAX_STATE_AGE_SECONDS,
    EntitySnapshot,
    FloorPlanAuthority,
    FloorPlanLayout,
    FloorPlanService,
)


MAX_LIVE_PROJECTIONS = 32
_UNAVAILABLE_UPSTREAM = {
    "ha_upstream_unavailable",
    "ha_upstream_unauthorized",
    "ha_projection_unsupported",
}


@dataclass(frozen=True)
class _Current:
    authority: FloorPlanAuthority
    facts: ActorFacts
    bindings: tuple[tuple[sqlite3.Row, object], ...]


@dataclass(frozen=True)
class _ResolvedAnchor:
    anchor: object
    resource_id: str
    resource_revision: int
    acl_revision: int
    binding: object | None


class FloorPlanRuntime:
    """Derives every caller-controlled revision from current signed Core state."""

    def __init__(self, database, auth, resources, home_assistant, context, key, clock):
        self.database = database
        self.auth = auth
        self.resources = resources
        self.home_assistant = home_assistant
        self.context = context
        self._key = key
        self._clock = clock
        self.service = FloorPlanService(
            database,
            audit_key=key,
            clock=clock,
            authority_guard=self._guard,
        )

    def _entity_registry_revision(self, rows: list[sqlite3.Row]) -> int:
        payload = json.dumps(
            [
                [
                    row["resource_id"],
                    row["binding_id"],
                    row["revision"],
                    hashlib.sha256(row["nonce"] + row["ciphertext"]).hexdigest(),
                ]
                for row in rows
            ],
            separators=(",", ":"),
        ).encode("ascii")
        digest = hmac.new(
            self._key, b"larenor-floor-plan-ha-registry-v1\0" + payload, hashlib.sha256
        ).digest()
        revision = int.from_bytes(digest[:8], "big") & (2**63 - 1)
        return revision or 1

    def _current(
        self,
        connection: sqlite3.Connection,
        actor: Principal,
        core_id: str,
        home_id: str,
    ) -> _Current:
        self.auth.assert_current(connection, actor)
        self.resources._check_context(connection, core_id, home_id)
        user = connection.execute("SELECT * FROM users WHERE id=?", (actor.id,)).fetchone()
        if user is None or user["disabled"] or user["must_change_password"]:
            raise ApiError("invalid_session", 401)
        facts = ActorFacts(
            userId=user["id"],
            revision=user["revision"],
            role=user["role"],
            disabled=bool(user["disabled"]),
            mustChangePassword=bool(user["must_change_password"]),
            sessionCurrent=True,
        )
        resource_state = self.resources._state(connection)
        binding_rows = ha_schema.validate(
            connection, self.home_assistant._key, self.resources.scope
        )
        bindings = tuple(
            (row, self.home_assistant._decode(row)) for row in binding_rows
        )
        layout = connection.execute(
            "SELECT revision FROM floor_plan_layouts WHERE core_id=? AND home_id=?",
            (core_id, home_id),
        ).fetchone()
        authority = FloorPlanAuthority(
            core_id=core_id,
            home_id=home_id,
            account_id=actor.id,
            session_id=actor.family_id,
            core_revision=1,
            home_revision=1,
            account_revision=user["revision"],
            layout_revision=0 if layout is None else layout["revision"],
            entity_registry_revision=self._entity_registry_revision(binding_rows),
            resource_revision=resource_state["revision"],
            grant_revision=resource_state["revision"],
            can_read=user["role"] in {"admin", "member"},
            can_edit=user["role"] == "admin",
        )
        return _Current(authority, facts, bindings)

    def authority(self, actor: Principal, core_id: str, home_id: str) -> FloorPlanAuthority:
        try:
            with self.database.connection() as connection:
                connection.execute("BEGIN")
                return self._current(connection, actor, core_id, home_id).authority
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def _validate_anchors(
        self,
        connection: sqlite3.Connection,
        current: _Current,
        layout: FloorPlanLayout,
    ) -> None:
        entities: dict[str, list[tuple[sqlite3.Row, object]]] = {}
        for row, binding in current.bindings:
            entities.setdefault(binding.entityId, []).append((row, binding))
        for anchor in layout.anchors:
            if anchor.target_kind == "resource":
                try:
                    row, ref, data = self.resources._target(connection, anchor.target_id)
                except ApiError as error:
                    if error.code == "not_found":
                        raise ApiError("not_found", 404) from None
                    raise
                if ref.kind != "resource" or row["revision"] != anchor.target_revision:
                    raise ApiError("floor_plan_authority_changed", 409)
            else:
                matches = entities.get(anchor.target_id, [])
                if len(matches) != 1:
                    raise ApiError("not_found", 404)
                binding_row, binding = matches[0]
                if binding.revision != anchor.target_revision:
                    raise ApiError("floor_plan_authority_changed", 409)
                row, ref, data = self.resources._target(
                    connection, binding_row["resource_id"]
                )
            self.resources._require(current.facts, row, ref, data, "read")

    def _guard(
        self,
        connection: sqlite3.Connection,
        actor: Principal,
        authority: FloorPlanAuthority,
        *,
        edit: bool,
        layout: FloorPlanLayout | None,
    ) -> None:
        try:
            current = self._current(
                connection, actor, authority.core_id, authority.home_id
            )
            if current.authority != authority:
                raise ApiError("floor_plan_authority_changed", 409)
            if edit and not current.authority.can_edit:
                raise ApiError("forbidden", 403)
            if layout is not None:
                self._validate_anchors(connection, current, layout)
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def _authority_guard(self, actor: Principal, authority: FloorPlanAuthority):
        def guard(connection: sqlite3.Connection) -> None:
            self._guard(
                connection,
                actor,
                authority,
                edit=False,
                layout=None,
            )

        return guard

    def _resolved_anchors(
        self,
        connection: sqlite3.Connection,
        current: _Current,
        layout: FloorPlanLayout,
    ) -> tuple[_ResolvedAnchor, ...]:
        self._validate_anchors(connection, current, layout)
        by_entity: dict[str, list[tuple[sqlite3.Row, object]]] = {}
        by_resource: dict[str, tuple[sqlite3.Row, object]] = {}
        for binding_row, binding in current.bindings:
            by_entity.setdefault(binding.entityId, []).append((binding_row, binding))
            by_resource[binding_row["resource_id"]] = (binding_row, binding)
        resolved = []
        for anchor in layout.anchors:
            if anchor.target_kind == "entity":
                matches = by_entity.get(anchor.target_id, [])
                if len(matches) != 1:
                    raise ApiError("floor_plan_authority_changed", 409)
                binding_row, binding = matches[0]
                resource_id = binding_row["resource_id"]
                resource_row, ref, data = self.resources._target(connection, resource_id)
            else:
                resource_id = anchor.target_id
                resource_row, ref, data = self.resources._target(connection, resource_id)
                match = by_resource.get(resource_id)
                binding = None if match is None else match[1]
            self.resources._require(current.facts, resource_row, ref, data, "read")
            resolved.append(
                _ResolvedAnchor(
                    anchor=anchor,
                    resource_id=resource_id,
                    resource_revision=resource_row["revision"],
                    acl_revision=resource_row["acl_revision"],
                    binding=binding,
                )
            )
        return tuple(resolved)

    @staticmethod
    def _observed_at(value: object) -> float:
        if not isinstance(value, str) or len(value) > 40:
            raise ApiError("server_unavailable", 503)
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            raise ApiError("server_unavailable", 503) from None
        if parsed.tzinfo is None:
            raise ApiError("server_unavailable", 503)
        return parsed.astimezone(timezone.utc).timestamp()

    @staticmethod
    def _none_capability() -> dict:
        return {
            "kind": "none",
            "actions": [],
            "resourceId": None,
            "resourceRevision": None,
            "aclRevision": None,
            "bindingId": None,
            "bindingRevision": None,
            "serviceRevision": None,
        }

    def _capability(self, resolved: _ResolvedAnchor, snapshot: dict | None) -> dict:
        binding = resolved.binding
        if binding is None or snapshot is None:
            return self._none_capability()
        projection = snapshot["projection"]
        ref = snapshot["ref"]
        exact = (
            ref["id"] == resolved.resource_id
            and snapshot["resourceRevision"] == resolved.resource_revision
            and snapshot["aclRevision"] == resolved.acl_revision
            and snapshot["bindingId"] == binding.id
            and snapshot["bindingRevision"] == binding.revision
            and snapshot["serviceRevision"] == binding.serviceRevision
        )
        if not exact:
            raise ApiError("floor_plan_authority_changed", 409)
        if projection["kind"] != "switch" or projection["commandAvailable"] is not True:
            return self._none_capability()
        return {
            "kind": "home_assistant.switch",
            "actions": ["turn_on", "turn_off"],
            "resourceId": resolved.resource_id,
            "resourceRevision": resolved.resource_revision,
            "aclRevision": resolved.acl_revision,
            "bindingId": binding.id,
            "bindingRevision": binding.revision,
            "serviceRevision": binding.serviceRevision,
        }

    def _live_snapshot(
        self,
        actor: Principal,
        authority: FloorPlanAuthority,
        resolved: _ResolvedAnchor,
        cancelled,
    ) -> dict | None:
        if cancelled():
            raise ApiError("request_timeout", 408)
        try:
            result = self.home_assistant.snapshot(
                actor,
                authority.core_id,
                authority.home_id,
                resolved.resource_id,
                cancelled=cancelled,
                authority_guard=self._authority_guard(actor, authority),
                consume_rate_limit=False,
            )
        except ApiError as error:
            if error.code in _UNAVAILABLE_UPSTREAM:
                return None
            raise
        return result["snapshot"]

    def replace(self, actor: Principal, core_id: str, home_id: str, body):
        authority = self.authority(actor, core_id, home_id)
        return self.service.replace_layout(
            actor,
            authority=authority,
            request_id=body.requestId,
            expected_layout_revision=body.expectedLayoutRevision,
            layout=body.to_domain(),
        )

    def read(
        self,
        actor: Principal,
        core_id: str,
        home_id: str,
        *,
        cancelled=lambda: False,
    ):
        authority = self.authority(actor, core_id, home_id)
        stored = self.service.read(actor, authority=authority)
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            current = self._current(connection, actor, core_id, home_id)
            if current.authority != authority:
                raise ApiError("floor_plan_authority_changed", 409)
            resolved = self._resolved_anchors(connection, current, stored.layout)

        self.auth.rate_limit([("floor_plan_live_read", actor.id, 60)])
        bindable = [item for item in resolved if item.binding is not None]
        selected = {item.anchor.anchor_id for item in bindable[:MAX_LIVE_PROJECTIONS]}
        snapshots: dict[str, dict] = {}
        entity_snapshots = []
        for item in resolved:
            if item.anchor.anchor_id not in selected:
                continue
            snapshot = self._live_snapshot(actor, authority, item, cancelled)
            if snapshot is None:
                continue
            snapshots[item.anchor.anchor_id] = snapshot
            if item.anchor.target_kind == "entity":
                state = snapshot["projection"]["state"]
                supported = state in ENTITY_STATES
                entity_snapshots.append(
                    EntitySnapshot(
                        entity_id=item.anchor.target_id,
                        entity_revision=item.binding.revision,
                        registry_revision=authority.entity_registry_revision,
                        source_status="verified" if supported else "unavailable",
                        state=state if supported else "unavailable",
                        observed_at=self._observed_at(snapshot["observedAt"]),
                    )
                )
        projected_entities = {
            item.entity_id: item
            for item in self.service.project_entities(
                actor,
                authority=authority,
                snapshots=tuple(entity_snapshots),
            )
        }
        projections = []
        now = self._clock()
        for item in resolved:
            anchor = item.anchor
            snapshot = snapshots.get(anchor.anchor_id)
            if anchor.target_kind == "entity":
                projection = projected_entities[anchor.target_id]
                state, status = projection.state, projection.status
            elif item.binding is None:
                state, status = "available", "live"
            elif snapshot is None:
                state, status = "unavailable", "unavailable"
            else:
                state = snapshot["projection"]["state"]
                observed_at = self._observed_at(snapshot["observedAt"])
                status = (
                    "live"
                    if now - observed_at <= MAX_STATE_AGE_SECONDS
                    else "stale"
                )
            projections.append(
                {
                    "anchorId": anchor.anchor_id,
                    "targetKind": anchor.target_kind,
                    "targetId": anchor.target_id,
                    "targetRevision": anchor.target_revision,
                    "state": state,
                    "status": status,
                    "capability": self._capability(item, snapshot),
                }
            )
        if cancelled():
            raise ApiError("request_timeout", 408)
        return {
            "stored": stored,
            "authority": authority,
            "projections": projections,
            "projectionLimit": MAX_LIVE_PROJECTIONS,
            "projectionTruncated": len(bindable) > MAX_LIVE_PROJECTIONS,
        }

    def action(
        self,
        actor: Principal,
        core_id: str,
        home_id: str,
        body,
        *,
        cancelled=lambda: False,
    ) -> dict:
        authority = self.authority(actor, core_id, home_id)
        expected = (
            body.expectedLayoutRevision,
            body.expectedEntityRegistryRevision,
            body.expectedResourceRegistryRevision,
            body.expectedGrantRevision,
        )
        current = (
            authority.layout_revision,
            authority.entity_registry_revision,
            authority.resource_revision,
            authority.grant_revision,
        )
        if expected != current:
            raise ApiError("floor_plan_authority_changed", 409)
        stored = self.service.read(actor, authority=authority)
        with self.database.connection() as connection:
            connection.execute("BEGIN")
            exact = self._current(connection, actor, core_id, home_id)
            if exact.authority != authority:
                raise ApiError("floor_plan_authority_changed", 409)
            matches = [
                item
                for item in self._resolved_anchors(connection, exact, stored.layout)
                if item.anchor.anchor_id == body.anchorId
            ]
            if len(matches) != 1:
                raise ApiError("not_found", 404)
            resolved = matches[0]
        anchor, binding = resolved.anchor, resolved.binding
        if binding is None or not binding.entityId.startswith("switch."):
            raise ApiError("invalid_request", 400)
        if (
            anchor.target_revision != body.expectedTargetRevision
            or resolved.resource_id != body.expectedResourceId
            or resolved.resource_revision != body.expectedResourceRevision
            or resolved.acl_revision != body.expectedAclRevision
            or binding.id != body.expectedBindingId
            or binding.revision != body.expectedBindingRevision
            or binding.serviceRevision != body.expectedServiceRevision
        ):
            raise ApiError("floor_plan_authority_changed", 409)
        command = {
            "schemaVersion": 1,
            "requestId": body.requestId,
            "action": body.action,
            "expectedBindingRevision": body.expectedBindingRevision,
            "expectedResourceRevision": body.expectedResourceRevision,
            "expectedAclRevision": body.expectedAclRevision,
        }
        result = self.home_assistant.command(
            actor,
            core_id,
            home_id,
            resolved.resource_id,
            command,
            cancelled=cancelled,
            authority_guard=self._authority_guard(actor, authority),
        )
        return {
            "receipt": {
                "schemaVersion": 1,
                "anchorId": anchor.anchor_id,
                "layoutRevision": authority.layout_revision,
                "entityRegistryRevision": authority.entity_registry_revision,
                "resourceRevision": authority.resource_revision,
                "grantRevision": authority.grant_revision,
                "command": result["receipt"],
            }
        }

    def export(self, actor: Principal, core_id: str, home_id: str):
        authority = self.authority(actor, core_id, home_id)
        return self.service.export(actor, authority=authority)

    def history(self, actor: Principal, core_id: str, home_id: str, limit: int):
        authority = self.authority(actor, core_id, home_id)
        return self.service.history(actor, authority=authority, limit=limit)
