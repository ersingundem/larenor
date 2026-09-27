from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class FrozenModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True, strict=True)


class CreateCookingSessionRequest(FrozenModel):
    schemaVersion: Literal[1]
    recipeId: str = Field(min_length=1, max_length=128)
    recipeRevision: int = Field(ge=1, le=2**63 - 1)
    title: str = Field(min_length=1, max_length=200)
    steps: tuple[str, ...] = Field(min_length=1, max_length=100)

    @field_validator("recipeId")
    @classmethod
    def identifier(cls, value: str) -> str:
        if any(not (char.isalnum() or char in "-_.:") for char in value):
            raise ValueError("invalid_recipe_id")
        return value

    @field_validator("title")
    @classmethod
    def normalized_title(cls, value: str) -> str:
        if value != value.strip():
            raise ValueError("invalid_title")
        return value

    @field_validator("steps", mode="before")
    @classmethod
    def bounded_steps(cls, value) -> tuple[str, ...]:
        if not isinstance(value, (list, tuple)):
            raise ValueError("invalid_steps")
        value = tuple(value)
        if any(
            step != step.strip() or not step or len(step) > 2000
            for step in value
        ):
            raise ValueError("invalid_steps")
        return value


class MoveCookingSessionRequest(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: int = Field(ge=1, le=2**63 - 1)
    step: int = Field(ge=0, le=99)


class CancelCookingSessionRequest(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: int = Field(ge=1, le=2**63 - 1)


class CookingSessionDocument(FrozenModel):
    schemaVersion: Literal[1]
    id: str
    accountId: str
    recipeId: str
    recipeRevision: int = Field(ge=1, le=2**63 - 1)
    revision: int = Field(ge=1, le=2**63 - 1)
    title: str
    steps: tuple[str, ...] = Field(min_length=1, max_length=100)
    currentStep: int = Field(ge=0, le=99)
    cancelled: bool


class CookingSessionResponse(FrozenModel):
    schemaVersion: Literal[1]
    session: CookingSessionDocument


class CookingSessionListResponse(FrozenModel):
    schemaVersion: Literal[1]
    sessions: tuple[CookingSessionDocument, ...] = Field(max_length=100)


class IngredientDeductionItem(FrozenModel):
    stockItemId: str = Field(min_length=1, max_length=80)
    quantityMicros: int = Field(ge=1, le=10_000_000)
    unit: Literal["g", "ml", "piece"] = "g"

    @field_validator("stockItemId")
    @classmethod
    def ingredient(cls, value: str) -> str:
        if (
            value != value.strip()
            or value != value.lower()
            or any(ord(char) < 32 or ord(char) == 127 for char in value)
        ):
            raise ValueError("invalid_ingredient")
        return value


class IngredientDeductionRequest(FrozenModel):
    schemaVersion: Literal[1]
    idempotencyKey: str
    recipeRevision: int = Field(ge=1, le=2**63 - 1)
    completedStep: int = Field(ge=0, le=99)
    stepRevision: int = Field(ge=1, le=2**63 - 1)
    expectedPantryRevision: int = Field(ge=0, le=2**63 - 1)
    items: tuple[IngredientDeductionItem, ...] = Field(min_length=1, max_length=100)

    @field_validator("idempotencyKey")
    @classmethod
    def digest(cls, value: str) -> str:
        if len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
            raise ValueError("invalid_idempotency_key")
        return value

    @field_validator("items", mode="before")
    @classmethod
    def unique_items(cls, value):
        if not isinstance(value, (list, tuple)):
            raise ValueError("invalid_items")
        value = tuple(value)
        identities = [
            item.stockItemId if isinstance(item, IngredientDeductionItem)
            else item.get("stockItemId") if isinstance(item, dict)
            else None
            for item in value
        ]
        if len(set(identities)) != len(identities):
            raise ValueError("duplicate_ingredient")
        return value


class IngredientDeductionReceipt(FrozenModel):
    schemaVersion: Literal[1]
    idempotencyKey: str
    accountId: str
    pantryRevision: int = Field(ge=1, le=2**63 - 1)
    applied: tuple[IngredientDeductionItem, ...] = Field(min_length=1, max_length=100)

    @field_validator("applied", mode="before")
    @classmethod
    def applied_tuple(cls, value):
        if not isinstance(value, (list, tuple)):
            raise ValueError("invalid_applied_items")
        return tuple(value)


class IngredientDeductionResponse(FrozenModel):
    schemaVersion: Literal[1]
    receipt: IngredientDeductionReceipt
