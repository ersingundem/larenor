"""Closed request contracts for household habit observations."""

import math
from typing import Annotated, Literal

from pydantic import Field, field_validator

from ..home_resources.models import FrozenModel, Identity


RequestKey = Annotated[
    str, Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
]
SeriesId = Annotated[
    str, Field(min_length=1, max_length=64, pattern=r"^[a-z][a-z0-9_.-]*$")
]


class Versioned(FrozenModel):
    schemaVersion: Literal[1]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class RecordHabitObservation(Versioned):
    requestKey: RequestKey
    seriesId: SeriesId
    metric: SeriesId
    unit: Literal[
        "percent", "bytes", "milliseconds", "seconds", "count", "celsius", "ratio"
    ]
    value: float
    observedAtMs: Annotated[int, Field(ge=0, le=2**63 - 1)]

    @field_validator("value", mode="before")
    @classmethod
    def finite_value(cls, value):
        if type(value) not in (int, float) or not math.isfinite(value):
            raise ValueError("invalid_observation_value")
        return float(value)


class MarkHabitObservation(Versioned):
    requestKey: RequestKey
    expectedObservationId: Identity
    label: Literal["normal", "false_positive"]
