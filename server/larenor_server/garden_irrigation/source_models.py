"""Persisted Home Assistant source settings for irrigation observations."""

from typing import Annotated, Literal
import re

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision


EntityId = Annotated[str, Field(min_length=3, max_length=128)]
_ENTITY = re.compile(r"[a-z0-9_]{1,64}\.[a-z0-9_]{1,121}\Z")


def _entity(value: str, domain: str) -> str:
    if _ENTITY.fullmatch(value) is None or not value.startswith(domain + "."):
        raise ValueError("invalid_entity")
    return value


class IrrigationZoneSource(FrozenModel):
    roomId: Identity
    roomRevision: Revision
    valveEntityId: EntityId
    soilMoistureEntityId: EntityId
    plantName: str = Field(min_length=1, max_length=120)
    flowMlPerMinute: int = Field(ge=1, le=1_000_000)
    maxDurationSeconds: int = Field(ge=1, le=7_200)

    @field_validator("valveEntityId")
    @classmethod
    def valve(cls, value):
        return _entity(value, "valve")

    @field_validator("soilMoistureEntityId")
    @classmethod
    def soil(cls, value):
        return _entity(value, "sensor")

    @field_validator("plantName")
    @classmethod
    def label(cls, value):
        value = value.strip()
        if not value or any(
            ord(char) < 32 or ord(char) == 127
            or 0xD800 <= ord(char) <= 0xDFFF
            for char in value
        ):
            raise ValueError("invalid_label")
        return value


class HomeAssistantIrrigationSourceInput(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Revision | None
    serviceId: Identity
    expectedServiceRevision: Revision
    weatherEntityId: EntityId
    leakEntityId: EntityId
    dailyWaterEntityId: EntityId
    targetMoisturePermille: int = Field(ge=1, le=1_000)
    soilMaxAgeMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1000)
    safetyMaxAgeMs: int = Field(ge=1_000, le=60 * 60 * 1000)
    forecastMaxAgeMs: int = Field(ge=60_000, le=48 * 60 * 60 * 1000)
    rainDeferralMilliMm: int = Field(ge=0, le=1_000_000)
    freezeThresholdMilliC: int = Field(ge=-50_000, le=20_000)
    windLimitMilliMps: int = Field(ge=0, le=100_000)
    previewTtlMs: int = Field(ge=1_000, le=60_000)
    dailyLimitMl: int = Field(ge=0, le=10_000_000_000)
    priceMicrosPerLiter: int = Field(ge=0, le=1_000_000_000)
    zones: list[IrrigationZoneSource] = Field(min_length=1, max_length=32)

    @field_validator("weatherEntityId")
    @classmethod
    def weather(cls, value):
        return _entity(value, "weather")

    @field_validator("leakEntityId")
    @classmethod
    def leak(cls, value):
        return _entity(value, "binary_sensor")

    @field_validator("dailyWaterEntityId")
    @classmethod
    def daily_water(cls, value):
        return _entity(value, "sensor")

    @model_validator(mode="after")
    def unique_entities(self):
        valves = [item.valveEntityId for item in self.zones]
        moisture = [item.soilMoistureEntityId for item in self.zones]
        if len(valves) != len(set(valves)) or len(moisture) != len(set(moisture)):
            raise ValueError("duplicate_entity")
        if len({self.weatherEntityId, self.leakEntityId,
                self.dailyWaterEntityId, *valves, *moisture}) != 3 + 2 * len(self.zones):
            raise ValueError("duplicate_entity")
        return self


class HomeAssistantIrrigationSource(FrozenModel):
    schemaVersion: Literal[1]
    revision: Revision
    serviceId: Identity
    serviceRevision: Revision
    weatherEntityId: EntityId
    leakEntityId: EntityId
    dailyWaterEntityId: EntityId
    targetMoisturePermille: int
    soilMaxAgeMs: int
    safetyMaxAgeMs: int
    forecastMaxAgeMs: int
    rainDeferralMilliMm: int
    freezeThresholdMilliC: int
    windLimitMilliMps: int
    previewTtlMs: int
    dailyLimitMl: int
    priceMicrosPerLiter: int
    zones: list[IrrigationZoneSource]

    @classmethod
    def from_input(cls, value: HomeAssistantIrrigationSourceInput, revision: int):
        raw = value.model_dump(mode="json")
        raw.pop("expectedRevision")
        raw["revision"] = revision
        raw["serviceRevision"] = raw.pop("expectedServiceRevision")
        return cls.model_validate(raw)
