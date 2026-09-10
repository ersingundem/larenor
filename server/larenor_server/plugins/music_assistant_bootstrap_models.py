"""Strict worker-private Music Assistant first-run input."""

from typing import Literal

from pydantic import ConfigDict, Field

from ..admin.models import ObjectId
from ..models import StrictModel


class PrivateMusicAssistantBootstrap(StrictModel):
    model_config = ConfigDict(extra='forbid', strict=True, frozen=True)

    schemaVersion: Literal[1] = 1
    installationId: ObjectId
    username: Literal['larenor-core'] = 'larenor-core'
    credential: str = Field(
        min_length=32, max_length=128, repr=False,
        pattern=r'^[A-Za-z0-9_-]+$')
