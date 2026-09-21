from typing import Annotated, Literal

from pydantic import Field

from ..home_resources.models import FrozenModel, Identity, Revision

TimestampMs = Annotated[int, Field(ge=1, le=2**63 - 1)]
Digest = Annotated[str, Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")]


class PreviewCharge(FrozenModel):
    schemaVersion: Literal[1]
    previewId: Identity
    expectedChargerRevision: Revision
    expectedScheduleRevision: Revision
    expectedTariffRevision: Revision
    expectedPowerBudgetRevision: Revision
    departureAtMs: TimestampMs
    targetSoc: int = Field(ge=0, le=100)


class ConfirmCharge(FrozenModel):
    schemaVersion: Literal[1]
    previewId: Identity
    commandId: Identity
    expectedPlanHash: Digest
    expectedChargerRevision: Revision
    expectedScheduleRevision: Revision
