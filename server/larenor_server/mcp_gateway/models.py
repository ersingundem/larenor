import math
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision


RequestKey = Annotated[
    str,
    Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$"),
]
ClientId = Annotated[
    str,
    Field(min_length=3, max_length=96, pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]+$"),
]
ToolId = Literal["home.resource_count.read", "home.note.create"]


class Versioned(FrozenModel):
    schemaVersion: Literal[1]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class CreateGrant(Versioned):
    requestKey: RequestKey
    clientId: ClientId
    clientName: Annotated[str, Field(min_length=1, max_length=80)]
    tools: list[ToolId] = Field(min_length=1, max_length=2)
    expiresAt: float

    @field_validator("clientName")
    @classmethod
    def safe_name(cls, value):
        value = " ".join(value.split())
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_client_name")
        return value

    @model_validator(mode="after")
    def closed_grant(self):
        if self.tools != sorted(set(self.tools)) or not math.isfinite(self.expiresAt):
            raise ValueError("invalid_grant")
        return self


class RevokeGrant(Versioned):
    expectedRevision: Revision


class InitializeParams(FrozenModel):
    protocolVersion: Literal["2025-06-18"]
    capabilities: dict = Field(default_factory=dict, max_length=16)
    clientInfo: dict = Field(default_factory=dict, max_length=8)


class EmptyParams(FrozenModel):
    pass


class ReadArguments(FrozenModel):
    pass


class PreviewNoteArguments(FrozenModel):
    phase: Literal["preview"]
    requestKey: RequestKey
    title: Annotated[str, Field(min_length=1, max_length=120)]

    @field_validator("title")
    @classmethod
    def safe_title(cls, value):
        value = " ".join(value.split())
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_title")
        return value


class ConfirmNoteArguments(FrozenModel):
    phase: Literal["confirm"]
    previewId: Identity
    expectedRevision: Revision


class ToolCallParams(FrozenModel):
    name: ToolId
    arguments: dict = Field(default_factory=dict, max_length=8)


class McpRequest(FrozenModel):
    jsonrpc: Literal["2.0"]
    id: int | str
    method: Literal["initialize", "ping", "tools/list", "tools/call"]
    params: dict = Field(default_factory=dict, max_length=16)

    @field_validator("id")
    @classmethod
    def bounded_id(cls, value):
        if type(value) is int:
            if not -(2**63) <= value <= 2**63 - 1:
                raise ValueError("invalid_id")
        elif not 1 <= len(value) <= 128:
            raise ValueError("invalid_id")
        return value
