from datetime import date, timedelta
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision


PlanRevision = Annotated[int, Field(ge=0, le=2**63 - 1)]
Unit = Literal['g', 'kg', 'ml', 'l', 'piece']
Slot = Literal['breakfast', 'lunch', 'dinner', 'snack']
Locale = Literal['en', 'tr']


def safe_text(value: str):
    if value != value.strip() or any(
        ord(char) < 32 or ord(char) == 127 or
        0xD800 <= ord(char) <= 0xDFFF or
        0x202A <= ord(char) <= 0x202E or
        0x2066 <= ord(char) <= 0x2069
        for char in value
    ):
        raise ValueError('invalid_text')
    return value


class MealIngredient(FrozenModel):
    schemaVersion: Literal[1]
    quantityMillis: int = Field(ge=1, le=10_000_000)
    unit: Unit
    name: str = Field(min_length=1, max_length=120)

    _name = field_validator('name')(safe_text)


class MealRecipe(FrozenModel):
    schemaVersion: Literal[1]
    id: Identity
    locale: Locale
    title: str = Field(min_length=1, max_length=100)
    baseServings: int = Field(ge=1, le=24)
    ingredients: list[MealIngredient] = Field(min_length=1, max_length=32)

    _title = field_validator('title')(safe_text)


class MealPlanEntry(FrozenModel):
    schemaVersion: Literal[1]
    id: Identity
    date: str
    slot: Slot
    recipeId: Identity
    servings: int = Field(ge=1, le=24)
    personId: Identity
    expectedPersonRevision: Revision
    expectedPersonAclRevision: Revision

    @field_validator('date')
    @classmethod
    def canonical_date(cls, value):
        try:
            parsed = date.fromisoformat(value)
        except ValueError:
            raise ValueError('invalid_date') from None
        if parsed.isoformat() != value:
            raise ValueError('invalid_date')
        return value


class MealPlanFields(FrozenModel):
    weekStart: str
    recipes: list[MealRecipe] = Field(max_length=32)
    entries: list[MealPlanEntry] = Field(max_length=28)

    @model_validator(mode='after')
    def valid_week(self):
        try:
            start = date.fromisoformat(self.weekStart)
        except ValueError:
            raise ValueError('invalid_week') from None
        if start.isoformat() != self.weekStart or start.weekday() != 0:
            raise ValueError('invalid_week')
        recipes = {recipe.id for recipe in self.recipes}
        if len(recipes) != len(self.recipes):
            raise ValueError('duplicate_recipe')
        entry_ids = {entry.id for entry in self.entries}
        if len(entry_ids) != len(self.entries):
            raise ValueError('duplicate_entry')
        end = start + timedelta(days=7)
        for entry in self.entries:
            day = date.fromisoformat(entry.date)
            if not start <= day < end or entry.recipeId not in recipes:
                raise ValueError('invalid_entry')
        return self


class PutMealPlanRequest(MealPlanFields):
    schemaVersion: Literal[1]
    requestId: Identity
    expectedAccountRevision: Revision
    expectedRevision: PlanRevision


class StoredMealPlan(MealPlanFields):
    pass


class MealPlan(MealPlanFields):
    schemaVersion: Literal[1]
    revision: Revision


class MealPlanAuthority(HomeScope):
    accountId: Identity
    sessionFamilyId: Identity
    accountRevision: Revision
    planRevision: PlanRevision


class MealPlanResponse(FrozenModel):
    authority: MealPlanAuthority
    plan: MealPlan | None
