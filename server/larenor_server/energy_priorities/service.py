import hashlib
import hmac
import json
import secrets
import threading

from ..errors import ApiError
from .api_models import (
    ConfirmEnergyCommand,
    EnergyPrioritySnapshot,
    PreviewEnergyCommand,
    PreviewReserveCommand,
)
from .commands import MAX_COMMANDS, InverterCommandManager
from .history import analyze_reserve_history
from .models import (
    EnergyAuthority,
    EnergyInputs,
    InverterCapability,
    ReserveCommandPreview,
    ReserveCommandResult,
)
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
        reserve_control=None,
        home_revision_provider=None,
        history_provider=None,
    ):
        self.db, self.auth, self.settings = db, auth, settings
        self.context, self.provider, self.worker = context, provider, worker
        self._home_revision_provider = home_revision_provider or (lambda: 1)
        if not callable(self._home_revision_provider):
            raise ValueError("invalid_home_revision_provider")
        self.inverter = (
            None if inverter is None else InverterCapability.model_validate(inverter)
        )
        self.reserve_control = reserve_control
        self.history_provider = history_provider
        self._command_key = hmac.new(
            key, b"larenor:energy-reserve-confirmation:v1", hashlib.sha256
        ).digest()
        self._lock = threading.RLock()
        self._authorities = {}
        self._plans = {}
        self._previews = {}
        self._reserve_previews = {}
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

    def _authority(self, actor, capability=None):
        with self.db.connection() as connection:
            self.auth.assert_current(connection, actor)
            row = connection.execute(
                "SELECT role,disabled,must_change_password,revision FROM users WHERE id=?",
                (actor.id,),
            ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("forbidden", 403)
        selected = self.inverter if capability is None else capability
        try:
            home_revision = self._home_revision_provider()
        except ApiError:
            raise
        except Exception:
            raise ApiError("server_unavailable", 503) from None
        if type(home_revision) is not int or not 1 <= home_revision <= 2**63 - 1:
            raise ApiError("server_unavailable", 503)
        authority = EnergyAuthority(
            schemaVersion=1,
            coreId=self.context.coreId,
            homeId=self.context.homeId,
            homeRevision=home_revision,
            accountId=actor.id,
            accountRevision=row["revision"],
            memberRevision=row["revision"],
            sessionFamilyId=actor.family_id,
            role=row["role"],
            active=True,
            canPlan=True,
            canControl=(
                row["role"] == "admin"
                and selected is not None
                and selected.writable
                and (
                    self.worker is not None
                    or self.reserve_control is not None
                    and selected.canSetReserve
                )
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

    def _provider_snapshot(self, authority):
        if self.provider is None:
            raise ApiError("energy_provider_unavailable", 503)
        try:
            method = getattr(self.provider, "snapshot", None)
            if callable(method):
                raw_inputs, raw_capability = method(authority)
                capability = InverterCapability.model_validate(raw_capability)
            else:
                raw_inputs = self.provider(authority)
                capability = self.inverter
            inputs = EnergyInputs.model_validate(raw_inputs)
            if (
                self.reserve_control is not None
                and capability is not None
                and capability.controlSemantics == "none"
            ):
                capability = InverterCapability.model_validate(
                    self.reserve_control.capability(inputs, capability)
                )
        except ApiError:
            raise
        except Exception:  # noqa: BLE001 -- provider failures are redacted
            raise ApiError("energy_provider_unavailable", 503) from None
        return inputs, capability

    def _inputs(self, authority, inputs):
        now = int(self.settings.clock() * 1000)
        forecast_slot_ms = inputs.forecast.slotDurationSeconds * 1_000
        forecast_end_ms = (
            inputs.forecast.startsAtMs
            + len(inputs.forecast.solarEnergyWh) * forecast_slot_ms
        )
        if (
            (inputs.coreId, inputs.homeId, inputs.homeRevision)
            != (authority.coreId, authority.homeId, authority.homeRevision)
            or inputs.meter.capturedAtMs > now
            or now - inputs.meter.capturedAtMs > 5 * 60 * 1000
            or inputs.battery.capturedAtMs > now
            or now - inputs.battery.capturedAtMs > 5 * 60 * 1000
            or inputs.forecast.generatedAtMs > now
            or now - inputs.forecast.generatedAtMs > 24 * 60 * 60 * 1000
            or inputs.forecast.startsAtMs > now + forecast_slot_ms
            or forecast_end_ms <= now
        ):
            raise ApiError("revision_conflict", 409)
        return inputs

    def snapshot(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        authority = self._authority(actor)
        inputs, capability = self._provider_snapshot(authority)
        authority = self._authority(actor, capability)
        inputs = self._inputs(authority, inputs)
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
        if capability is not None and not authority.canControl:
            capability = capability.model_copy(update={"writable": False})
        return EnergyPrioritySnapshot(
            schemaVersion=1,
            authority=authority,
            inputs=inputs,
            plan=plan,
            inverter=capability,
        )

    def reserve_backtest(self, actor, core_id, home_id):
        """Review recorded reserve samples without inferring missing intervals."""
        if self.history_provider is None:
            raise ApiError("energy_provider_unavailable", 503)
        before = self.snapshot(actor, core_id, home_id)
        try:
            observation = self.history_provider.observe(before.authority)
        except ApiError:
            raise
        except Exception:  # noqa: BLE001 -- private provider failures are redacted
            raise ApiError("energy_provider_unavailable", 503) from None
        after = self.snapshot(actor, core_id, home_id)
        stable_before = (
            before.authority,
            before.inputs.battery.resourceId,
            before.inputs.battery.providerRevision,
            before.inputs.battery.capacityWh,
            before.inputs.reserve,
            before.inputs.manualOverride,
        )
        stable_after = (
            after.authority,
            after.inputs.battery.resourceId,
            after.inputs.battery.providerRevision,
            after.inputs.battery.capacityWh,
            after.inputs.reserve,
            after.inputs.manualOverride,
        )
        if stable_after != stable_before:
            raise ApiError("revision_conflict", 409)
        try:
            assert_current = getattr(self.history_provider, "assert_current", None)
            if not callable(assert_current):
                raise ValueError("invalid_history_provider")
            assert_current(after.authority, observation)
            return analyze_reserve_history(
                after.authority,
                after.inputs,
                after.plan,
                observation,
            )
        except Exception:  # noqa: BLE001 -- never expose private history details
            raise ApiError("energy_provider_unavailable", 503) from None

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
        now = int(self.settings.clock() * 1000)
        slot_duration_ms = snapshot.inputs.forecast.slotDurationSeconds * 1_000
        if (
            capability is None
            or not capability.writable
            or (body.inverterId, body.expectedInverterRevision)
            != (capability.inverterId, capability.revision)
            or (slot.action == "charge" and not capability.canCharge)
            or (slot.action == "discharge" and not capability.canDischarge)
            or slot.action == "hold"
            or not slot.startsAtMs <= now < slot.startsAtMs + slot_duration_ms
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

    @staticmethod
    def _reserve_values(preview):
        return [
            preview.requestId,
            preview.coreId,
            preview.homeId,
            preview.accountId,
            preview.accountRevision,
            preview.memberRevision,
            preview.sessionFamilyId,
            preview.inverterId,
            preview.inverterRevision,
            preview.batteryId,
            preview.batteryRevision,
            preview.batteryProviderRevision,
            preview.inputDigest,
            preview.targetReservePercent,
            preview.expiresAtMs,
        ]

    def _reserve_token(self, preview):
        raw = json.dumps(
            self._reserve_values(preview), separators=(",", ":")
        ).encode("ascii")
        return hmac.new(self._command_key, raw, hashlib.sha256).hexdigest()

    def reserve_preview(self, actor, core_id, home_id, raw):
        body = PreviewReserveCommand.model_validate(raw)
        snapshot = self.snapshot(actor, core_id, home_id)
        capability = snapshot.inverter
        if (
            body.inputDigest != snapshot.plan.inputDigest
            or body.expectedAccountRevision != snapshot.authority.accountRevision
            or body.expectedHomeRevision != snapshot.authority.homeRevision
            or capability is None
            or not capability.writable
            or not capability.canSetReserve
            or capability.controlSemantics != "reserve_percent"
            or (body.inverterId, body.expectedInverterRevision)
            != (capability.inverterId, capability.revision)
            or body.targetReservePercent
            != snapshot.inputs.reserve.backupReservePercent
        ):
            raise ApiError("revision_conflict", 409)
        draft = ReserveCommandPreview(
            schemaVersion=1,
            requestId=body.requestId,
            coreId=snapshot.authority.coreId,
            homeId=snapshot.authority.homeId,
            accountId=snapshot.authority.accountId,
            accountRevision=snapshot.authority.accountRevision,
            memberRevision=snapshot.authority.memberRevision,
            sessionFamilyId=snapshot.authority.sessionFamilyId,
            inverterId=capability.inverterId,
            inverterRevision=capability.revision,
            batteryId=snapshot.inputs.battery.resourceId,
            batteryRevision=snapshot.inputs.battery.revision,
            batteryProviderRevision=snapshot.inputs.battery.providerRevision,
            inputDigest=snapshot.plan.inputDigest,
            targetReservePercent=body.targetReservePercent,
            expiresAtMs=int(self.settings.clock() * 1000) + 60_000,
            confirmationToken="0" * 64,
        )
        preview = draft.model_copy(
            update={"confirmationToken": self._reserve_token(draft)}
        )
        with self._lock:
            old = self._reserve_previews.get(preview.requestId)
            if old is not None and old != preview:
                raise ApiError("idempotency_conflict", 409)
            if old is None and len(self._reserve_previews) >= MAX_COMMANDS:
                raise ApiError("rate_limited", 429)
            self._reserve_previews[preview.requestId] = preview
        return preview

    def _reserve_context(self, actor, core_id, home_id):
        snapshot = self.snapshot(actor, core_id, home_id)
        if snapshot.inverter is None:
            raise ApiError("revision_conflict", 409)
        return (
            snapshot.authority,
            snapshot.inputs,
            snapshot.plan.inputDigest,
            snapshot.inverter,
        )

    @staticmethod
    def _reserve_result(receipt):
        status = {
            "verified": "confirmed",
            "uncertain": "uncertain",
            "mismatch": "mismatch",
        }[receipt.status]
        return ReserveCommandResult(
            schemaVersion=1,
            requestId=receipt.request_id,
            status=status,
            targetReservePercent=receipt.target_reserve_percent,
            observedReservePercent=receipt.observed_reserve_percent,
            bindingRevision=receipt.binding_revision,
        )

    def reserve_confirm(self, actor, core_id, home_id, request_id, token):
        self._scope(core_id, home_id)
        with self._lock:
            preview = self._reserve_previews.get(request_id)
        if (
            preview is None
            or not isinstance(token, str)
            or not secrets.compare_digest(token, self._reserve_token(preview))
            or int(self.settings.clock() * 1000) >= preview.expiresAtMs
        ):
            raise ApiError("invalid_request")
        authority, inputs, digest, capability = self._reserve_context(
            actor, core_id, home_id
        )
        if (
            (authority.coreId, authority.homeId, authority.accountId,
             authority.accountRevision, authority.memberRevision,
             authority.sessionFamilyId)
            != (preview.coreId, preview.homeId, preview.accountId,
                preview.accountRevision, preview.memberRevision,
                preview.sessionFamilyId)
            or (capability.inverterId, capability.revision)
            != (preview.inverterId, preview.inverterRevision)
            or (inputs.battery.resourceId, inputs.battery.revision,
                inputs.battery.providerRevision, digest)
            != (preview.batteryId, preview.batteryRevision,
                preview.batteryProviderRevision, preview.inputDigest)
        ):
            raise ApiError("revision_conflict", 409)
        receipt = self.reserve_control.apply(
            authority,
            inputs,
            capability,
            request_id=request_id,
            input_digest=digest,
            target_reserve_percent=preview.targetReservePercent,
            guard=lambda: self._reserve_context(actor, core_id, home_id),
        )
        return self._reserve_result(receipt)

    def reserve_result(self, actor, core_id, home_id, request_id):
        authority, inputs, digest, capability = self._reserve_context(
            actor, core_id, home_id
        )
        receipt = self.reserve_control.result(
            authority,
            inputs,
            capability,
            request_id=request_id,
            input_digest=digest,
            guard=lambda: self._reserve_context(actor, core_id, home_id),
        )
        return self._reserve_result(receipt)
