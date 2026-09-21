"""Current Core authority adapter for the persistent floor-plan foundation."""

import hashlib
import hmac
import json
import sqlite3
from dataclasses import dataclass

from cryptography.exceptions import InvalidTag

from ..auth import Principal
from ..errors import ApiError
from ..home_assistant import schema as ha_schema
from ..home_resources.models import ActorFacts
from .service import FloorPlanAuthority, FloorPlanLayout, FloorPlanService


@dataclass(frozen=True)
class _Current:
    authority: FloorPlanAuthority
    facts: ActorFacts
    bindings: tuple[tuple[sqlite3.Row, object], ...]


class FloorPlanRuntime:
    """Derives every caller-controlled revision from current signed Core state."""

    def __init__(self, database, auth, resources, home_assistant, context, key, clock):
        self.database = database
        self.auth = auth
        self.resources = resources
        self.home_assistant = home_assistant
        self.context = context
        self._key = key
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

    def replace(self, actor: Principal, core_id: str, home_id: str, body):
        authority = self.authority(actor, core_id, home_id)
        return self.service.replace_layout(
            actor,
            authority=authority,
            request_id=body.requestId,
            expected_layout_revision=body.expectedLayoutRevision,
            layout=body.to_domain(),
        )

    def read(self, actor: Principal, core_id: str, home_id: str):
        authority = self.authority(actor, core_id, home_id)
        return self.service.read(actor, authority=authority)

    def export(self, actor: Principal, core_id: str, home_id: str):
        authority = self.authority(actor, core_id, home_id)
        return self.service.export(actor, authority=authority)

    def history(self, actor: Principal, core_id: str, home_id: str, limit: int):
        authority = self.authority(actor, core_id, home_id)
        return self.service.history(actor, authority=authority, limit=limit)
