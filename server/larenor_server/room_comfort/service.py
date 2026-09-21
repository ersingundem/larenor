import hashlib
import hmac
import json
import secrets
import sqlite3

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .api_models import ConfirmComfortPlan, PreviewComfortPlan, PublishComfortPlan
from .models import (
    ComfortAuthority,
    ComfortCommandResult,
    ComfortDeviceReadback,
    ComfortPlan,
    ComfortPolicy,
    ComfortPreview,
    ComfortReceipt,
)
from .planner import ComfortPlanner


MAX_PLANS = 64
MAX_PREVIEWS = 128


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class RoomComfortService:
    """Persistent, authenticated plan review; device dispatch stays external."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.scope = HomeScope.model_validate(context.model_dump())

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT role,disabled,must_change_password,revision FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if (
            row is None
            or row["disabled"]
            or row["must_change_password"]
            or row["role"] != "admin"
        ):
            raise ApiError("forbidden", 403)
        return row["revision"]

    def _tag(self, kind, values):
        return hmac.new(
            self._key,
            b"larenor-room-comfort-v1\0" + kind.encode() + b"\0" + _canonical(values).encode(),
            hashlib.sha256,
        ).hexdigest()

    def _plan_values(self, row):
        return [
            row["id"], row["policy_json"], row["plan_json"], row["readbacks_json"],
            row["actor_id"], row["family_id"], row["created_at"],
        ]

    def _preview_values(self, row):
        return [
            row["id"], row["request_id"], row["plan_id"], row["actor_id"],
            row["family_id"], row["token_hash"], row["expires_at"], row["receipt_json"],
        ]

    def _plan_row(self, connection, plan_id):
        row = connection.execute(
            "SELECT * FROM room_comfort_plans WHERE id=?", (plan_id,)
        ).fetchone()
        if row is None or not hmac.compare_digest(
            row["envelope_tag"], self._tag("plan", self._plan_values(row))
        ):
            raise ApiError("comfort_storage_unavailable", 503)
        try:
            policy = ComfortPolicy.model_validate_json(row["policy_json"])
            plan = ComfortPlan.model_validate_json(row["plan_json"])
            readbacks = [
                ComfortDeviceReadback.model_validate(value)
                for value in json.loads(row["readbacks_json"])
            ]
        except (ValueError, TypeError, json.JSONDecodeError):
            raise ApiError("comfort_storage_unavailable", 503) from None
        if plan.planId != row["id"] or policy.policyId != plan.policyId:
            raise ApiError("comfort_storage_unavailable", 503)
        return row, policy, plan, readbacks

    def _preview_row(self, connection, preview_id):
        row = connection.execute(
            "SELECT * FROM room_comfort_previews WHERE id=?", (preview_id,)
        ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        if not hmac.compare_digest(
            row["envelope_tag"], self._tag("preview", self._preview_values(row))
        ):
            raise ApiError("comfort_storage_unavailable", 503)
        return row

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                state = connection.execute(
                    "SELECT plan_id FROM room_comfort_state WHERE singleton=1"
                ).fetchall()
                if len(state) != 1:
                    raise ValueError
                rows = connection.execute(
                    "SELECT * FROM room_comfort_plans ORDER BY created_at,id LIMIT ?",
                    (MAX_PLANS + 1,),
                ).fetchall()
                previews = connection.execute(
                    "SELECT * FROM room_comfort_previews ORDER BY expires_at,id LIMIT ?",
                    (MAX_PREVIEWS + 1,),
                ).fetchall()
                if len(rows) > MAX_PLANS or len(previews) > MAX_PREVIEWS:
                    raise ValueError
                plan_ids = {row["id"] for row in rows}
                if state[0]["plan_id"] is not None and state[0]["plan_id"] not in plan_ids:
                    raise ValueError
                for row in rows:
                    self._plan_row(connection, row["id"])
                for row in previews:
                    if row["plan_id"] not in plan_ids:
                        raise ValueError
                    self._preview_row(connection, row["id"])
        except (sqlite3.Error, ValueError, ApiError):
            raise StartupError("invalid_room_comfort_storage") from None

    def publish(self, actor, core_id, home_id, value):
        body = PublishComfortPlan.model_validate(value)
        self._scope(core_id, home_id)
        now = int(self.settings.clock() * 1000)
        try:
            with self.db.transaction() as connection:
                revision = self._actor(connection, actor)
                if body.expectedHomeRevision != 1:
                    raise ApiError("revision_conflict", 409)
                authority = ComfortAuthority(
                    schemaVersion=1, coreId=core_id, homeId=home_id,
                    homeRevision=1, accountId=actor.id, accountRevision=revision,
                    sessionFamilyId=actor.family_id, role="admin", active=True,
                    canManageComfort=True,
                )
                planner = ComfortPlanner(
                    authorityResolver=lambda _account: authority,
                    policyResolver=lambda _policy: body.policy,
                )
                plan = planner.plan(
                    authority, body.policy, body.climate, body.weather,
                    body.occupancy, nowMs=now, overrides=body.overrides,
                )
                expected = {
                    (item.room.roomId, device.kind): device
                    for item in plan.items
                    for device in (item.room.hvac, item.room.window)
                }
                observed = {(item.roomId, item.device.kind): item.device for item in body.readbacks}
                if expected != observed:
                    raise ApiError("revision_conflict", 409)
                policy_json = body.policy.model_dump_json()
                plan_json = plan.model_dump_json()
                readbacks_json = _canonical(
                    [item.model_dump(mode="json") for item in body.readbacks]
                )
                old = connection.execute(
                    "SELECT * FROM room_comfort_plans WHERE id=?", (plan.planId,)
                ).fetchone()
                values = [plan.planId, policy_json, plan_json, readbacks_json,
                          actor.id, actor.family_id, plan.generatedAtMs / 1000]
                tag = self._tag("plan", values)
                if old is None:
                    if connection.execute("SELECT COUNT(*) FROM room_comfort_plans").fetchone()[0] >= MAX_PLANS:
                        raise ApiError("comfort_limit_reached", 429)
                    connection.execute(
                        "INSERT INTO room_comfort_plans VALUES(?,?,?,?,?,?,?,?)",
                        (*values, tag),
                    )
                elif self._plan_values(old) != values or not hmac.compare_digest(old["envelope_tag"], tag):
                    raise ApiError("idempotency_conflict", 409)
                connection.execute(
                    "UPDATE room_comfort_state SET plan_id=? WHERE singleton=1",
                    (plan.planId,),
                )
                return {"schemaVersion": 1, "plan": plan}
        except ApiError:
            raise
        except (sqlite3.Error, ValueError):
            raise ApiError("comfort_storage_unavailable", 503) from None

    def current(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                self._actor(connection, actor)
                state = connection.execute(
                    "SELECT plan_id FROM room_comfort_state WHERE singleton=1"
                ).fetchone()
                if state is None or state["plan_id"] is None:
                    raise ApiError("not_found", 404)
                _row, _policy, plan, _readbacks = self._plan_row(connection, state["plan_id"])
                if plan.actorAccountId != actor.id or plan.sessionFamilyId != actor.family_id:
                    raise ApiError("revision_conflict", 409)
                return {"schemaVersion": 1, "plan": plan}
        except ApiError:
            raise
        except sqlite3.Error:
            raise ApiError("comfort_storage_unavailable", 503) from None

    @staticmethod
    def _commands(plan, readbacks):
        desired = {
            (item.room.roomId, "hvac"): (item.room.hvac, item.hvacMode)
            for item in plan.items
        } | {
            (item.room.roomId, "window"): (item.room.window, item.windowState)
            for item in plan.items
        }
        observed = {(item.roomId, item.device.kind): item for item in readbacks}
        if set(desired) != set(observed):
            raise ApiError("revision_conflict", 409)
        return [(key, desired[key], observed[key]) for key in sorted(desired)
                if desired[key][1] != observed[key].state]

    def preview(self, actor, core_id, home_id, value):
        body = PreviewComfortPlan.model_validate(value)
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        try:
            with self.db.transaction() as connection:
                revision = self._actor(connection, actor)
                state = connection.execute("SELECT plan_id FROM room_comfort_state WHERE singleton=1").fetchone()
                if state is None or state["plan_id"] != body.expectedPlanId:
                    raise ApiError("revision_conflict", 409)
                _row, policy, plan, readbacks = self._plan_row(connection, body.expectedPlanId)
                if (body.expectedHomeRevision, body.expectedPolicyRevision) != (plan.homeRevision, plan.policyRevision):
                    raise ApiError("revision_conflict", 409)
                if (plan.actorAccountId, plan.accountRevision, plan.sessionFamilyId) != (actor.id, revision, actor.family_id):
                    raise ApiError("revision_conflict", 409)
                commands = self._commands(plan, readbacks)
                if not commands:
                    raise ApiError("invalid_request")
                old = connection.execute("SELECT * FROM room_comfort_previews WHERE request_id=?", (body.requestId,)).fetchone()
                if old is not None:
                    self._preview_row(connection, old["id"])
                    if (old["plan_id"], old["actor_id"], old["family_id"]) != (plan.planId, actor.id, actor.family_id):
                        raise ApiError("idempotency_conflict", 409)
                    raise ApiError("preview_already_created", 409)
                if connection.execute("SELECT COUNT(*) FROM room_comfort_previews").fetchone()[0] >= MAX_PREVIEWS:
                    raise ApiError("comfort_limit_reached", 429)
                preview_id, token = secrets.token_hex(16), secrets.token_urlsafe(32)
                expires = now + policy.previewTtlMs / 1000
                token_hash = hashlib.sha256(token.encode("ascii")).hexdigest()
                values = [preview_id, body.requestId, plan.planId, actor.id,
                          actor.family_id, token_hash, expires, None]
                connection.execute(
                    "INSERT INTO room_comfort_previews VALUES(?,?,?,?,?,?,?,?,?)",
                    (*values, self._tag("preview", values)),
                )
                preview = ComfortPreview(
                    schemaVersion=1, previewId=preview_id, confirmToken=token,
                    requestId=body.requestId, planId=plan.planId,
                    expiresAtMs=int(expires * 1000), commandCount=len(commands),
                )
                return {"schemaVersion": 1, "preview": preview}
        except ApiError:
            raise
        except (sqlite3.Error, ValueError):
            raise ApiError("comfort_storage_unavailable", 503) from None

    def confirm(self, actor, core_id, home_id, preview_id, value):
        body = ConfirmComfortPlan.model_validate(value)
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        try:
            with self.db.transaction() as connection:
                revision = self._actor(connection, actor)
                row = self._preview_row(connection, preview_id)
                if (row["plan_id"], row["actor_id"], row["family_id"]) != (body.expectedPlanId, actor.id, actor.family_id):
                    raise ApiError("revision_conflict", 409)
                if not hmac.compare_digest(row["token_hash"], hashlib.sha256(body.confirmToken.encode("ascii")).hexdigest()):
                    raise ApiError("invalid_request")
                _stored, _policy, plan, readbacks = self._plan_row(connection, row["plan_id"])
                state = connection.execute("SELECT plan_id FROM room_comfort_state WHERE singleton=1").fetchone()
                if (
                    state is None
                    or state["plan_id"] != plan.planId
                    or plan.policyRevision != body.expectedPolicyRevision
                    or (plan.accountRevision, plan.sessionFamilyId)
                    != (revision, actor.family_id)
                ):
                    raise ApiError("revision_conflict", 409)
                if row["receipt_json"] is not None:
                    receipt = ComfortReceipt.model_validate_json(row["receipt_json"])
                    return {"schemaVersion": 1, "receipt": receipt}
                if now > row["expires_at"]:
                    raise ApiError("preview_expired", 409)
                results = []
                for (room_id, kind), _desired, _before in self._commands(plan, readbacks):
                    command_id = hashlib.sha256((row["request_id"] + room_id + kind + plan.planId).encode()).hexdigest()[:32]
                    results.append(ComfortCommandResult(
                        schemaVersion=1, commandId=command_id, roomId=room_id,
                        targetKind=kind, status="unknown", code="worker_ack_unknown",
                        readback=None,
                    ))
                receipt = ComfortReceipt(
                    schemaVersion=1, requestId=row["request_id"], planId=plan.planId,
                    status="unknown", results=results, completedAtMs=int(now * 1000),
                )
                receipt_json = receipt.model_dump_json()
                values = [row["id"], row["request_id"], row["plan_id"], row["actor_id"],
                          row["family_id"], row["token_hash"], row["expires_at"], receipt_json]
                connection.execute(
                    "UPDATE room_comfort_previews SET receipt_json=?,envelope_tag=? WHERE id=?",
                    (receipt_json, self._tag("preview", values), preview_id),
                )
                return {"schemaVersion": 1, "receipt": receipt}
        except ApiError:
            raise
        except (sqlite3.Error, ValueError):
            raise ApiError("comfort_storage_unavailable", 503) from None
