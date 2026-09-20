from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision


class InventoryRef(HomeScope):
    kind: Literal["inventory_item"]
    id: Identity


class InventoryLinks(FrozenModel):
    schemaVersion: Literal[1]
    roomId: Identity | None
    deviceId: Identity | None
    documentIds: list[Identity] = Field(max_length=16)

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value

    @field_validator("documentIds")
    @classmethod
    def unique_documents(cls, value):
        if len(value) != len(set(value)):
            raise ValueError("duplicate_document")
        return value


class CreateInventoryItem(FrozenModel):
    schemaVersion: Literal[1]
    label: str = Field(min_length=1, max_length=120)
    roomId: Identity | None
    deviceId: Identity | None
    documentIds: list[Identity] = Field(max_length=16)
    readerIds: list[Identity] = Field(max_length=64)

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value

    @field_validator("label")
    @classmethod
    def safe_label(cls, value):
        value = value.strip()
        if not value or any(
            ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF
            for char in value
        ):
            raise ValueError("invalid_label")
        return value

    @model_validator(mode="after")
    def closed_sets(self):
        if len(self.documentIds) != len(set(self.documentIds)):
            raise ValueError("duplicate_document")
        if len(self.readerIds) != len(set(self.readerIds)):
            raise ValueError("duplicate_reader")
        return self


class StoredInventoryItem(FrozenModel):
    label: str = Field(min_length=1, max_length=120)
    links: InventoryLinks
    readerIds: list[Identity] = Field(max_length=64)
    createdBy: Identity

    @model_validator(mode="after")
    def unique_readers(self):
        if len(self.readerIds) != len(set(self.readerIds)):
            raise ValueError("duplicate_reader")
        return self


class InventoryItem(FrozenModel):
    schemaVersion: Literal[1]
    ref: InventoryRef
    revision: Revision
    label: str
    links: InventoryLinks


class InventoryQr(FrozenModel):
    schemaVersion: Literal[1]
    format: Literal["larenor_inventory_v1"]
    value: str = Field(min_length=1, max_length=160)


class InventoryItemResponse(FrozenModel):
    item: InventoryItem


class CreatedInventoryItemResponse(InventoryItemResponse):
    qr: InventoryQr
