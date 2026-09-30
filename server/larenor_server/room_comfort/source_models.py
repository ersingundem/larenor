"""Persisted, revision-bound Home Assistant room-comfort source policy."""

from typing import Annotated, Literal
import re

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision


EntityId = Annotated[str, Field(min_length=3, max_length=128)]
_ENTITY = re.compile(r"[a-z0-9_]{1,64}\.[a-z0-9_]{1,121}\Z")


def _entity(value, domain):
    if _ENTITY.fullmatch(value) is None or not value.startswith(domain + "."):
        raise ValueError("invalid_entity")
    return value


class ComfortRoomSource(FrozenModel):
    roomId: Identity
    roomRevision: Revision
    areaId: Identity
    areaRevision: Revision
    climateEntityId: EntityId
    windowEntityId: EntityId
    temperatureEntityId: EntityId
    humidityEntityId: EntityId
    co2EntityId: EntityId
    vocEntityId: EntityId
    smokeEntityId: EntityId
    occupancyEntityId: EntityId

    @field_validator("climateEntityId")
    @classmethod
    def climate(cls, value):
        return _entity(value, "climate")

    @field_validator("windowEntityId")
    @classmethod
    def window(cls, value):
        return _entity(value, "cover")

    @field_validator(
        "temperatureEntityId", "humidityEntityId", "co2EntityId",
        "vocEntityId",
    )
    @classmethod
    def sensor(cls, value):
        return _entity(value, "sensor")

    @field_validator("smokeEntityId", "occupancyEntityId")
    @classmethod
    def binary_sensor(cls, value):
        return _entity(value, "binary_sensor")

    @model_validator(mode="after")
    def unique_entities(self):
        entities = [
            self.climateEntityId, self.windowEntityId,
            self.temperatureEntityId, self.humidityEntityId,
            self.co2EntityId, self.vocEntityId,
            self.smokeEntityId, self.occupancyEntityId,
        ]
        if len(entities) != len(set(entities)) or self.roomId == self.areaId:
            raise ValueError("duplicate_source")
        return self


class HomeAssistantComfortSourceInput(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Revision | None
    serviceId: Identity
    expectedServiceRevision: Revision
    weatherEntityId: EntityId
    aqiEntityId: EntityId
    targetTemperatureMilliC: int = Field(ge=5_000, le=35_000)
    temperatureToleranceMilliC: int = Field(ge=100, le=10_000)
    humidityHighPermille: int = Field(ge=1, le=1_000)
    co2HighPpm: int = Field(ge=400, le=10_000)
    vocHighPpb: int = Field(ge=1, le=100_000)
    outdoorAqiLimit: int = Field(ge=1, le=500)
    freezeThresholdMilliC: int = Field(ge=-50_000, le=15_000)
    indoorMaxAgeMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1000)
    outdoorMaxAgeMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1000)
    occupancyMaxAgeMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1000)
    previewTtlMs: int = Field(ge=1_000, le=60_000)
    rooms: list[ComfortRoomSource] = Field(min_length=1, max_length=32)

    @field_validator("weatherEntityId")
    @classmethod
    def weather(cls, value):
        return _entity(value, "weather")

    @field_validator("aqiEntityId")
    @classmethod
    def aqi(cls, value):
        return _entity(value, "sensor")

    @model_validator(mode="after")
    def unique_rooms(self):
        rooms = [item.roomId for item in self.rooms]
        entities = [
            self.weatherEntityId, self.aqiEntityId,
            *(entity for item in self.rooms for entity in (
                item.climateEntityId, item.windowEntityId,
                item.temperatureEntityId, item.humidityEntityId,
                item.co2EntityId, item.vocEntityId,
                item.smokeEntityId, item.occupancyEntityId,
            )),
        ]
        if len(rooms) != len(set(rooms)) or len(entities) != len(set(entities)):
            raise ValueError("duplicate_source")
        return self


class HomeAssistantComfortSource(FrozenModel):
    schemaVersion: Literal[1]
    revision: Revision
    serviceId: Identity
    serviceRevision: Revision
    weatherEntityId: EntityId
    aqiEntityId: EntityId
    targetTemperatureMilliC: int
    temperatureToleranceMilliC: int
    humidityHighPermille: int
    co2HighPpm: int
    vocHighPpb: int
    outdoorAqiLimit: int
    freezeThresholdMilliC: int
    indoorMaxAgeMs: int
    outdoorMaxAgeMs: int
    occupancyMaxAgeMs: int
    previewTtlMs: int
    rooms: list[ComfortRoomSource]

    @classmethod
    def from_input(cls, value, revision):
        raw = value.model_dump(mode="json")
        raw.pop("expectedRevision")
        raw["revision"] = revision
        raw["serviceRevision"] = raw.pop("expectedServiceRevision")
        return cls.model_validate(raw)


class ComfortSourceResponse(FrozenModel):
    schemaVersion: Literal[1]
    configuration: HomeAssistantComfortSource
