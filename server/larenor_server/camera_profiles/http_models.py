"""Authenticated HTTP envelopes for camera profile readback."""

from typing import Literal

from pydantic import Field

from ..home_resources.models import FrozenModel, Identity
from .models import (
    CameraPrivacyBoundary,
    CameraProfileAuthority,
    CameraProfileDecision,
    CameraProfilePolicy,
    CameraProviderSupport,
    CameraReadback,
    PresenceSignal,
)


class CameraProfileSnapshot(FrozenModel):
    schemaVersion: Literal[1]
    authority: CameraProfileAuthority
    policy: CameraProfilePolicy
    signal: PresenceSignal
    decision: CameraProfileDecision
    readbacks: list[CameraReadback] = Field(min_length=1, max_length=64)
    support: list[CameraProviderSupport] = Field(min_length=1, max_length=64)
    privacyBoundary: CameraPrivacyBoundary = CameraPrivacyBoundary()


class CameraProfileApplyRequest(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    authority: CameraProfileAuthority
    policy: CameraProfilePolicy
    signal: PresenceSignal
    decision: CameraProfileDecision
    readbacks: list[CameraReadback] = Field(min_length=1, max_length=64)
    support: list[CameraProviderSupport] = Field(min_length=1, max_length=64)
