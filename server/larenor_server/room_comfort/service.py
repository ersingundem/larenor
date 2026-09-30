import hashlib
import hmac
import json
import secrets
import sqlite3
import threading

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
    ComfortWorkerCommand,
    WorkerComfortReadback,
)
from .planner import ComfortPlanner

MAX_PLANS = 64
MAX_PREVIEWS = 128
MAX_DISPATCHES = MAX_PREVIEWS * 64


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class RoomComfortService:
    """Persistent, authenticated plan review; device dispatch stays external."""

    def __init__(
        self, db, auth, settings, key, context, worker=None, source_store=None,
        input_provider=None, provisioner=None,
    ):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.scope = HomeScope.model_validate(context.model_dump())
        self.worker = worker
        self.source_store = source_store
        self.input_provider = input_provider
        self.provisioner = provisioner
        self._confirm_lock = threading.Lock()

    def configuration(self, actor):
        if self.source_store is None:
            raise ApiError("comfort_source_unavailable", 503)
        return {
            "schemaVersion": 1,
            "configuration": self.source_store.get(actor),
        }

    def configure(self, actor, value):
        if self.source_store is None:
            raise ApiError("comfort_source_unavailable", 503)
        return {
            "schemaVersion": 1,
            "configuration": self.source_store.put(actor, value),
        }

    def configuration_setup(self, actor):
        if self.provisioner is None:
            raise ApiError("comfort_source_unavailable", 503)
        return self.provisioner.setup(actor)

    def configuration_entities(self, actor, service_id, revision):
        if self.provisioner is None:
            raise ApiError("comfort_source_unavailable", 503)
        return self.provisioner.entities(actor, service_id, revision)

    def refresh(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        if self.input_provider is None:
            raise ApiError("comfort_source_unavailable", 503)
        (
            home_revision, policy, climate, weather, occupancy, readbacks,
            _observed_at,
        ) = self.input_provider.inputs()
        return self._publish(
            actor,
            core_id,
            home_id,
            PublishComfortPlan(
                schemaVersion=1,
                expectedHomeRevision=home_revision,
                policy=policy,
                climate=climate,
                weather=weather,
                occupancy=occupancy,
                overrides=[],
                readbacks=readbacks,
            ),
            trusted_source=True,
        )

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

    def _dispatch_values(self, row):
        return [
            row["command_id"], row["preview_id"], row["command_json"],
            row["state"], row["result_json"], row["reserved_at"],
            row["completed_at"],
        ]

    def _dispatch_row(self, connection, command_id):
        row = connection.execute(
            "SELECT * FROM room_comfort_dispatches WHERE command_id=?",
            (command_id,),
        ).fetchone()
        if row is None or not hmac.compare_digest(
            row["envelope_tag"],
            self._tag("dispatch", self._dispatch_values(row)),
        ):
            raise ApiError("comfort_storage_unavailable", 503)
        try:
            command = ComfortWorkerCommand.model_validate_json(row["command_json"])
            result = (
                None if row["result_json"] is None else
                ComfortCommandResult.model_validate_json(row["result_json"])
            )
        except (ValueError, TypeError):
            raise ApiError("comfort_storage_unavailable", 503) from None
        if command.commandId != row["command_id"] or (
            row["state"] == "completed" and (
                result is None or result.commandId != command.commandId
            )
        ):
            raise ApiError("comfort_storage_unavailable", 503)
        return row, command, result

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
                dispatches = connection.execute(
                    "SELECT * FROM room_comfort_dispatches "
                    "ORDER BY reserved_at,command_id LIMIT ?",
                    (MAX_DISPATCHES + 1,),
                ).fetchall()
                if (
                    len(rows) > MAX_PLANS or len(previews) > MAX_PREVIEWS
                    or len(dispatches) > MAX_DISPATCHES
                ):
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
                preview_ids = {row["id"] for row in previews}
                for row in dispatches:
                    if row["preview_id"] not in preview_ids:
                        raise ValueError
                    self._dispatch_row(connection, row["command_id"])
        except (sqlite3.Error, ValueError, ApiError):
            raise StartupError("invalid_room_comfort_storage") from None

    def publish(self, actor, core_id, home_id, value):
        return self._publish(
            actor, core_id, home_id, value, trusted_source=False
        )

    def _publish(
        self, actor, core_id, home_id, value, *, trusted_source
    ):
        body = PublishComfortPlan.model_validate(value)
        self._scope(core_id, home_id)
        now = int(self.settings.clock() * 1000)
        home_revision = 1
        policy = body.policy
        source_configured = False
        if self.source_store is not None:
            try:
                home_revision, configured_policy = self.source_store.policy()
            except ApiError as error:
                if error.code != "comfort_source_not_configured":
                    raise
            else:
                if not trusted_source:
                    raise ApiError("comfort_source_managed", 409)
                if body.policy != configured_policy:
                    raise ApiError("revision_conflict", 409)
                policy = configured_policy
                source_configured = True
        if body.expectedHomeRevision != home_revision:
            raise ApiError("revision_conflict", 409)
        try:
            with self.db.transaction() as connection:
                revision = self._actor(connection, actor)
                if source_configured:
                    self.source_store.assert_policy(
                        connection, home_revision, policy
                    )
                authority = ComfortAuthority(
                    schemaVersion=1, coreId=core_id, homeId=home_id,
                    homeRevision=home_revision, accountId=actor.id,
                    accountRevision=revision,
                    sessionFamilyId=actor.family_id, role="admin", active=True,
                    canManageComfort=True,
                )
                planner = ComfortPlanner(
                    authorityResolver=lambda _account: authority,
                    policyResolver=lambda _policy: policy,
                )
                plan = planner.plan(
                    authority, policy, body.climate, body.weather,
                    body.occupancy, nowMs=now, overrides=body.overrides,
                )
                expected = {
                    (item.room.roomId, device.kind): device
                    for item in plan.items
                    for device in (item.room.hvac, item.room.window)
                }
                observed = {(item.roomId, item.device.kind): item.device for item in body.readbacks}
                if len(observed) != len(body.readbacks) or expected != observed:
                    raise ApiError("revision_conflict", 409)
                policy_json = policy.model_dump_json()
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
        if len(observed) != len(readbacks) or set(desired) != set(observed):
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

    @staticmethod
    def _worker_command(row, plan, actor, room_id, kind, device, desired, before):
        command_id = hashlib.sha256(
            (row["request_id"] + room_id + kind + plan.planId).encode()
        ).hexdigest()[:32]
        return ComfortWorkerCommand(
            schemaVersion=1,
            commandId=command_id,
            requestId=row["request_id"],
            planId=plan.planId,
            policyRevision=plan.policyRevision,
            actorAccountId=actor.id,
            roomId=room_id,
            targetKind=kind,
            device=device,
            expectedStateRevision=before.stateRevision,
            desiredState=desired,
        )

    @staticmethod
    def _unknown(command):
        return ComfortCommandResult(
            schemaVersion=1,
            commandId=command.commandId,
            roomId=command.roomId,
            targetKind=command.targetKind,
            status="unknown",
            code="worker_ack_unknown",
            readback=None,
        )

    def _complete_dispatch(self, command, result, completed_at):
        result_json = result.model_dump_json()
        with self.db.transaction() as connection:
            row, stored, existing = self._dispatch_row(
                connection, command.commandId
            )
            if stored != command:
                raise ApiError("comfort_storage_unavailable", 503)
            if existing is not None:
                return existing
            values = [
                row["command_id"], row["preview_id"], row["command_json"],
                "completed", result_json, row["reserved_at"], completed_at,
            ]
            updated = connection.execute(
                "UPDATE room_comfort_dispatches SET "
                "state='completed',result_json=?,completed_at=?,envelope_tag=? "
                "WHERE command_id=? AND state='dispatching'",
                (
                    result_json, completed_at,
                    self._tag("dispatch", values), command.commandId,
                ),
            )
            if updated.rowcount != 1:
                raise ApiError("comfort_storage_unavailable", 503)
        return result

    def _confirm_locked(self, actor, core_id, home_id, preview_id, body):
        reserved_at = float(self.settings.clock())
        inserted = set()
        commands = []
        try:
            with self.db.transaction() as connection:
                revision = self._actor(connection, actor)
                row = self._preview_row(connection, preview_id)
                if (
                    row["plan_id"], row["actor_id"], row["family_id"]
                ) != (body.expectedPlanId, actor.id, actor.family_id):
                    raise ApiError("revision_conflict", 409)
                if not hmac.compare_digest(
                    row["token_hash"],
                    hashlib.sha256(body.confirmToken.encode("ascii")).hexdigest(),
                ):
                    raise ApiError("invalid_request")
                _stored, _policy, plan, readbacks = self._plan_row(
                    connection, row["plan_id"]
                )
                state = connection.execute(
                    "SELECT plan_id FROM room_comfort_state WHERE singleton=1"
                ).fetchone()
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
                    return receipt
                if reserved_at > row["expires_at"]:
                    raise ApiError("preview_expired", 409)
                raw_commands = self._commands(plan, readbacks)
                existing_count = connection.execute(
                    "SELECT COUNT(*) FROM room_comfort_dispatches"
                ).fetchone()[0]
                for (room_id, kind), (device, desired), before in raw_commands:
                    command = self._worker_command(
                        row, plan, actor, room_id, kind, device, desired, before
                    )
                    command_json = command.model_dump_json()
                    old = connection.execute(
                        "SELECT * FROM room_comfort_dispatches WHERE command_id=?",
                        (command.commandId,),
                    ).fetchone()
                    if old is None:
                        if existing_count >= MAX_DISPATCHES:
                            raise ApiError("comfort_limit_reached", 429)
                        values = [
                            command.commandId, preview_id, command_json,
                            "dispatching", None, reserved_at, None,
                        ]
                        connection.execute(
                            "INSERT INTO room_comfort_dispatches "
                            "VALUES(?,?,?,?,?,?,?,?)",
                            (*values, self._tag("dispatch", values)),
                        )
                        inserted.add(command.commandId)
                        existing_count += 1
                    else:
                        old, stored_command, _result = self._dispatch_row(
                            connection, command.commandId
                        )
                        if (
                            old["preview_id"] != preview_id
                            or stored_command != command
                            or old["command_json"] != command_json
                        ):
                            raise ApiError("comfort_storage_unavailable", 503)
                    commands.append((command, before))
                preview = {
                    "id": row["id"], "request_id": row["request_id"],
                    "plan_id": row["plan_id"], "actor_id": row["actor_id"],
                    "family_id": row["family_id"], "token_hash": row["token_hash"],
                    "expires_at": row["expires_at"],
                }
        except ApiError:
            raise
        except (sqlite3.Error, ValueError):
            raise ApiError("comfort_storage_unavailable", 503) from None

        results = []
        for command, before in commands:
            if command.commandId not in inserted:
                with self.db.connection() as connection:
                    connection.execute("BEGIN")
                    _row, _stored, existing = self._dispatch_row(
                        connection, command.commandId
                    )
                result = existing or self._unknown(command)
            else:
                raw_result = None
                if self.worker is not None:
                    try:
                        execute = getattr(
                            self.worker, "execute_authorized", None
                        )
                        raw_result = (
                            execute(command, actor)
                            if callable(execute)
                            else self.worker(command)
                        )
                    except Exception:  # noqa: BLE001 -- provider failure is redacted
                        raw_result = None
                completed_ms = int(float(self.settings.clock()) * 1000)
                try:
                    value = WorkerComfortReadback.model_validate(raw_result)
                except (ValueError, TypeError):
                    value = None
                exact = value is not None and (
                    value.commandId == command.commandId
                    and value.roomId == command.roomId
                    and value.device == command.device
                    and value.stateRevision > before.stateRevision
                    and value.state == command.desiredState
                    and value.observedAtMs >= before.observedAtMs
                    and value.observedAtMs <= completed_ms
                )
                result = ComfortCommandResult(
                    schemaVersion=1,
                    commandId=command.commandId,
                    roomId=command.roomId,
                    targetKind=command.targetKind,
                    status="applied" if exact else (
                        "unknown" if value is None else "failed"
                    ),
                    code="applied" if exact else (
                        "worker_ack_unknown" if value is None
                        else "readback_mismatch"
                    ),
                    readback=value,
                )
            completed_at = float(self.settings.clock())
            results.append(self._complete_dispatch(command, result, completed_at))

        states = {item.status for item in results}
        receipt_status = (
            "applied" if states == {"applied"}
            else ("partial" if len(states) > 1 else next(iter(states)))
        )
        completed_at = float(self.settings.clock())
        receipt = ComfortReceipt(
            schemaVersion=1,
            requestId=preview["request_id"],
            planId=preview["plan_id"],
            status=receipt_status,
            results=results,
            completedAtMs=int(completed_at * 1000),
        )
        receipt_json = receipt.model_dump_json()
        try:
            with self.db.transaction() as connection:
                current = self._preview_row(connection, preview_id)
                if current["receipt_json"] is not None:
                    return ComfortReceipt.model_validate_json(
                        current["receipt_json"]
                    )
                values = [
                    preview["id"], preview["request_id"], preview["plan_id"],
                    preview["actor_id"], preview["family_id"],
                    preview["token_hash"], preview["expires_at"], receipt_json,
                ]
                updated = connection.execute(
                    "UPDATE room_comfort_previews SET "
                    "receipt_json=?,envelope_tag=? "
                    "WHERE id=? AND receipt_json IS NULL",
                    (
                        receipt_json, self._tag("preview", values), preview_id,
                    ),
                )
                if updated.rowcount != 1:
                    raise ApiError("comfort_storage_unavailable", 503)
        except ApiError:
            raise
        except (sqlite3.Error, ValueError):
            raise ApiError("comfort_storage_unavailable", 503) from None
        return receipt

    def confirm(self, actor, core_id, home_id, preview_id, value):
        body = ConfirmComfortPlan.model_validate(value)
        self._scope(core_id, home_id)
        # Serializes duplicate in-process confirms without holding SQLite over
        # provider I/O. A restart finds dispatching rows and never resends them.
        with self._confirm_lock:
            receipt = self._confirm_locked(
                actor, core_id, home_id, preview_id, body
            )
        return {"schemaVersion": 1, "receipt": receipt}
