"""Private persisted binding and public setup contracts for HA MQTT room presence."""

from typing import Annotated, Literal
import re

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot


EntityId = Annotated[str, Field(min_length=8, max_length=128)]
ProviderToken = Annotated[str, Field(min_length=1, max_length=96)]
_ENTITY = re.compile(r"sensor\.[a-z0-9_]{1,121}\Z")


def _safe_text(value, maximum):
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value) > maximum
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        raise ValueError("invalid_provider_text")
    return value.strip()


class MqttRoomMapping(FrozenModel):
    roomId: Identity
    roomRevision: Revision
    roomLabel: str = Field(min_length=1, max_length=80)
    providerToken: ProviderToken

    @field_validator("roomLabel")
    @classmethod
    def label(cls, value):
        return _safe_text(value, 80)

    @field_validator("providerToken")
    @classmethod
    def token(cls, value):
        return _safe_text(value, 96)


class MqttRoomSource(FrozenModel):
    schemaVersion: Literal[1]
    revision: Revision
    serviceId: Identity
    serviceRevision: Revision
    entityId: EntityId
    entityUniqueId: str = Field(min_length=1, max_length=255)
    entityName: str = Field(min_length=1, max_length=80)
    consentAccountId: Identity
    consentAccountRevision: Revision
    consentActive: bool
    maxSignalAgeMs: int = Field(ge=1_000, le=15 * 60 * 1000)
    mappings: list[MqttRoomMapping] = Field(min_length=1, max_length=32)

    @field_validator("entityId")
    @classmethod
    def entity(cls, value):
        if _ENTITY.fullmatch(value) is None:
            raise ValueError("invalid_entity")
        return value

    @field_validator("entityUniqueId")
    @classmethod
    def unique_id(cls, value):
        return _safe_text(value, 255)

    @field_validator("entityName")
    @classmethod
    def name(cls, value):
        return _safe_text(value, 80)

    @model_validator(mode="after")
    def unique_mappings(self):
        rooms = [item.roomId for item in self.mappings]
        tokens = [item.providerToken for item in self.mappings]
        if len(rooms) != len(set(rooms)) or len(tokens) != len(set(tokens)):
            raise ValueError("duplicate_mapping")
        return self


class MqttRoomSourceInput(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Revision | None
    serviceId: Identity
    expectedServiceRevision: Revision
    entityId: EntityId
    candidateId: Snapshot
    roomId: Identity
    expectedRoomRevision: Revision
    maxSignalAgeMs: int = Field(ge=1_000, le=15 * 60 * 1000)
    consent: Literal[True]

    @field_validator("entityId")
    @classmethod
    def entity(cls, value):
        if _ENTITY.fullmatch(value) is None:
            raise ValueError("invalid_entity")
        return value

class MqttRoomSourceView(FrozenModel):
    schemaVersion: Literal[1]
    revision: Revision
    serviceId: Identity
    serviceRevision: Revision
    entityId: EntityId
    entityName: str
    consentActive: bool
    maxSignalAgeMs: int
    rooms: list[dict] = Field(min_length=1, max_length=32)
    provider: Literal["home_assistant_mqtt_room"] = "home_assistant_mqtt_room"
    advisoryOnly: Literal[True] = True
    grantsAccess: Literal[False] = False


class MqttRoomEntityCandidate(FrozenModel):
    schemaVersion: Literal[1]
    candidateId: Snapshot
    entityId: EntityId
    name: str = Field(min_length=1, max_length=80)
    platform: Literal["mqtt_room"]


class MqttRoomConsentRevoke(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Revision


__all__ = [
    "MqttRoomEntityCandidate", "MqttRoomMapping", "MqttRoomSource",
    "MqttRoomConsentRevoke", "MqttRoomSourceInput", "MqttRoomSourceView",
]
