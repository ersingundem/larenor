from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity


RequestKey = Annotated[
    str, Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
]
EventKey = Annotated[
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


class TrialRule(FrozenModel):
    ruleId: Identity
    eventKey: EventKey
    deviceId: Identity
    action: Literal["turn_on", "turn_off"]
    priority: Annotated[int, Field(ge=0, le=100)]
    weekdays: Annotated[list[Annotated[int, Field(ge=0, le=6)]], Field(min_length=1, max_length=7)]
    startMinute: Annotated[int, Field(ge=0, le=1439)]
    endMinute: Annotated[int, Field(ge=1, le=1440)]

    @model_validator(mode="after")
    def coherent_window(self):
        if len(set(self.weekdays)) != len(self.weekdays) or self.endMinute <= self.startMinute:
            raise ValueError("invalid_trial_window")
        return self


class CreateTrial(Versioned):
    requestKey: RequestKey
    timezone: Annotated[str, Field(min_length=1, max_length=128)]
    localStartDate: Annotated[str, Field(pattern=r"^\d{4}-\d{2}-\d{2}$")]
    rules: Annotated[list[TrialRule], Field(min_length=1, max_length=32)]

    @field_validator("rules")
    @classmethod
    def unique_rules(cls, value):
        if len({item.ruleId for item in value}) != len(value):
            raise ValueError("duplicate_trial_rule")
        return value


class EvaluateTrialEvent(Versioned):
    requestKey: RequestKey
    source: Literal["real", "synthetic"]
    eventKey: EventKey
    occurredAtMs: Annotated[int, Field(ge=0, le=2**63 - 1)]


class IngestHomeAssistantTrace(Versioned):
    requestKey: RequestKey
    expectedTrialId: Identity
    sourceResourceId: Identity


class ReplayTrial(Versioned):
    expectedTrialId: Identity
    requiredEventCount: Annotated[int, Field(ge=1, le=512)]
    proposedRules: Annotated[list[TrialRule], Field(min_length=1, max_length=32)]

    @field_validator("proposedRules")
    @classmethod
    def unique_rules(cls, value):
        if len({item.ruleId for item in value}) != len(value):
            raise ValueError("duplicate_trial_rule")
        return value
