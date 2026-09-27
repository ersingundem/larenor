from typing import Annotated, Literal

from pydantic import Field, field_validator

from ..home_resources.models import FrozenModel, Identity, Revision


RequestKey = Annotated[
    str,
    Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$"),
]


class Versioned(FrozenModel):
    schemaVersion: Literal[1]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class CreateMiniPlugin(Versioned):
    requestKey: RequestKey
    templateId: Literal["home-resource-count"]
    displayName: Annotated[str, Field(min_length=1, max_length=48)]

    @field_validator("displayName")
    @classmethod
    def safe_name(cls, value):
        value = " ".join(value.split())
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_display_name")
        return value


class StopMiniPlugin(Versioned):
    requestKey: RequestKey
    expectedRevision: Revision


class RenderMiniPlugin(Versioned):
    expectedRevision: Revision
