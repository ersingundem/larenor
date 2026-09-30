"""Private OpenSprinkler controller binding contracts."""

from typing import Literal
import re

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision
from ..services.models import canonical_base_url


class OpenSprinklerStationInput(FrozenModel):
    zoneId: Identity
    expectedZoneRevision: Revision
    stationIndex: int = Field(ge=0, le=255)


class OpenSprinklerControllerInput(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Revision | None
    expectedSourceRevision: Revision
    baseUrl: str = Field(min_length=1, max_length=2048, repr=False)
    passwordMd5: str = Field(
        min_length=32, max_length=32, pattern=r"^[0-9a-f]{32}$", repr=False
    )
    stations: list[OpenSprinklerStationInput] = Field(min_length=1, max_length=32)

    @field_validator("baseUrl")
    @classmethod
    def endpoint(cls, value):
        return canonical_base_url(value)

    @field_validator("passwordMd5")
    @classmethod
    def password(cls, value):
        if re.fullmatch(r"[0-9a-f]{32}", value) is None:
            raise ValueError("invalid_password_hash")
        return value

    @model_validator(mode="after")
    def unique_stations(self):
        zone_ids = [item.zoneId for item in self.stations]
        indexes = [item.stationIndex for item in self.stations]
        if len(zone_ids) != len(set(zone_ids)) or len(indexes) != len(set(indexes)):
            raise ValueError("duplicate_station")
        return self


class OpenSprinklerControllerMetadata(FrozenModel):
    schemaVersion: Literal[1]
    controllerId: Identity
    revision: Revision
    sourceRevision: Revision
    stations: list[OpenSprinklerStationInput]
    endpointConfigured: Literal[True]
    passwordConfigured: Literal[True]


class StoredOpenSprinklerController(FrozenModel):
    schemaVersion: Literal[1]
    controllerId: Identity
    revision: Revision
    sourceRevision: Revision
    baseUrl: str = Field(min_length=1, max_length=2048, repr=False)
    passwordMd5: str = Field(
        min_length=32, max_length=32, pattern=r"^[0-9a-f]{32}$", repr=False
    )
    stations: list[OpenSprinklerStationInput] = Field(min_length=1, max_length=32)

    def metadata(self):
        return OpenSprinklerControllerMetadata(
            schemaVersion=1,
            controllerId=self.controllerId,
            revision=self.revision,
            sourceRevision=self.sourceRevision,
            stations=self.stations,
            endpointConfigured=True,
            passwordConfigured=True,
        )
