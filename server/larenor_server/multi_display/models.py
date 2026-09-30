from typing import Annotated, Literal

from pydantic import Field, StringConstraints, model_validator

from ..models import StrictModel


Identity = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]
Revision = Annotated[int, Field(ge=1, le=2**53 - 1)]


class MultiDisplayAuthority(StrictModel):
    schemaVersion: Literal[1] = 1
    coreId: Identity
    homeId: Identity
    accountId: Identity
    accountRevision: Revision
    homeRevision: Revision
    sessionFamilyId: Identity
    routePolicyRevision: Literal[2] = 2
    allowedSecondaryRoutes: tuple[Literal["core.status"], ...]


class PublicCoreStatus(StrictModel):
    schemaVersion: Literal[1] = 1
    snapshotRevision: Revision
    observedAtMs: Annotated[int, Field(ge=0, le=2**53 - 1)]
    expiresAtMs: Annotated[int, Field(ge=1, le=2**53 - 1)]
    serviceState: Literal["online"] = "online"
    apiVersion: Literal[1] = 1
    systemLoadPercent: Annotated[int, Field(ge=0, le=100)]
    processMemoryMiB: Annotated[int, Field(ge=0, le=1_048_576)]
    dataDiskFreeBytes: Annotated[int, Field(ge=0, le=2**53 - 1)]
    dataDiskTotalBytes: Annotated[int, Field(ge=1, le=2**53 - 1)]
    processUptimeSeconds: Annotated[int, Field(ge=0, le=2**53 - 1)]

    @model_validator(mode="after")
    def coherent(self):
        if (
            self.expiresAtMs <= self.observedAtMs
            or self.expiresAtMs - self.observedAtMs > 15_000
            or self.dataDiskFreeBytes > self.dataDiskTotalBytes
        ):
            raise ValueError("invalid_public_core_status")
        return self


class MultiDisplayProjection(StrictModel):
    schemaVersion: Literal[1] = 1
    authority: MultiDisplayAuthority
    publicSnapshot: PublicCoreStatus
