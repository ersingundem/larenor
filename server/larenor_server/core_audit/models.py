"""Closed v1 response models for the Core audit verification API."""

from typing import Annotated, Literal

from pydantic import Field

from ..home_resources.models import FrozenModel, HomeScope, Identity, Snapshot
from .schema import MAX_ENTRIES


class CoreAuditVerification(FrozenModel):
    schemaVersion: Literal[1] = 1
    scope: HomeScope
    chainId: Identity
    sequence: Annotated[int, Field(ge=0, le=MAX_ENTRIES)]
    headHash: Snapshot
    checkpoint: Annotated[str, Field(min_length=1, max_length=512)]
    verified: Literal[True]
    comparedCheckpoint: bool
    causalityVerified: Literal[False]


class CoreAuditVerificationResponse(FrozenModel):
    verification: CoreAuditVerification
