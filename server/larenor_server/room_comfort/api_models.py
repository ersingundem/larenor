from typing import Literal

from pydantic import Field

from ..home_resources.models import FrozenModel, Identity, Revision
from .models import (
    ComfortPlan,
    ComfortPolicy,
    ComfortPreview,
    ComfortReceipt,
    ComfortDeviceReadback,
    ManualComfortOverride,
    OccupancySnapshot,
    OutdoorWeatherSnapshot,
    RoomClimateSnapshot,
)


class PublishComfortPlan(FrozenModel):
    schemaVersion: Literal[1]
    expectedHomeRevision: Revision
    policy: ComfortPolicy
    climate: list[RoomClimateSnapshot] = Field(min_length=1, max_length=32)
    weather: OutdoorWeatherSnapshot
    occupancy: list[OccupancySnapshot] = Field(min_length=1, max_length=32)
    overrides: list[ManualComfortOverride] = Field(max_length=32)
    readbacks: list[ComfortDeviceReadback] = Field(min_length=2, max_length=64)


class ComfortPlanResponse(FrozenModel):
    schemaVersion: Literal[1]
    plan: ComfortPlan


class PreviewComfortPlan(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    expectedPlanId: Identity
    expectedHomeRevision: Revision
    expectedPolicyRevision: Revision


class ComfortPreviewResponse(FrozenModel):
    schemaVersion: Literal[1]
    preview: ComfortPreview


class ConfirmComfortPlan(FrozenModel):
    schemaVersion: Literal[1]
    expectedPlanId: Identity
    expectedPolicyRevision: Revision
    confirmToken: str = Field(
        min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]{43}$"
    )


class ComfortReceiptResponse(FrozenModel):
    schemaVersion: Literal[1]
    receipt: ComfortReceipt
