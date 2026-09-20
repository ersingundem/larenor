from datetime import date
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


Identity = str
StockUnit = Literal['g', 'kg', 'ml', 'l', 'piece']
MeasureKind = Literal['mass_mg', 'volume_ul', 'count_milli']


class FrozenModel(BaseModel):
    model_config = ConfigDict(extra='forbid', frozen=True, strict=True)


class StockAmount(FrozenModel):
    schemaVersion: Literal[1]
    quantityMillis: int = Field(ge=1, le=10_000_000)
    unit: StockUnit

    @property
    def normalized(self) -> tuple[MeasureKind, int]:
        kind, multiplier = {
            'g': ('mass_mg', 1),
            'kg': ('mass_mg', 1000),
            'ml': ('volume_ul', 1),
            'l': ('volume_ul', 1000),
            'piece': ('count_milli', 1),
        }[self.unit]
        value = self.quantityMillis * multiplier
        if value > 10_000_000_000:
            raise ValueError('quantity_out_of_range')
        return kind, value


class StockLot(FrozenModel):
    schemaVersion: Literal[1]
    id: str
    ingredientKey: str = Field(min_length=1, max_length=80)
    amount: StockAmount
    expiresOn: str | None = None

    @field_validator('id')
    @classmethod
    def identity(cls, value):
        if len(value) != 32 or any(char not in '0123456789abcdef' for char in value):
            raise ValueError('invalid_identity')
        return value

    @field_validator('ingredientKey')
    @classmethod
    def ingredient(cls, value):
        if (value != value.strip() or value != value.lower() or
                any(ord(char) < 32 or ord(char) == 127 for char in value)):
            raise ValueError('invalid_ingredient')
        return value

    @field_validator('expiresOn')
    @classmethod
    def expiry(cls, value):
        if value is None:
            return None
        try:
            parsed = date.fromisoformat(value)
        except ValueError:
            raise ValueError('invalid_expiry') from None
        if parsed.isoformat() != value:
            raise ValueError('invalid_expiry')
        return value


class LotBalance(FrozenModel):
    schemaVersion: Literal[1]
    lotId: str
    ingredientKey: str
    measure: MeasureKind
    remaining: int = Field(ge=1, le=10_000_000_000)
    expiresOn: str | None


class StockAllocation(FrozenModel):
    schemaVersion: Literal[1]
    lotId: str
    quantity: int = Field(ge=1, le=10_000_000_000)


class StockReceipt(FrozenModel):
    schemaVersion: Literal[1]
    requestId: str
    movementId: str
    revision: int = Field(ge=1, le=2**63 - 1)
    kind: Literal['receive', 'consume', 'undo']
    allocations: tuple[StockAllocation, ...] = ()


class StockSnapshot(FrozenModel):
    schemaVersion: Literal[1]
    revision: int = Field(ge=0, le=2**63 - 1)
    lots: tuple[LotBalance, ...]
