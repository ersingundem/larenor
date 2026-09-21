from typing import Literal

from pydantic import Field, field_validator

from ..home_resources.models import FrozenModel, Identity, Revision


class CreateExpense(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    expectedLedgerRevision: Revision
    expectedMembersRevision: Revision
    title: str = Field(min_length=1, max_length=200)
    currency: Literal["EUR", "GBP", "JPY", "TRY", "USD"]
    totalMinor: int = Field(ge=1, le=10**12)
    payerId: Identity
    participantIds: list[Identity] = Field(min_length=1, max_length=32)

    @field_validator("title")
    @classmethod
    def safe_title(cls, value):
        if value != value.strip() or any(
            ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF
            for char in value
        ):
            raise ValueError("invalid_title")
        return value

    @field_validator("participantIds")
    @classmethod
    def unique_participants(cls, value):
        if len(set(value)) != len(value):
            raise ValueError("duplicate_participant")
        return value


class ExpectedLedger(FrozenModel):
    schemaVersion: Literal[1]
    expectedLedgerRevision: Revision
