from datetime import date
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision

LibraryRevision = Annotated[int, Field(ge=0, le=2**63 - 1)]
Digest = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
CanonicalDate = Annotated[str, Field(min_length=10, max_length=10)]


def _date(value):
    if value is None:
        return None
    if type(value) is not str or len(value) != 10:
        raise ValueError("invalid_date")
    try:
        parsed = date.fromisoformat(value)
    except ValueError:
        raise ValueError("invalid_date") from None
    if parsed.isoformat() != value:
        raise ValueError("invalid_date")
    return value


def _safe_text(value, *, lower=False):
    if type(value) is not str or value != value.strip() or not value:
        raise ValueError("invalid_text")
    if lower and value != value.lower():
        raise ValueError("invalid_text")
    if any(
        ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF
        for char in value
    ):
        raise ValueError("invalid_text")
    return value


class DocumentActor(FrozenModel):
    schemaVersion: Literal[1]
    accountId: Identity
    accountRevision: Revision
    sessionFamilyId: Identity
    role: Literal["admin", "member"]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class DocumentBlobRef(FrozenModel):
    schemaVersion: Literal[1]
    resourceId: Identity
    serviceRevision: Revision
    contentLength: int = Field(ge=1, le=256 * 1024)
    sha256: Digest
    contentType: Literal["application/pdf", "image/jpeg", "image/png"]

    _version = field_validator("schemaVersion", mode="before")(
        DocumentActor.integer_version.__func__
    )


class OcrWarrantyCandidate(FrozenModel):
    """Untrusted extraction evidence; never schedules a reminder by itself."""

    schemaVersion: Literal[1]
    extractedDate: CanonicalDate
    confidencePermille: int = Field(ge=0, le=1000)
    sourceRevision: Revision
    sourceDigest: Digest

    _version = field_validator("schemaVersion", mode="before")(
        DocumentActor.integer_version.__func__
    )
    _canonical_date = field_validator("extractedDate")(_date)


class WarrantyState(FrozenModel):
    candidate: OcrWarrantyCandidate | None
    confirmedDate: CanonicalDate | None
    confirmedBy: Identity | None
    confirmedAt: float | None = Field(ge=0)
    correctedFromOcr: bool

    _confirmed_date = field_validator("confirmedDate")(_date)

    @model_validator(mode="after")
    def coherent_confirmation(self):
        confirmed = self.confirmedDate is not None
        if confirmed != (self.confirmedBy is not None) or confirmed != (
            self.confirmedAt is not None
        ):
            raise ValueError("invalid_confirmation")
        if not confirmed and self.correctedFromOcr:
            raise ValueError("invalid_confirmation")
        return self


class HomeDocumentRef(HomeScope):
    kind: Literal["home_document"]
    id: Identity


class HomeDocument(FrozenModel):
    schemaVersion: Literal[1]
    ref: HomeDocumentRef
    revision: Revision
    title: str = Field(min_length=1, max_length=120)
    kind: Literal["invoice", "manual", "warranty", "other"]
    inventoryItemId: Identity
    blob: DocumentBlobRef
    warranty: WarrantyState
    createdAt: float = Field(ge=0)
    updatedAt: float = Field(ge=0)

    _version = field_validator("schemaVersion", mode="before")(
        DocumentActor.integer_version.__func__
    )

    @field_validator("title")
    @classmethod
    def safe_title(cls, value):
        return _safe_text(value)

    @model_validator(mode="after")
    def ordered_timestamps(self):
        if self.updatedAt < self.createdAt:
            raise ValueError("invalid_timestamps")
        return self


class DocumentAuthority(HomeScope):
    accountId: Identity
    sessionFamilyId: Identity
    accountRevision: Revision
    libraryRevision: LibraryRevision


class DocumentCommand(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    requestId: Identity
    expectedAccountRevision: Revision
    expectedRevision: LibraryRevision

    _version = field_validator("schemaVersion", mode="before")(
        DocumentActor.integer_version.__func__
    )


class CreateHomeDocumentCommand(DocumentCommand):
    documentId: Identity
    title: str = Field(min_length=1, max_length=120)
    kind: Literal["invoice", "manual", "warranty", "other"]
    inventoryItemId: Identity
    blob: DocumentBlobRef
    readerIds: list[Identity] = Field(max_length=64)
    ocrCandidate: OcrWarrantyCandidate | None
    reminderLeadDays: list[int] = Field(max_length=8)

    _title = field_validator("title")(HomeDocument.safe_title.__func__)

    @model_validator(mode="after")
    def closed_sets(self):
        if (
            len(self.readerIds) != len(set(self.readerIds))
            or len(self.reminderLeadDays) != len(set(self.reminderLeadDays))
            or any(type(value) is not int or not 0 <= value <= 365 for value in self.reminderLeadDays)
        ):
            raise ValueError("invalid_document_sets")
        return self


class ConfirmWarrantyCommand(DocumentCommand):
    documentId: Identity
    expectedDocumentRevision: Revision
    confirmedDate: CanonicalDate

    _confirmed_date = field_validator("confirmedDate")(_date)


class DocumentCommandResult(FrozenModel):
    authority: DocumentAuthority
    document: HomeDocument
    replayed: bool


class DocumentPage(FrozenModel):
    schemaVersion: Literal[1]
    authority: DocumentAuthority
    items: list[HomeDocument] = Field(max_length=50)
    hasMore: bool


class WarrantyReminder(FrozenModel):
    schemaVersion: Literal[1]
    documentId: Identity
    inventoryItemId: Identity
    title: str
    remindOn: CanonicalDate
    expiresOn: CanonicalDate

    _remind_on = field_validator("remindOn")(_date)
    _expires_on = field_validator("expiresOn")(_date)


class WarrantyReminderPage(FrozenModel):
    schemaVersion: Literal[1]
    authority: DocumentAuthority
    items: list[WarrantyReminder] = Field(max_length=100)
    hasMore: bool
