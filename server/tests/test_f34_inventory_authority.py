"""F34 second slice: resolved links, revisioned grants and immutable history."""

import hashlib
import uuid

import pytest
from fastapi.testclient import TestClient

from conftest import auth, login, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_admin import activate, create as create_user
from test_bounded_blob_product_provider import paths, upload_headers


def scope(app):
    return app.state.core.context.model_dump()


def root(app):
    value = scope(app)
    return f'/api/v1/inventory/{value["coreId"]}/{value["homeId"]}'


def home_record(app, client, admin, kind, label):
    value = scope(app)
    response = client.post(
        f'/api/v1/admin/home-resources/{value["coreId"]}/{value["homeId"]}',
        headers=auth(admin), json={"kind": kind, "label": label, "order": 0},
    )
    assert response.status_code == 201, response.text
    return response.json()["record"]


def document(app, client, admin):
    record = home_record(app, client, admin, "resource", "Garanti belgesi")
    payload = b"verified warranty document"
    upload, _descriptor, _download = paths(record)
    request_id = uuid.uuid4().hex
    response = client.put(
        upload + request_id,
        headers=upload_headers(app, admin, record, payload, request_id=request_id),
        content=payload,
    )
    assert response.status_code == 201, response.text
    return record


def item_body(room, device, document_id, *, readers=()):
    return {"schemaVersion": 1, "label": "Kahve değirmeni",
            "roomId": room["ref"]["id"], "deviceId": device["ref"]["id"],
            "documentIds": [document_id], "readerIds": list(readers)}


def create_inventory(app, client, admin, body):
    response = client.post(root(app) + "/items", headers=auth(admin), json=body)
    assert response.status_code == 201, response.text
    return response.json()["item"]


def resolved_fixture(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    room = home_record(app, client, admin, "room", "Mutfak")
    device = home_record(app, client, admin, "resource", "Değirmen")
    doc = document(app, client, admin)
    return app, client, admin, room, device, doc


def test_links_resolve_to_exact_current_home_types_and_persisted_document(server):
    app, client, admin, room, device, doc = resolved_fixture(server)
    valid = item_body(room, device, doc["ref"]["id"])
    created = client.post(root(app) + "/items", headers=auth(admin), json=valid)
    assert created.status_code == 201

    invalid = [
        valid | {"roomId": device["ref"]["id"]},
        valid | {"deviceId": room["ref"]["id"]},
        valid | {"documentIds": ["f" * 32]},
    ]
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE bounded_blob_objects SET home_id=? WHERE resource_id=?",
            ("e" * 32, doc["ref"]["id"]),
        )
    invalid.append(valid)
    for body in invalid:
        response = client.post(root(app) + "/items", headers=auth(admin), json=body)
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "invalid_request"
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM inventory_items").fetchone()[0] == 1

    value = scope(app)
    removed = client.delete(
        f'/api/v1/admin/home-resources/{value["coreId"]}/{value["homeId"]}/{room["ref"]["id"]}',
        headers=auth(admin), params={"expectedRevision": 1, "expectedAclRevision": 1})
    assert removed.status_code == 204
    item_id = created.json()["item"]["ref"]["id"]
    assert client.get(root(app) + "/items/" + item_id, headers=auth(admin)).status_code == 404


def test_reference_resolver_rejects_cryptographically_invalid_registry_and_blob_rows(server):
    app, client, admin, room, device, doc = resolved_fixture(server)
    minimal = item_body(room, device, doc["ref"]["id"]) | {
        "deviceId": None, "documentIds": []}
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE home_resource_records SET kind='room' WHERE id=?",
            (device["ref"]["id"],),
        )
    forged = minimal | {"roomId": device["ref"]["id"]}
    assert client.post(root(app) + "/items", headers=auth(admin), json=forged).status_code == 503

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE home_resource_records SET kind='resource' WHERE id=?",
            (device["ref"]["id"],),
        )
        connection.execute(
            "UPDATE bounded_blob_objects SET authentication_tag=? WHERE resource_id=?",
            ("0" * 64, doc["ref"]["id"]),
        )
    forged = minimal | {"roomId": room["ref"]["id"],
                        "documentIds": [doc["ref"]["id"]]}
    assert client.post(root(app) + "/items", headers=auth(admin), json=forged).status_code == 503


def test_admin_grants_and_updates_are_closed_revision_controlled_and_revocable(server):
    app, client, admin, room, device, doc = resolved_fixture(server)
    created_user = create_user(client, admin, "inventory.member")
    member = activate(client, "inventory.member")
    item = create_inventory(app, client, admin,
        item_body(room, device, doc["ref"]["id"]))
    base = root(app) + "/items/" + item["ref"]["id"]
    grant = base + "/grants/" + created_user["id"]

    added = client.put(grant, headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 1})
    assert added.status_code == 200 and added.json()["item"]["revision"] == 2
    listed = client.get(base + "/grants", headers=auth(admin))
    assert listed.json() == {"schemaVersion": 1, "itemRevision": 2,
                            "grants": [{"schemaVersion": 1, "subjectId": created_user["id"]}]}
    assert client.get(base + "/grants", headers=auth(member)).status_code == 403
    stale = client.put(grant, headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 1})
    assert stale.status_code == 409

    updated = client.patch(base, headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 2, "label": "Sessiz değirmen",
        "roomId": room["ref"]["id"], "deviceId": device["ref"]["id"],
        "documentIds": [doc["ref"]["id"]],
    })
    assert updated.status_code == 200 and updated.json()["item"]["revision"] == 3
    assert client.get(base, headers=auth(member)).status_code == 200
    revoked = client.request("DELETE", grant, headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 3})
    assert revoked.status_code == 204
    assert client.get(base, headers=auth(member)).status_code == 404
    history = client.get(base + "/history", headers=auth(admin))
    assert history.status_code == 200
    assert [entry["action"] for entry in history.json()["entries"]] == [
        "create", "grant", "update", "revoke"]


def test_history_is_authorized_restart_stable_and_detects_chain_or_state_tamper(server):
    app, client, settings, _clock = server
    admin = ready(server)
    room = home_record(app, client, admin, "room", "Mutfak")
    device = home_record(app, client, admin, "resource", "Değirmen")
    doc = document(app, client, admin)
    denied_user = create_user(client, admin, "inventory.denied")
    denied = activate(client, "inventory.denied")
    item = create_inventory(app, client, admin, item_body(room, device, doc["ref"]["id"]))
    base = root(app) + "/items/" + item["ref"]["id"]
    client.patch(base, headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 1, "label": "Yeni etiket",
        "roomId": room["ref"]["id"], "deviceId": device["ref"]["id"],
        "documentIds": [doc["ref"]["id"]]})
    history = client.get(base + "/history", headers=auth(admin))
    assert history.status_code == 200
    assert history.json()["verified"] is True
    assert [entry["action"] for entry in history.json()["entries"]] == ["create", "update"]
    assert client.get(base + "/history", headers=auth(denied)).status_code == 404

    with TestClient(create_app(settings)) as restarted:
        current = login(restarted, "admin", "Synthetic new password 2026").json()
        again = restarted.get(base + "/history", headers=auth(current))
        assert again.status_code == 200 and again.json() == history.json()

    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE inventory_audit SET entry_hash=? WHERE sequence=1", ("0" * 64,))
    assert client.get(base, headers=auth(admin)).status_code == 503
    with pytest.raises(StartupError, match="inventory_storage_invalid"):
        with TestClient(create_app(settings)):
            pass
