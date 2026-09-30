"""Explicit admin assignment of existing HA resources to a camera profile."""

from typing import Literal

from pydantic import Field, model_validator

from ..home_resources.models import FrozenModel, Identity
from .models import CameraMode


class CameraSourceReconcile(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    expectedSourceRevision: int = Field(ge=1, lt=2**63 - 1)
    cameraId: Identity
    expectedStateRevision: int = Field(ge=1, lt=2**63 - 1)
    mode: CameraMode


class CameraResourcePair(FrozenModel):
    recordingResourceId: Identity
    detectionResourceId: Identity
    areaId: Identity


class CameraSourceSettings(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: int = Field(ge=0, lt=2**63 - 1)
    presenceResourceId: Identity
    cameras: list[CameraResourcePair] = Field(min_length=1, max_length=16)
    enterDelayMs: int = Field(ge=0, le=3600000)
    exitDelayMs: int = Field(ge=0, le=3600000)
    hysteresisMs: int = Field(ge=0, le=900000)
    presenceMaxAgeMs: int = Field(ge=1000, le=86400000)
    atHomeMode: CameraMode
    awayMode: CameraMode
    failSafeMode: CameraMode

    @model_validator(mode='after')
    def distinct(self):
        targets = [value for pair in self.cameras for value in (
            pair.recordingResourceId, pair.detectionResourceId)]
        if (len(set(targets)) != len(targets) or self.presenceResourceId in targets
                or self.failSafeMode.recording != 'enabled'):
            raise ValueError('invalid_camera_source')
        return self
