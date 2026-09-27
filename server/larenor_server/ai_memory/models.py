"""Strict public contracts for visible, time-bounded AI memory."""

from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import Identity, Revision
from ..models import StrictModel


RequestKey = Annotated[
    str, Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
]
MemoryText = Annotated[str, Field(min_length=1, max_length=2048)]
DurationSeconds = Annotated[int, Field(ge=300, le=31_536_000)]


class Versioned(StrictModel):
    schemaVersion: Literal[1] = 1

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def exact_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class MemorySource(Versioned):
    kind: Literal["manual", "assistant", "automation", "integration"]
    description: str = Field(min_length=1, max_length=160)

    @field_validator("description")
    @classmethod
    def safe_description(cls, value):
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_memory_source")
        return value


class RememberMemory(Versioned):
    requestKey: RequestKey
    source: MemorySource
    content: MemoryText
    durationSeconds: DurationSeconds

    @field_validator("content")
    @classmethod
    def safe_content(cls, value):
        value = value.strip()
        if not value or "\x00" in value:
            raise ValueError("invalid_memory_content")
        return value


class CorrectMemory(RememberMemory):
    expectedRevision: Revision


class ForgetMemory(Versioned):
    requestKey: RequestKey
    expectedRevision: Revision
    reason: Literal["userRequested", "privacy", "obsolete", "incorrect"]


class SearchMemory(Versioned):
    query: str = Field(min_length=1, max_length=256)
    limit: Annotated[int, Field(ge=1, le=50)] = 20

    @field_validator("query")
    @classmethod
    def safe_query(cls, value):
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_memory_query")
        return value


class BackupMemoryRecord(Versioned):
    memoryId: Identity
    revision: Revision
    source: MemorySource
    content: MemoryText
    learnedBy: str = Field(min_length=1, max_length=80)
    createdAt: float = Field(ge=0)
    updatedAt: float = Field(ge=0)
    expiresAt: float = Field(gt=0)

    @field_validator("content")
    @classmethod
    def safe_content(cls, value):
        value = value.strip()
        if not value or "\x00" in value:
            raise ValueError("invalid_memory_content")
        return value

    @field_validator("learnedBy")
    @classmethod
    def safe_user_label(cls, value):
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_memory_user")
        return value

    @model_validator(mode="after")
    def coherent_times(self):
        if self.updatedAt < self.createdAt or self.expiresAt <= self.createdAt:
            raise ValueError("invalid_memory_times")
        return self


class BackupMemoryTombstone(Versioned):
    memoryId: Identity
    deletedRevision: Revision
    deletedAt: float = Field(ge=0)
    reason: Literal["userRequested", "privacy", "obsolete", "incorrect", "expired"]


class RestoreAiMemoryBackup(Versioned):
    requestKey: RequestKey
    records: list[BackupMemoryRecord] = Field(default_factory=list, max_length=1024)
    tombstones: list[BackupMemoryTombstone] = Field(
        default_factory=list, max_length=2048
    )

    @model_validator(mode="after")
    def unique_items(self):
        record_ids = [item.memoryId for item in self.records]
        tombstone_ids = [item.memoryId for item in self.tombstones]
        if len(set(record_ids)) != len(record_ids) or len(set(tombstone_ids)) != len(
            tombstone_ids
        ):
            raise ValueError("duplicate_memory_backup_item")
        return self
