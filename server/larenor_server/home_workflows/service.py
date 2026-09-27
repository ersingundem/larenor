"""Durable one-step workflows with explicit human and reconciliation gates."""

from contextlib import contextmanager
import json
import secrets
import sqlite3
from threading import RLock
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..errors import ApiError, StartupError
from ..home_assistant.models import CommandAttribution, CommandRequest
from ..home_resources.models import HomeScope, ResourceRef
from . import schema
from .models import (
    CreateWorkflowRequest,
    HomeWorkflow,
    OperationRecord,
    WorkflowDecisionRequest,
    WorkflowPayload,
    WorkflowResumeRequest,
    WorkflowTarget,
)


class HomeWorkflowService:
    _NOTIFICATION_BODIES = {
        "waiting_decision": "A home workflow is waiting for your decision.",
        "reconciliation_required": "A home workflow needs reconciliation.",
        "failed": "A home workflow failed.",
        "timed_out": "A home workflow timed out.",
        "completed": "A home workflow completed.",
    }

    def __init__(
        self, db, auth, settings, key, resources, home_assistant, notification_writer
    ):
        self.db, self.auth, self.settings = db, auth, settings
        self.resources, self.home_assistant = resources, home_assistant
        self.notification_writer = notification_writer
        self.scope = HomeScope.model_validate(resources.scope.model_dump())
        self._key, self._cipher = key, AESGCM(key)
        self._lock = RLock()
        self._active_workflows = set()

    def _aad(self, row):
        values = [
            row[name]
            for name in (
                "id", "sequence", "revision", "actor_id", "request_id",
                "state", "attempt", "step_request_id", "effect_state",
                "reconciliation_result", "cancel_requested", "deadline_at",
                "created_at", "updated_at",
            )
        ]
        return b"larenor-home-workflow-v1\0" + json.dumps(
            values, separators=(",", ":"), ensure_ascii=True, allow_nan=False
        ).encode("ascii")

    def _decode(self, row):
        try:
            for field in ("id", "actor_id", "request_id"):
                self.resources._id(row[field])
            if row["step_request_id"] is not None:
                self.resources._id(row["step_request_id"])
            self.resources._revision(row["revision"])
            if (
                type(row["sequence"]) is not int
                or row["sequence"] < 1
                or type(row["attempt"]) is not int
                or not 1 <= row["attempt"] <= 3
                or type(row["cancel_requested"]) is not int
                or row["cancel_requested"] not in (0, 1)
                or type(row["deadline_at"]) not in (int, float)
                or type(row["created_at"]) not in (int, float)
                or type(row["updated_at"]) not in (int, float)
                or type(row["nonce"]) is not bytes
                or len(row["nonce"]) != 12
                or type(row["ciphertext"]) is not bytes
                or not 16 <= len(row["ciphertext"]) <= schema.MAX_CIPHERTEXT
            ):
                raise ValueError("invalid_storage")
            payload = WorkflowPayload.model_validate_json(
                self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row))
            )
            if payload.request.requestId != row["request_id"]:
                raise ValueError("invalid_storage")
            return payload
        except (ApiError, InvalidTag, ValidationError, UnicodeError, ValueError, TypeError):
            raise ValueError("invalid_storage") from None

    def _save(self, connection, row, payload):
        payload = WorkflowPayload.model_validate(payload)
        plain = payload.model_dump_json().encode("utf-8")
        nonce = secrets.token_bytes(12)
        cipher = self._cipher.encrypt(nonce, plain, self._aad(row))
        if len(cipher) > schema.MAX_CIPHERTEXT:
            raise ApiError("invalid_request")
        connection.execute(
            "INSERT INTO home_workflows VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,state=excluded.state,"
            "attempt=excluded.attempt,step_request_id=excluded.step_request_id,"
            "effect_state=excluded.effect_state,"
            "reconciliation_result=excluded.reconciliation_result,"
            "cancel_requested=excluded.cancel_requested,deadline_at=excluded.deadline_at,"
            "updated_at=excluded.updated_at,nonce=excluded.nonce,ciphertext=excluded.ciphertext",
            (
                row["id"], row["sequence"], row["revision"], row["actor_id"],
                row["request_id"], row["state"], row["attempt"],
                row["step_request_id"], row["effect_state"],
                row["reconciliation_result"], row["cancel_requested"],
                row["deadline_at"], row["created_at"], row["updated_at"], nonce, cipher,
            ),
        )

    def _notify(self, connection, row, payload):
        body = self._NOTIFICATION_BODIES.get(row["state"])
        if body is None:
            return
        self.notification_writer.append_internal(
            connection,
            {
                "schemaVersion": 1,
                "recipientUserId": row["actor_id"],
                "idempotencyKey": (
                    f"workflow:{row['id']}:{row['revision']}:{row['state']}"
                ),
                "category": "home_workflow",
                "sensitivity": "private",
                "title": payload.request.title,
                "body": body,
                "target": "/workflows",
            },
        )

    def _find(self, connection, workflow_id):
        self.resources._id(workflow_id)
        row = connection.execute(
            "SELECT * FROM home_workflows WHERE id=?", (workflow_id,)
        ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        return row, self._decode(row)

    def _target(self, connection, facts, row, payload, *, write=False):
        if facts.role != "admin" and row["actor_id"] != facts.userId:
            raise ApiError("not_found", 404)
        resource_id = payload.request.target.resourceId
        try:
            target_row, ref, data, binding = self.home_assistant._target(
                connection, facts, resource_id
            )
            if write:
                self.resources._require(
                    facts,
                    target_row,
                    ref,
                    data,
                    "write",
                    expected_revision=payload.request.target.expectedResourceRevision,
                    expected_acl_revision=payload.request.target.expectedAclRevision,
                )
                if (
                    binding is None
                    or binding.revision
                    != payload.request.target.expectedBindingRevision
                ):
                    raise ApiError("ha_binding_changed", 409)
        except ApiError as error:
            if write and error.code in {
                "not_found", "forbidden", "revision_conflict", "ha_binding_changed",
            }:
                raise ApiError("home_workflow_authority_changed", 409) from None
            raise
        return ref, binding

    def _public(self, row, payload):
        request = payload.request
        ref = ResourceRef(
            **self.scope.model_dump(), kind="resource", id=request.target.resourceId
        )
        return HomeWorkflow(
            id=row["id"],
            revision=row["revision"],
            requestId=row["request_id"],
            scope=self.scope,
            creatorId=row["actor_id"],
            title=request.title,
            target=WorkflowTarget(
                kind="home_assistant_switch",
                resource=ref,
                action=request.target.action,
                bindingRevision=request.target.expectedBindingRevision,
                resourceRevision=request.target.expectedResourceRevision,
                aclRevision=request.target.expectedAclRevision,
            ),
            state=row["state"],
            decisionRequired=(
                "approve_effect"
                if row["state"] == "waiting_decision"
                else "reconcile_effect"
                if row["state"] == "reconciliation_required"
                else None
            ),
            attempt=row["attempt"],
            stepRequestId=row["step_request_id"],
            effectState=row["effect_state"],
            reconciliationResult=row["reconciliation_result"],
            cancelRequested=bool(row["cancel_requested"]),
            deadlineAt=utc(row["deadline_at"]),
            createdAt=utc(row["created_at"]),
            updatedAt=utc(row["updated_at"]),
        ).model_dump()

    @contextmanager
    def _transaction(
        self, actor, core_id, home_id, *, write=False, consume_rate_limit=True
    ):
        try:
            if write and consume_rate_limit:
                self.auth.rate_limit([("home_workflow_write", actor.id, 120)])
            with self._lock, self.resources._transaction(
                actor, core_id, home_id,
                consume_rate_limit=consume_rate_limit and not write,
            ) as (connection, facts):
                yield connection, facts
        except ApiError:
            raise
        except (InvalidTag, ValidationError, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM home_workflows ORDER BY sequence LIMIT ?",
                    (schema.MAX_WORKFLOWS + 1,),
                ).fetchall()
                if len(rows) > schema.MAX_WORKFLOWS:
                    raise ValueError("invalid_storage")
                for row in rows:
                    self._decode(row)
        except (InvalidTag, ValidationError, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError("home_workflow_storage_invalid") from None

    def recover_incomplete(self):
        with self._lock, self.db.transaction() as connection:
            for saved in connection.execute(
                "SELECT * FROM home_workflows WHERE state='running'"
            ).fetchall():
                payload = self._decode(saved)
                self._save_transition(
                    connection,
                    saved,
                    payload,
                    state="reconciliation_required",
                    effect_state="unknown",
                )

    def create(self, actor, core_id, home_id, body):
        body = CreateWorkflowRequest.model_validate(body)
        with self._transaction(actor, core_id, home_id, write=True) as (connection, facts):
            existing = connection.execute(
                "SELECT * FROM home_workflows WHERE actor_id=? AND request_id=?",
                (actor.id, body.requestId),
            ).fetchone()
            if existing is not None:
                payload = self._decode(existing)
                if payload.request != body:
                    raise ApiError("home_workflow_conflict", 409)
                self._target(connection, facts, existing, payload)
                return {"schemaVersion": 1, "workflow": self._public(existing, payload)}
            if connection.execute("SELECT COUNT(*) FROM home_workflows").fetchone()[0] >= schema.MAX_WORKFLOWS:
                raise ApiError("home_workflow_limit_reached", 429)

            # Creation needs current write authority, but it never contacts or
            # mutates the physical provider.
            payload = WorkflowPayload(request=body)
            target_row, ref, data, binding = self.home_assistant._target(
                connection, facts, body.target.resourceId
            )
            self.resources._require(
                facts,
                target_row,
                ref,
                data,
                "write",
                expected_revision=body.target.expectedResourceRevision,
                expected_acl_revision=body.target.expectedAclRevision,
            )
            if binding is None or binding.revision != body.target.expectedBindingRevision:
                raise ApiError("ha_binding_changed", 409)
            now = self.settings.clock()
            sequence = connection.execute(
                "SELECT COALESCE(MAX(sequence),0)+1 FROM home_workflows"
            ).fetchone()[0]
            row = {
                "id": uuid.uuid4().hex,
                "sequence": sequence,
                "revision": 1,
                "actor_id": actor.id,
                "request_id": body.requestId,
                "state": "waiting_decision",
                "attempt": 1,
                "step_request_id": None,
                "effect_state": "not_started",
                "reconciliation_result": "none",
                "cancel_requested": 0,
                "deadline_at": now + body.deadlineSeconds,
                "created_at": now,
                "updated_at": now,
            }
            self._save(connection, row, payload)
            self._notify(connection, row, payload)
            return {"schemaVersion": 1, "workflow": self._public(row, payload)}

    def _operation(self, row, payload, operation_id, kind, expected, decision=None):
        for operation in payload.operations:
            if operation.id != operation_id:
                continue
            if (
                operation.kind != kind
                or operation.expectedRevision != expected
                or operation.decision != decision
            ):
                raise ApiError("home_workflow_conflict", 409)
            if operation.responseRevision != row["revision"]:
                raise ApiError("home_workflow_changed", 409)
            return self._public(row, payload)
        return None

    @staticmethod
    def _append_operation(payload, operation):
        if len(payload.operations) >= 16:
            raise ApiError("home_workflow_limit_reached", 429)
        return payload.model_copy(
            update={"operations": [*payload.operations, operation]}
        )

    def _save_transition(self, connection, row, payload, *, operation=None, **changes):
        value = dict(row)
        value.update(changes)
        value["revision"] = row["revision"] + 1
        value["updated_at"] = self.settings.clock()
        if operation is not None:
            operation = OperationRecord(
                **operation, responseRevision=value["revision"]
            )
            payload = self._append_operation(payload, operation)
        self._save(connection, value, payload)
        if value["state"] != row["state"]:
            self._notify(connection, value, payload)
        return value, payload

    def decide(self, actor, core_id, home_id, workflow_id, body, *, cancelled=lambda: False):
        body = WorkflowDecisionRequest.model_validate(body)
        timed_out = False
        dispatch = None
        with self._transaction(actor, core_id, home_id, write=True) as (connection, facts):
            saved, payload = self._find(connection, workflow_id)
            duplicate = self._operation(
                saved, payload, body.decisionId, "decision", body.expectedRevision,
                body.decision,
            )
            if duplicate is not None:
                return {"schemaVersion": 1, "workflow": duplicate}
            ref, binding = self._target(
                connection, facts, saved, payload, write=True
            )
            if saved["revision"] != body.expectedRevision:
                raise ApiError("home_workflow_changed", 409)

            if body.decision == "approve":
                if saved["state"] != "waiting_decision":
                    raise ApiError("home_workflow_decision_invalid", 409)
                if self.settings.clock() >= saved["deadline_at"]:
                    saved, payload = self._save_transition(
                        connection, saved, payload, state="timed_out"
                    )
                    timed_out = True
                else:
                    running = dict(saved)
                    running.update(
                        state="running",
                        step_request_id=uuid.uuid4().hex,
                        updated_at=self.settings.clock(),
                    )
                    self._save(connection, running, payload)
                    self._active_workflows.add(running["id"])
                    dispatch = (running, payload, ref, binding)
            elif body.decision == "cancel":
                if saved["state"] == "waiting_decision":
                    saved, payload = self._save_transition(
                        connection,
                        saved,
                        payload,
                        operation={
                            "id": body.decisionId,
                            "kind": "decision",
                            "expectedRevision": body.expectedRevision,
                            "decision": body.decision,
                        },
                        state="cancelled",
                        cancel_requested=1,
                    )
                    return {"schemaVersion": 1, "workflow": self._public(saved, payload)}
                if saved["state"] == "running":
                    saved, payload = self._save_transition(
                        connection,
                        saved,
                        payload,
                        operation={
                            "id": body.decisionId,
                            "kind": "decision",
                            "expectedRevision": body.expectedRevision,
                            "decision": body.decision,
                        },
                        state="reconciliation_required",
                        effect_state="unknown",
                        cancel_requested=1,
                    )
                    return {"schemaVersion": 1, "workflow": self._public(saved, payload)}
                raise ApiError("home_workflow_decision_invalid", 409)
            elif body.decision == "effect_not_applied":
                if saved["state"] != "reconciliation_required":
                    raise ApiError("home_workflow_decision_invalid", 409)
                if saved["cancel_requested"] or saved["attempt"] >= 3:
                    saved, payload = self._save_transition(
                        connection,
                        saved,
                        payload,
                        operation={
                            "id": body.decisionId,
                            "kind": "decision",
                            "expectedRevision": body.expectedRevision,
                            "decision": body.decision,
                        },
                        state=(
                            "cancelled" if saved["cancel_requested"] else "failed"
                        ),
                        effect_state="rejected",
                        reconciliation_result="effect_not_applied",
                    )
                    return {
                        "schemaVersion": 1,
                        "workflow": self._public(saved, payload),
                    }
                saved, payload = self._save_transition(
                    connection,
                    saved,
                    payload,
                    operation={
                        "id": body.decisionId,
                        "kind": "decision",
                        "expectedRevision": body.expectedRevision,
                        "decision": body.decision,
                    },
                    state="waiting_decision",
                    attempt=saved["attempt"] + 1,
                    step_request_id=None,
                    effect_state="not_started",
                    reconciliation_result="effect_not_applied",
                    cancel_requested=0,
                )
                return {"schemaVersion": 1, "workflow": self._public(saved, payload)}
            else:
                if saved["state"] != "reconciliation_required":
                    raise ApiError("home_workflow_decision_invalid", 409)
                saved, payload = self._save_transition(
                    connection,
                    saved,
                    payload,
                    operation={
                        "id": body.decisionId,
                        "kind": "decision",
                        "expectedRevision": body.expectedRevision,
                        "decision": body.decision,
                    },
                    state="completed",
                    effect_state="accepted",
                    reconciliation_result="effect_applied",
                )
                return {"schemaVersion": 1, "workflow": self._public(saved, payload)}

        if timed_out:
            raise ApiError("home_workflow_timed_out", 409)
        running, payload, ref, binding = dispatch
        command = CommandRequest(
            requestId=running["step_request_id"],
            action=payload.request.target.action,
            expectedBindingRevision=payload.request.target.expectedBindingRevision,
            expectedResourceRevision=payload.request.target.expectedResourceRevision,
            expectedAclRevision=payload.request.target.expectedAclRevision,
        )
        attribution = CommandAttribution(
            correlationId=running["step_request_id"],
            source="core_workflow",
            reason="workflow_step_execution",
            serviceId=binding.serviceId,
            serviceRevision=binding.serviceRevision,
            workflowId=running["id"],
            workflowRevision=body.expectedRevision,
            stepId="effect",
        )

        def stopped():
            if cancelled():
                return True
            try:
                with self.db.connection() as connection:
                    current = connection.execute(
                        "SELECT cancel_requested FROM home_workflows WHERE id=?",
                        (workflow_id,),
                    ).fetchone()
                    return current is None or bool(current["cancel_requested"])
            except sqlite3.Error:
                return True

        try:
            try:
                outcome = self.home_assistant.command(
                    actor,
                    core_id,
                    home_id,
                    ref.id,
                    command,
                    cancelled=stopped,
                    attribution=attribution,
                )["receipt"]
            except ApiError as error:
                if error.code in {
                    "forbidden", "revision_conflict", "ha_binding_changed", "not_found",
                }:
                    with self._transaction(
                        actor,
                        core_id,
                        home_id,
                        write=True,
                        consume_rate_limit=False,
                    ) as (connection, _):
                        saved, payload = self._find(connection, workflow_id)
                        if (
                            saved["revision"] == body.expectedRevision
                            and saved["state"] == "running"
                            and saved["step_request_id"] == running["step_request_id"]
                        ):
                            self._save_transition(
                                connection,
                                saved,
                                payload,
                                state="failed",
                                effect_state="rejected",
                            )
                    raise ApiError("home_workflow_authority_changed", 409) from None
                raise

            with self._transaction(
                actor,
                core_id,
                home_id,
                write=True,
                consume_rate_limit=False,
            ) as (connection, facts):
                saved, payload = self._find(connection, workflow_id)
                self._target(connection, facts, saved, payload)
                if (
                    saved["revision"] != body.expectedRevision
                    or saved["state"] != "running"
                    or saved["step_request_id"] != running["step_request_id"]
                ):
                    # A concurrent cancel, reconciliation decision, or recovery
                    # owns the newer state. The late physical result must not
                    # overwrite that human-visible outcome.
                    return {
                        "schemaVersion": 1,
                        "workflow": self._public(saved, payload),
                    }
                accepted = (
                    outcome["dispatchState"] == "accepted"
                    and outcome["observationMatchesTarget"] is True
                )
                rejected = outcome["dispatchState"] == "rejected"
                state = (
                    "completed"
                    if accepted
                    else "failed"
                    if rejected
                    else "reconciliation_required"
                )
                effect = (
                    "accepted" if accepted else "rejected" if rejected else "unknown"
                )
                saved, payload = self._save_transition(
                    connection,
                    saved,
                    payload,
                    operation={
                        "id": body.decisionId,
                        "kind": "decision",
                        "expectedRevision": body.expectedRevision,
                        "decision": body.decision,
                    },
                    state=state,
                    effect_state=effect,
                    reconciliation_result="effect_applied" if accepted else "none",
                )
                return {
                    "schemaVersion": 1,
                    "workflow": self._public(saved, payload),
                }
        finally:
            with self._lock:
                self._active_workflows.discard(workflow_id)

    def get(self, actor, core_id, home_id, workflow_id):
        with self._transaction(actor, core_id, home_id) as (connection, facts):
            saved, payload = self._find(connection, workflow_id)
            self._target(connection, facts, saved, payload)
            if (
                saved["state"] == "running"
                and workflow_id not in self._active_workflows
            ):
                saved, payload = self._save_transition(
                    connection,
                    saved,
                    payload,
                    state="reconciliation_required",
                    effect_state="unknown",
                )
            return {"schemaVersion": 1, "workflow": self._public(saved, payload)}

    def list(self, actor, core_id, home_id, *, before=None, limit=25):
        if type(limit) is not int or not 1 <= limit <= 50:
            raise ApiError("invalid_request")
        if before is not None:
            self.resources._id(before)
        with self._transaction(actor, core_id, home_id) as (connection, facts):
            visible = []
            for saved in connection.execute(
                "SELECT * FROM home_workflows ORDER BY sequence DESC LIMIT ?",
                (schema.MAX_WORKFLOWS + 1,),
            ).fetchall():
                if facts.role != "admin" and saved["actor_id"] != facts.userId:
                    continue
                payload = self._decode(saved)
                try:
                    self._target(connection, facts, saved, payload)
                except ApiError as error:
                    if error.code == "not_found":
                        continue
                    raise
                visible.append((saved, payload))
            if before is not None:
                position = next(
                    (index for index, value in enumerate(visible) if value[0]["id"] == before),
                    None,
                )
                if position is None:
                    raise ApiError("not_found", 404)
                visible = visible[position + 1 :]
            page = visible[:limit]
            return {
                "schemaVersion": 1,
                "workflows": [self._public(row, payload) for row, payload in page],
                "nextBefore": page[-1][0]["id"] if len(visible) > limit else None,
            }

    def resume(self, actor, core_id, home_id, workflow_id, body):
        body = WorkflowResumeRequest.model_validate(body)
        with self._transaction(
            actor, core_id, home_id, write=True
        ) as (connection, facts):
            saved, payload = self._find(connection, workflow_id)
            duplicate = self._operation(
                saved, payload, body.resumeId, "resume", body.expectedRevision
            )
            if duplicate is not None:
                return {"schemaVersion": 1, "workflow": duplicate}
            ref, _ = self._target(connection, facts, saved, payload, write=True)
            if saved["revision"] != body.expectedRevision:
                raise ApiError("home_workflow_changed", 409)
            if saved["state"] not in {"running", "reconciliation_required"} or saved["step_request_id"] is None:
                raise ApiError("home_workflow_decision_invalid", 409)
            request_id = saved["step_request_id"]
            initial_revision = saved["revision"]

        try:
            outcome = self.home_assistant.command_result(
                actor, core_id, home_id, ref.id, request_id
            )["receipt"]
        except ApiError as error:
            if error.code != "not_found":
                raise
            outcome = {
                "dispatchState": "unknown",
                "observationMatchesTarget": None,
            }

        with self._transaction(
            actor,
            core_id,
            home_id,
            write=True,
            consume_rate_limit=False,
        ) as (connection, facts):
            saved, payload = self._find(connection, workflow_id)
            self._target(connection, facts, saved, payload, write=True)
            if (
                saved["revision"] != initial_revision
                or saved["step_request_id"] != request_id
                or saved["state"] not in {"running", "reconciliation_required"}
            ):
                raise ApiError("home_workflow_changed", 409)
            accepted = (
                outcome["dispatchState"] == "accepted"
                and outcome["observationMatchesTarget"] is True
            )
            rejected = outcome["dispatchState"] == "rejected"
            final_state = (
                "completed"
                if accepted
                else "cancelled"
                if rejected and saved["cancel_requested"]
                else "failed"
                if rejected
                else "reconciliation_required"
            )
            saved, payload = self._save_transition(
                connection,
                saved,
                payload,
                operation={
                    "id": body.resumeId,
                    "kind": "resume",
                    "expectedRevision": body.expectedRevision,
                    "decision": None,
                },
                state=final_state,
                effect_state="accepted" if accepted else "rejected" if rejected else "unknown",
                reconciliation_result="effect_applied" if accepted else "none",
            )
            return {"schemaVersion": 1, "workflow": self._public(saved, payload)}
