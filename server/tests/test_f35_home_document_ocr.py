"""F35 real bounded Tesseract/Poppler home-document OCR."""

import hashlib
from pathlib import Path
import uuid

import pytest
from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.home_documents.models import OcrWarrantyCandidate
from support.f35_ocr_fixture import executable, warranty_pdf
from test_bounded_blob_product_provider import paths, upload_headers


@pytest.fixture
def ocr_server(tmp_path):
    root = tmp_path.resolve()
    clock = Clock()
    settings = Settings(
        root / "data", root / "secrets/vault.key", clock=clock,
        login_ip_limit=100, login_account_limit=100, login_global_limit=100,
        home_document_tesseract=executable("LARENOR_TEST_TESSERACT", "tesseract"),
        home_document_pdftoppm=executable("LARENOR_TEST_PDFTOPPM", "pdftoppm"),
    )
    app = create_app(settings)
    with TestClient(app) as client:
        yield app, client, settings, clock


def _resource(app, client, admin):
    scope = app.state.core.context
    response = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=auth(admin),
        json={"kind": "resource", "label": "Private warranty PDF", "order": 0},
    )
    assert response.status_code == 201, response.text
    return response.json()["record"]


def _account_revision(client, admin):
    users = client.get("/api/v1/admin/users", headers=auth(admin)).json()["users"]
    return next(item["revision"] for item in users if item["id"] == admin["user"]["id"])


def _upload(app, client, admin, record, payload):
    upload, _descriptor, _download = paths(record)
    request_id = uuid.uuid4().hex
    response = client.put(
        upload + request_id,
        headers=upload_headers(
            app, admin, record, payload, request_id=request_id,
            content_type="application/pdf",
        ),
        content=payload,
    )
    assert response.status_code == 201, response.text
    return {"schemaVersion": 1, **{
        key: value for key, value in response.json()["blob"].items()
        if key != "requestId" and key not in {"createdAt", "updatedAt"}
    }}


class _Ocr:
    def __init__(self, callback=None):
        self.callback = callback

    def extract(self, blob, _content):
        if self.callback is not None:
            self.callback()
        return OcrWarrantyCandidate(
            schemaVersion=1, provider="tesseract",
            extractedDate="2028-06-01", confidencePermille=900,
            sourceRevision=blob.serviceRevision, sourceDigest=blob.sha256,
            sourceContentType=blob.contentType,
        )


def test_real_pdf_candidate_is_untrusted_and_requires_explicit_confirmation(ocr_server):
    app, client, _settings, _clock = ocr_server
    admin = ready(ocr_server)
    scope = app.state.core.context
    record = _resource(app, client, admin)
    payload = warranty_pdf()
    blob = _upload(app, client, admin, record, payload)
    root = f"/api/v1/home-documents/{scope.coreId}/{scope.homeId}"
    revision = _account_revision(client, admin)

    observed = client.post(root + "/ocr-candidates", headers=auth(admin), json={
        "schemaVersion": 1,
        "expectedAccountRevision": revision,
        "blob": blob,
    })
    assert observed.status_code == 200, observed.text
    candidate = observed.json()["candidate"]
    assert candidate == {
        "schemaVersion": 1,
        "provider": "tesseract",
        "extractedDate": "2028-06-01",
        "confidencePermille": candidate["confidencePermille"],
        "sourceRevision": blob["serviceRevision"],
        "sourceDigest": hashlib.sha256(payload).hexdigest(),
        "sourceContentType": "application/pdf",
    }
    assert 0 <= candidate["confidencePermille"] <= 1000

    item = client.post(
        f"/api/v1/inventory/{scope.coreId}/{scope.homeId}/items",
        headers=auth(admin),
        json={
            "schemaVersion": 1, "label": "Fridge", "roomId": None,
            "deviceId": None, "documentIds": [], "readerIds": [],
        },
    ).json()["item"]
    create_body = {
        "schemaVersion": 1, "coreId": scope.coreId, "homeId": scope.homeId,
        "requestId": uuid.uuid4().hex, "expectedAccountRevision": revision,
        "expectedRevision": 0, "documentId": uuid.uuid4().hex,
        "title": "Fridge warranty", "kind": "warranty",
        "inventoryItemId": item["ref"]["id"], "blob": blob,
        "readerIds": [], "ocrCandidate": candidate,
        "reminderLeadDays": [30, 7],
    }
    created = client.post(
        root + "/documents", headers=auth(admin), json=create_body
    )
    assert created.status_code == 201, created.text
    document = created.json()["document"]
    assert document["warranty"]["candidate"] == candidate
    assert document["warranty"]["confirmedDate"] is None
    reminders = client.get(
        root + "/reminders", headers=auth(admin),
        params={"today": "2028-05-05", "limit": 100},
    )
    assert reminders.json()["items"] == []

    confirmed = client.post(
        root + f"/documents/{document['ref']['id']}/warranty",
        headers=auth(admin),
        json={
            "schemaVersion": 1, "coreId": scope.coreId, "homeId": scope.homeId,
            "requestId": uuid.uuid4().hex,
            "expectedAccountRevision": revision, "expectedRevision": 1,
            "documentId": document["ref"]["id"],
            "expectedDocumentRevision": 1, "confirmedDate": "2028-06-01",
        },
    )
    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json()["document"]["warranty"]["confirmedBy"] == admin["user"]["id"]
    app.state.core.home_documents._ocr = None
    replay = client.post(
        root + "/documents", headers=auth(admin), json=create_body
    )
    assert replay.status_code == 201
    assert replay.json()["replayed"] is True


def test_no_warranty_label_never_becomes_candidate(ocr_server):
    app, client, _settings, _clock = ocr_server
    admin = ready(ocr_server)
    scope = app.state.core.context
    record = _resource(app, client, admin)
    blob = _upload(app, client, admin, record, warranty_pdf("PURCHASE 2028-06-01"))
    root = f"/api/v1/home-documents/{scope.coreId}/{scope.homeId}"
    revision = _account_revision(client, admin)
    response = client.post(root + "/ocr-candidates", headers=auth(admin), json={
        "schemaVersion": 1, "expectedAccountRevision": revision, "blob": blob,
    })
    assert response.status_code == 200
    assert response.json()["candidate"] is None


def test_session_revocation_during_ocr_discards_candidate(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    scope = app.state.core.context
    record = _resource(app, client, admin)
    blob = _upload(app, client, admin, record, warranty_pdf())
    revision = _account_revision(client, admin)

    def revoke():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE session_families SET revoked_at=? WHERE id=?",
                (app.state.core.settings.clock(), admin["sessionFamilyId"]),
            )

    app.state.core.home_documents._ocr = _Ocr(revoke)
    root = f"/api/v1/home-documents/{scope.coreId}/{scope.homeId}"
    response = client.post(root + "/ocr-candidates", headers=auth(admin), json={
        "schemaVersion": 1,
        "expectedAccountRevision": revision,
        "blob": blob,
    })
    assert response.status_code == 401


def test_client_changed_candidate_is_rejected_before_document_storage(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    scope = app.state.core.context
    record = _resource(app, client, admin)
    blob = _upload(app, client, admin, record, warranty_pdf())
    app.state.core.home_documents._ocr = _Ocr()
    revision = _account_revision(client, admin)
    root = f"/api/v1/home-documents/{scope.coreId}/{scope.homeId}"
    candidate = client.post(root + "/ocr-candidates", headers=auth(admin), json={
        "schemaVersion": 1, "expectedAccountRevision": revision, "blob": blob,
    }).json()["candidate"]
    item = client.post(
        f"/api/v1/inventory/{scope.coreId}/{scope.homeId}/items",
        headers=auth(admin),
        json={
            "schemaVersion": 1, "label": "Fridge", "roomId": None,
            "deviceId": None, "documentIds": [], "readerIds": [],
        },
    ).json()["item"]
    candidate["extractedDate"] = "2029-01-01"
    response = client.post(root + "/documents", headers=auth(admin), json={
        "schemaVersion": 1, "coreId": scope.coreId, "homeId": scope.homeId,
        "requestId": uuid.uuid4().hex, "expectedAccountRevision": revision,
        "expectedRevision": 0, "documentId": uuid.uuid4().hex,
        "title": "Forged warranty", "kind": "warranty",
        "inventoryItemId": item["ref"]["id"], "blob": blob,
        "readerIds": [], "ocrCandidate": candidate,
        "reminderLeadDays": [30],
    })
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "ocr_candidate_changed"
    assert client.get(root + "/documents", headers=auth(admin)).json()["items"] == []


def test_container_declares_real_ocr_runtime_and_configuration_is_paired(tmp_path):
    dockerfile = (Path(__file__).resolve().parents[2] / "server/Dockerfile").read_text()
    for required in (
        "poppler-utils", "tesseract-ocr", "/usr/bin/pdftoppm",
        "/usr/bin/tesseract", "LARENOR_HOME_DOCUMENT_TESSERACT=/usr/bin/tesseract",
        "LARENOR_HOME_DOCUMENT_PDFTOPPM=/usr/bin/pdftoppm",
        "/usr/bin/tesseract --list-langs | grep -Fx eng",
    ):
        assert required in dockerfile
    with pytest.raises(ValueError, match="invalid_home_document_ocr_configuration"):
        Settings(
            tmp_path / "data", tmp_path / "key",
            home_document_tesseract=Path("/usr/bin/tesseract"),
        )
