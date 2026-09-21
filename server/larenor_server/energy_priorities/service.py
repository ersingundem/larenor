import threading

from ..errors import ApiError
from .api_models import (
    ConfirmEnergyCommand,
    EnergyPrioritySnapshot,
    PreviewEnergyCommand,
)
from .commands import MAX_COMMANDS, InverterCommandManager
from .models import EnergyAuthority, EnergyInputs, InverterCapability
from .planner import EnergyPlanner


class EnergyPriorityService:
    """Authenticated adapter around advisory planning and optional inverter effects."""

    def __init__(
        self,
        db,
        auth,
        settings,
        key,
        context,
        provider=None,
        worker=None,
        inverter=None,
    ):
        self.db, self.auth, self.settings = db, auth, settings
        self.context, self.provider, self.worker = context, provider, worker
        self.inverter = (
            None if inverter is None else InverterCapability.model_validate(inverter)
        )
        self._lock = threading.RLock()
        self._authorities = {}
        self._plans = {}
        self._previews = {}
        self._commands = InverterCommandManager(
            auditKey=key,
            authorityResolver=self._resolve_authority,
            planResolver=self._resolve_plan,
            worker=worker or (lambda _command: None),
            clockMs=lambda: int(settings.clock() * 1000),
        )

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)

    def _authority(self, actor):
        with self.db.connection() as connection:
            self.auth.assert_current(connection, actor)
            row = connection.execute(
                "SELECT role,disabled,must_change_password,revision FROM users WHERE id=?",
                (actor.id,),
            ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("forbidden", 403)
        authority = EnergyAuthority(
            schemaVersion=1,
            coreId=self.context.coreId,
            homeId=self.context.homeId,
            homeRevision=1,
            accountId=actor.id,
            accountRevision=row["revision"],
            memberRevision=row["revision"],
            sessionFamilyId=actor.family_id,
            role=row["role"],
            active=True,
            canPlan=True,
            canControl=(
                row["role"] == "admin"
                and self.worker is not None
                and self.inverter is not None
                and self.inverter.writable
            ),
        )
        with self._lock:
            self._authorities[actor.id] = authority
        return authority

    def _resolve_authority(self, account_id):
        with self._lock:
            return self._authorities.get(account_id)

    def _resolve_plan(self, plan_id):
        with self._lock:
            return self._plans.get(plan_id)

    def _inputs(self, authority):
        if self.provider is None:
            raise ApiError("energy_provider_unavailable", 503)
        try:
            inputs = EnergyInputs.model_validate(self.provider(authority))
        except ApiError:
            raise
        except Exception:  # noqa: BLE001 -- provider failures are redacted
            raise ApiError("energy_provider_unavailable", 503) from None
        now = int(self.settings.clock() * 1000)
        if (
            (inputs.coreId, inputs.homeId, inputs.homeRevision)
            != (authority.coreId, authority.homeId, authority.homeRevision)
            or inputs.meter.capturedAtMs > now
            or now - inputs.meter.capturedAtMs > 5 * 60 * 1000
            or inputs.battery.capturedAtMs > now
            or now - inputs.battery.capturedAtMs > 5 * 60 * 1000
            or inputs.forecast.generatedAtMs > now
            or now - inputs.forecast.generatedAtMs > 24 * 60 * 60 * 1000
        ):
            raise ApiError("revision_conflict", 409)
        return inputs

    def snapshot(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        authority = self._authority(actor)
        inputs = self._inputs(authority)
        planner = EnergyPlanner(
            authorityResolver=lambda account: (
                authority if account == authority.accountId else None
            ),
            inputResolver=lambda battery: (
                inputs if battery == inputs.battery.resourceId else None
            ),
            clockMs=lambda: int(self.settings.clock() * 1000),
        )
        plan = planner.plan(authority, inputs)
        with self._lock:
            self._plans = {plan.planId: plan}
        capability = self.inverter
        if capability is not None and not authority.canControl:
            capability = capability.model_copy(update={"writable": False})
        return EnergyPrioritySnapshot(
            schemaVersion=1,
            authority=authority,
            inputs=inputs,
            plan=plan,
            inverter=capability,
        )

    def preview(self, actor, core_id, home_id, raw):
        body = PreviewEnergyCommand.model_validate(raw)
        snapshot = self.snapshot(actor, core_id, home_id)
        if (
            body.planId != snapshot.plan.planId
            or body.inputDigest != snapshot.plan.inputDigest
            or body.expectedAccountRevision != snapshot.authority.accountRevision
            or body.expectedHomeRevision != snapshot.authority.homeRevision
        ):
            raise ApiError("revision_conflict", 409)
        capability = snapshot.inverter
        if body.slotIndex >= len(snapshot.plan.slots):
            raise ApiError("invalid_request")
        slot = snapshot.plan.slots[body.slotIndex]
        if (
            capability is None
            or not capability.writable
            or (body.inverterId, body.expectedInverterRevision)
            != (capability.inverterId, capability.revision)
            or (slot.action == "charge" and not capability.canCharge)
            or (slot.action == "discharge" and not capability.canDischarge)
            or slot.action == "hold"
        ):
            raise ApiError("forbidden", 403)
        target = slot.powerW if slot.action == "charge" else -slot.powerW
        with self._lock:
            old = self._previews.get(body.requestId)
        if old is not None:
            if (
                old.planId,
                old.inputDigest,
                old.accountId,
                old.sessionFamilyId,
                old.inverterId,
                old.expectedInverterRevision,
                old.targetPowerW,
            ) != (
                snapshot.plan.planId,
                snapshot.plan.inputDigest,
                snapshot.authority.accountId,
                snapshot.authority.sessionFamilyId,
                capability.inverterId,
                capability.revision,
                target,
            ):
                raise ApiError("idempotency_conflict", 409)
            return old
        preview = self._commands.preview(
            snapshot.authority,
            snapshot.plan,
            slotIndex=body.slotIndex,
            requestId=body.requestId,
            inverterId=body.inverterId,
            expectedInverterRevision=body.expectedInverterRevision,
        )
        with self._lock:
            old = self._previews.get(preview.requestId)
            if old is not None and old != preview:
                raise ApiError("idempotency_conflict", 409)
            if old is None and len(self._previews) >= MAX_COMMANDS:
                raise ApiError("rate_limited", 429)
            self._previews[preview.requestId] = preview
        return preview

    def confirm(self, actor, core_id, home_id, request_id, raw):
        body = ConfirmEnergyCommand.model_validate(raw)
        self._scope(core_id, home_id)
        authority = self._authority(actor)
        with self._lock:
            preview = self._previews.get(request_id)
        if preview is None:
            raise ApiError("not_found", 404)
        current = self.snapshot(actor, core_id, home_id)
        if current.plan.planId != preview.planId:
            raise ApiError("revision_conflict", 409)
        return self._commands.confirm(authority, preview, body.confirmationToken)

    def result(self, actor, core_id, home_id, request_id):
        self._scope(core_id, home_id)
        return self._commands.result(self._authority(actor), request_id)
