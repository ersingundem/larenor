import pytest
from larenor_server.errors import ApiError
from larenor_server.home_documents.models import (
    ConfirmWarrantyCommand,
    CreateHomeDocumentCommand,
    DocumentActor,
    DocumentBlobRef,
    OcrWarrantyCandidate,
)
from larenor_server.home_documents.service import HomeDocumentLibrary
from larenor_server.home_resources.models import HomeScope

CORE = "1" * 32
HOME = "2" * 32
ADMIN = "3" * 32
READER = "4" * 32
STRANGER = "5" * 32
FAMILY = "6" * 32
DOCUMENT = "7" * 32
INVENTORY = "8" * 32
BLOB = "9" * 32
REQUEST = "a" * 32
CONFIRM = "b" * 32


def actor(identity=ADMIN, *, role="admin", revision=4, family=FAMILY):
    return DocumentActor(
        schemaVersion=1,
        accountId=identity,
        accountRevision=revision,
        sessionFamilyId=family,
        role=role,
    )


def blob(revision=3):
    return DocumentBlobRef(
        schemaVersion=1,
        resourceId=BLOB,
        serviceRevision=revision,
        contentLength=1024,
        sha256="c" * 64,
        contentType="application/pdf",
    )


def create_command(**changes):
    values = {
        "schemaVersion": 1,
        "coreId": CORE,
        "homeId": HOME,
        "requestId": REQUEST,
        "expectedAccountRevision": 4,
        "expectedRevision": 0,
        "documentId": DOCUMENT,
        "title": "Buzdolabı faturası",
        "kind": "invoice",
        "inventoryItemId": INVENTORY,
        "blob": blob(),
        "readerIds": [READER],
        "ocrCandidate": OcrWarrantyCandidate(
            schemaVersion=1,
            extractedDate="2028-05-10",
            confidencePermille=810,
            sourceRevision=12,
            sourceDigest="d" * 64,
        ),
        "reminderLeadDays": [30, 7],
    }
    values.update(changes)
    return CreateHomeDocumentCommand(**values)


def library(*, blob_allowed=True, inventory_allowed=True):
    return HomeDocumentLibrary(
        HomeScope(schemaVersion=1, coreId=CORE, homeId=HOME),
        blob_current=lambda _actor, value: blob_allowed and value == blob(),
        inventory_current=lambda _actor, value: inventory_allowed and value == INVENTORY,
        clock=lambda: 1_800_000_000.0,
    )


def test_verified_create_is_exactly_idempotent_and_reference_bounded():
    store = library()
    result = store.create(actor(), create_command())
    replay = store.create(actor(), create_command())
    assert result.authority.libraryRevision == 1
    assert result.document.revision == 1
    assert result.document.warranty.confirmedDate is None
    assert replay.replayed is True
    assert replay.document == result.document
    assert store.revision == 1

    with pytest.raises(ApiError, match="idempotency_conflict"):
        store.create(actor(), create_command(title="Değiştirilmiş fatura"))
    with pytest.raises(ApiError, match="not_found"):
        library(blob_allowed=False).create(actor(), create_command())
    with pytest.raises(ApiError, match="not_found"):
        library(inventory_allowed=False).create(actor(), create_command())
    with pytest.raises(ApiError, match="revision_conflict"):
        library().create(actor(revision=5), create_command())


def test_ocr_date_needs_explicit_confirmation_and_correction_is_audited():
    store = library()
    store.create(actor(), create_command())
    assert store.due(actor(READER, role="member"), today="2028-04-10").items == []

    command = ConfirmWarrantyCommand(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        requestId=CONFIRM,
        expectedAccountRevision=4,
        expectedRevision=1,
        documentId=DOCUMENT,
        expectedDocumentRevision=1,
        confirmedDate="2028-06-01",
    )
    result = store.confirm_warranty(actor(), command)
    replay = store.confirm_warranty(actor(), command)
    assert result.document.warranty.confirmedDate == "2028-06-01"
    assert result.document.warranty.correctedFromOcr is True
    assert result.document.warranty.confirmedBy == ADMIN
    assert result.document.revision == 2
    assert replay.replayed is True

    with pytest.raises(ApiError, match="revision_conflict"):
        store.confirm_warranty(
            actor(), command.model_copy(update={"requestId": "e" * 32})
        )
    with pytest.raises(ApiError, match="forbidden"):
        store.confirm_warranty(
            actor(READER, role="member"),
            command.model_copy(
                update={
                    "requestId": "f" * 32,
                    "expectedRevision": 2,
                    "expectedDocumentRevision": 2,
                }
            ),
        )


def test_private_search_and_due_projection_are_bounded_and_confirmed_only():
    store = library()
    store.create(actor(), create_command())
    store.confirm_warranty(
        actor(),
        ConfirmWarrantyCommand(
            schemaVersion=1,
            coreId=CORE,
            homeId=HOME,
            requestId=CONFIRM,
            expectedAccountRevision=4,
            expectedRevision=1,
            documentId=DOCUMENT,
            expectedDocumentRevision=1,
            confirmedDate="2028-06-01",
        ),
    )

    reader_page = store.search(actor(READER, role="member"), "buzdolabı")
    assert [item.ref.id for item in reader_page.items] == [DOCUMENT]
    assert reader_page.authority.accountId == READER
    assert reader_page.authority.libraryRevision == 2
    exact = store.get(actor(READER, role="member"), DOCUMENT)
    assert exact.document.ref.id == DOCUMENT
    assert exact.authority.accountId == READER
    with pytest.raises(ApiError, match="not_found"):
        store.get(actor(STRANGER, role="member"), DOCUMENT)
    stranger_page = store.search(actor(STRANGER, role="member"), "fatura")
    assert stranger_page.items == []
    assert stranger_page.authority.libraryRevision == 0
    reminder = store.due(actor(READER, role="member"), today="2028-05-05")
    assert reminder.authority.accountId == READER
    assert len(reminder.items) == 1
    assert reminder.items[0].documentId == DOCUMENT
    assert reminder.items[0].remindOn == "2028-05-02"
    assert reminder.items[0].expiresOn == "2028-06-01"
    assert store.due(actor(STRANGER, role="member"), today="2028-05-05").items == []

    with pytest.raises(ApiError, match="invalid_request"):
        store.due(actor(READER, role="member"), today="2028-99-99")
    with pytest.raises(ApiError, match="invalid_request"):
        store.search(actor(READER, role="member"), "x" * 121)
