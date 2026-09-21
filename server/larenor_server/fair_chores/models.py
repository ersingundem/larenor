from typing import Annotated, Literal

from pydantic import Field, field_validator

from ..home_resources.models import FrozenModel, Identity, Revision

Timestamp = Annotated[float, Field(ge=0, le=253402300799)]


class CreateChore(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    title: str = Field(min_length=1, max_length=200)
    timezone: str = Field(min_length=1, max_length=128)
    intervalDays: int = Field(ge=1, le=365)
    dueAt: Timestamp

    @field_validator("title")
    @classmethod
    def safe_title(cls, value: str) -> str:
        if value != value.strip() or any(
            ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF
            for char in value
        ):
            raise ValueError("invalid_title")
        return value


class CompleteChore(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    expectedRevision: Revision
    completedAt: Timestamp


class DeferChore(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    expectedRevision: Revision
    days: int = Field(ge=1, le=30)
