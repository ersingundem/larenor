"""Closed request contracts for read-only, evidence-linked diagnostics."""

import math
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Revision


TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
SourceId = Annotated[
    str,
    Field(min_length=1, max_length=96, pattern=r"^[A-Za-z0-9][A-Za-z0-9._:/-]*$"),
]
FactId = Annotated[
    str,
    Field(min_length=1, max_length=96, pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]*$"),
]
Metric = Annotated[
    str,
    Field(min_length=1, max_length=80, pattern=r"^[a-z][a-z0-9_.-]*$"),
]
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


class DiagnosticMeasurement(FrozenModel):
    measurementId: FactId
    metric: Metric
    value: float
    unit: Literal[
        "percent", "bytes", "milliseconds", "seconds", "count", "celsius", "ratio"
    ]
    comparator: Literal["above", "at_or_above", "below", "at_or_below"] | None = None
    threshold: float | None = None

    @model_validator(mode="after")
    def finite_threshold(self):
        if not math.isfinite(self.value):
            raise ValueError("invalid_measurement")
        if (self.comparator is None) != (self.threshold is None):
            raise ValueError("incomplete_threshold")
        if self.threshold is not None and not math.isfinite(self.threshold):
            raise ValueError("invalid_threshold")
        return self


class DiagnosticEvent(FrozenModel):
    eventId: FactId
    kind: FactId
    severity: Literal["info", "warning", "critical", "unknown"]
    occurredAtMs: TimestampMs


class DiagnosticSource(FrozenModel):
    sourceId: SourceId
    sourceType: Literal["health", "event", "measurement"]
    revision: Revision
    capturedAtMs: TimestampMs
    state: Literal[
        "healthy", "attention", "degraded", "critical", "unavailable", "unknown"
    ]
    # Upstream text is never evidence for a decision. The service deliberately
    # discards it and reports the field as redacted before persistence.
    detail: str | None = Field(default=None, min_length=1, max_length=512, repr=False)
    measurements: list[DiagnosticMeasurement] = Field(default_factory=list, max_length=32)
    events: list[DiagnosticEvent] = Field(default_factory=list, max_length=32)

    @field_validator("detail")
    @classmethod
    def safe_detail_shape(cls, value):
        if value is not None and any(
            ord(char) == 0 or 0xD800 <= ord(char) <= 0xDFFF for char in value
        ):
            raise ValueError("invalid_detail")
        return value

    @model_validator(mode="after")
    def coherent_facts(self):
        measurements = [item.measurementId for item in self.measurements]
        events = [item.eventId for item in self.events]
        if len(measurements) != len(set(measurements)) or len(events) != len(set(events)):
            raise ValueError("duplicate_source_fact")
        if any(item.occurredAtMs > self.capturedAtMs for item in self.events):
            raise ValueError("event_after_capture")
        if self.sourceType == "event" and not self.events:
            raise ValueError("event_source_empty")
        if self.sourceType == "measurement" and not self.measurements:
            raise ValueError("measurement_source_empty")
        return self


class CreateDiagnosis(Versioned):
    requestKey: RequestKey
    sources: list[DiagnosticSource] = Field(min_length=1, max_length=32)

    @field_validator("sources")
    @classmethod
    def unique_sources(cls, value):
        source_ids = [item.sourceId for item in value]
        if len(source_ids) != len(set(source_ids)):
            raise ValueError("duplicate_diagnostic_source")
        return value


class CreateRepairPreview(Versioned):
    requestKey: RequestKey
    expectedDiagnosisRevision: Revision
