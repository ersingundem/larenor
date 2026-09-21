from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app


def _account_revision(client, admin):
    users = client.get("/api/v1/admin/users", headers=auth(admin)).json()["users"]
    return next(row["revision"] for row in users if row["id"] == admin["user"]["id"])


def _body(app, client, admin):
    context = app.state.core.context
    return {
        "schemaVersion": 1,
        "coreId": context.coreId,
        "homeId": context.homeId,
        "requestId": "a" * 32,
        "expectedAccountRevision": _account_revision(client, admin),
        "expectedRevision": 0,
        "documentId": "b" * 32,
        "title": "Buzdolabı faturası",
        "kind": "invoice",
        "inventoryItemId": "c" * 32,
        "blob": {
            "schemaVersion": 1,
            "resourceId": "d" * 32,
            "serviceRevision": 3,
            "contentLength": 1024,
            "sha256": "e" * 64,
            "contentType": "application/pdf",
        },
        "readerIds": [],
        "ocrCandidate": None,
        "reminderLeadDays": [30, 7],
    }


def _allow_synthetic_references(core):
    core.home_documents._blob_current = lambda _actor, _blob: True
    core.home_documents._inventory_current = lambda _actor, _item: True


def test_http_registration_and_encrypted_state_survive_core_restart(server):
    app, client, settings, _clock = server
    admin = ready(server)
    _allow_synthetic_references(app.state.core)
    body = _body(app, client, admin)
    context = app.state.core.context
    root = f"/api/v1/home-documents/{context.coreId}/{context.homeId}"

    created = client.post(f"{root}/documents", headers=auth(admin), json=body)
    assert created.status_code == 201, created.text
    assert created.json()["authority"]["libraryRevision"] == 1
    assert created.json()["document"]["title"] == "Buzdolabı faturası"
    with app.state.core.db.connection() as connection:
        stored = connection.execute(
            "SELECT nonce,ciphertext FROM home_document_state WHERE singleton=1"
        ).fetchone()
    assert len(stored["nonce"]) == 12
    assert "Buzdolabı".encode() not in stored["ciphertext"]

    listed = client.get(
        f"{root}/documents",
        headers=auth(admin),
        params={"query": "Buzdolabı", "limit": 50},
    )
    assert listed.status_code == 200
    assert [row["ref"]["id"] for row in listed.json()["items"]] == ["b" * 32]

    with TestClient(create_app(settings)) as restarted:
        durable = restarted.get(
            f"{root}/documents", headers=auth(admin), params={"query": "", "limit": 50}
        )
        assert durable.status_code == 200, durable.text
        assert (
            durable.json()
            == client.get(
                f"{root}/documents",
                headers=auth(admin),
                params={"query": "", "limit": 50},
            ).json()
        )
        replay = restarted.post(f"{root}/documents", headers=auth(admin), json=body)
        assert replay.status_code == 201
        assert replay.json()["replayed"] is True


def test_http_scope_revision_and_session_authority_fail_closed(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    _allow_synthetic_references(app.state.core)
    body = _body(app, client, admin)
    context = app.state.core.context
    root = f"/api/v1/home-documents/{context.coreId}/{context.homeId}"

    foreign = client.post(
        f"/api/v1/home-documents/{'f' * 32}/{context.homeId}/documents",
        headers=auth(admin),
        json={**body, "coreId": "f" * 32},
    )
    assert foreign.status_code == 404

    stale = client.post(
        f"{root}/documents",
        headers=auth(admin),
        json={**body, "expectedAccountRevision": body["expectedAccountRevision"] + 1},
    )
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "revision_conflict"

    malformed = client.get(
        f"{root}/documents", headers=auth(admin), params={"query": "x\n", "limit": 50}
    )
    assert malformed.status_code == 400
