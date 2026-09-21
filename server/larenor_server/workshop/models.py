import math
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import HomeScope, Identity, Revision
from ..models import StrictModel


JobState = Literal["idle", "printing", "paused", "completed", "error"]
MaterialKind = Literal["pla", "petg", "abs", "tpu", "asa", "other"]
PrinterAction = Literal["pause", "cancel"]


def safe_label(value: str) -> str:
    if any(ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF
           for char in value):
        raise ValueError("invalid_label")
    value = value.strip()
    if not value:
        raise ValueError("invalid_label")
    return value


def finite(value: float) -> float:
    if type(value) is not float or not math.isfinite(value):
        raise ValueError("invalid_number")
    return value


class Versioned(StrictModel):
    schemaVersion: Literal[1]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class JobInput(StrictModel):
    jobId: Identity | None
    state: JobState
    progressPermille: int = Field(ge=0, le=1000)
    remainingSeconds: int | None = Field(ge=0, le=31_536_000)

    @model_validator(mode="after")
    def coherent(self):
        if self.state == "idle" and self.jobId is not None:
            raise ValueError("idle_job_has_identity")
        if self.state != "idle" and self.jobId is None:
            raise ValueError("active_job_missing_identity")
        return self


class MaterialInput(StrictModel):
    kind: MaterialKind
    remainingGrams: float = Field(ge=0, le=100_000)

    _remaining = field_validator("remainingGrams", mode="before")(finite)


class SafetyInput(StrictModel):
    connectivity: Literal["online", "offline"]
    thermal: Literal["normal", "warning", "runaway"]
    filament: Literal["available", "low", "runout", "unknown"]
    door: Literal["closed", "open", "unknown"]
    emergency: Literal["clear", "triggered"]
    observedAt: float

    _observed = field_validator("observedAt", mode="before")(finite)


class RegisterPrinter(Versioned):
    registrationId: Identity
    name: str = Field(min_length=1, max_length=80)
    serviceId: Identity
    expectedServiceRevision: Revision
    job: JobInput
    material: MaterialInput
    safety: SafetyInput

    _name = field_validator("name")(safe_label)


class UpdatePrinterState(Versioned):
    expectedPrinterRevision: Revision
    expectedServiceRevision: Revision
    expectedJobRevision: Revision
    expectedMaterialRevision: Revision
    expectedSafetyRevision: Revision
    job: JobInput
    material: MaterialInput
    safety: SafetyInput


class PreviewIntent(Versioned):
    expectedPrinterRevision: Revision
    expectedServiceRevision: Revision
    expectedJobRevision: Revision
    expectedMaterialRevision: Revision
    expectedSafetyRevision: Revision
    requestKey: str = Field(
        min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$"
    )
    action: PrinterAction


class ConfirmIntent(Versioned):
    confirmationToken: str = Field(
        min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]{43}$"
    )


class ServiceRef(StrictModel):
    id: Identity
    revision: Revision


class PrinterRef(HomeScope):
    kind: Literal["workshop_printer"]
    id: Identity


class JobStateView(JobInput):
    revision: Revision


class MaterialStateView(MaterialInput):
    revision: Revision


class SafetyStateView(SafetyInput):
    revision: Revision
    freshness: Literal["current", "stale"]


class PrinterView(StrictModel):
    schemaVersion: Literal[1]
    ref: PrinterRef
    revision: Revision
    name: str
    serviceRef: ServiceRef
    job: JobStateView
    material: MaterialStateView
    safety: SafetyStateView
    availableActions: list[PrinterAction] = Field(max_length=2)


class PrinterResponse(StrictModel):
    printer: PrinterView


class PrinterList(StrictModel):
    schemaVersion: Literal[1]
    printers: list[PrinterView] = Field(max_length=64)


class PreviewView(StrictModel):
    schemaVersion: Literal[1]
    id: Identity
    printerRef: PrinterRef
    action: PrinterAction
    confirmationToken: str
    expiresAt: float


class PreviewResponse(StrictModel):
    preview: PreviewView


class IntentAuthority(StrictModel):
    printerRevision: Revision
    serviceRevision: Revision
    jobRevision: Revision
    materialRevision: Revision
    safetyRevision: Revision


class IntentReceipt(StrictModel):
    schemaVersion: Literal[1]
    id: Identity
    sequence: int = Field(ge=1, le=2**63 - 1)
    printerRef: PrinterRef
    action: PrinterAction
    state: Literal["recorded"]
    effect: Literal["notDispatched"]
    authority: IntentAuthority
    createdAt: float


class IntentResponse(StrictModel):
    receipt: IntentReceipt


class IntentList(StrictModel):
    schemaVersion: Literal[1]
    intents: list[IntentReceipt] = Field(max_length=100)
