import unicodedata
from typing import Annotated, Literal

from pydantic import Field, field_validator

from ..home_resources.models import FrozenModel, Identity, Revision


RequestKey = Annotated[str, Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")]


class Versioned(FrozenModel):
    schemaVersion: Literal[1]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class CreateAutomationDraft(Versioned):
    requestKey: RequestKey
    transcript: Annotated[str, Field(min_length=1, max_length=256)]
    resourceId: Identity
    expectedResourceRevision: Revision
    expectedAclRevision: Revision
    expectedBindingRevision: Revision
    expectedServiceRevision: Revision

    @field_validator("transcript")
    @classmethod
    def safe_transcript(cls, value):
        value = " ".join(value.split())
        if not value or any(unicodedata.category(char).startswith("C") for char in value):
            raise ValueError("invalid_transcript")
        return value


class ActivateAutomationDraft(Versioned):
    requestKey: RequestKey
    expectedDraftRevision: Revision
    confirmed: Literal[True]
