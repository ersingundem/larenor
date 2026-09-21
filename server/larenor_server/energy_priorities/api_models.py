from typing import Literal

from pydantic import Field

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot
from .models import EnergyAuthority, EnergyInputs, EnergyPlan, InverterCapability


class EnergyPrioritySnapshot(FrozenModel):
    schemaVersion: Literal[1]
    authority: EnergyAuthority
    inputs: EnergyInputs
    plan: EnergyPlan
    inverter: InverterCapability | None


class PreviewEnergyCommand(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    planId: Identity
    inputDigest: Snapshot
    slotIndex: int = Field(ge=0, le=95)
    inverterId: Identity
    expectedInverterRevision: Revision
    expectedAccountRevision: Revision
    expectedHomeRevision: Revision


class ConfirmEnergyCommand(FrozenModel):
    schemaVersion: Literal[1]
    confirmationToken: Snapshot
