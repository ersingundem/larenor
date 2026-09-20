"""F34 first slice: durable, scoped and non-authorizing QR inventory identity."""

import json

from fastapi.testclient import TestClient

from larenor_server.app import create_app

from conftest import auth, ready
from test_admin import activate, create as create_user


def scope(app):
    return app.state.core.context.model_dump()


def root(app):
    value = scope(app)
    return f'/api/v1/inventory/{value["coreId"]}/{value["homeId"]}'


def body(*, readers=()):
    return {
        "schemaVersion": 1,
        "label": "Kahve değirmeni",
        "roomId": "2" * 32,
        "deviceId": "3" * 32,
        "documentIds": ["4" * 32, "5" * 32],
        "readerIds": list(readers),
    }


def create_item(app, client, admin, *, readers=()):
    response = client.post(root(app) + "/items", headers=auth(admin), json=body(readers=readers))
    assert response.status_code == 201, response.text
    return response.json()


def test_stable_item_and_secret_free_qr_survive_restart_encrypted(server):
    app, client, settings, _clock = server
    admin = ready(server)
    created = create_item(app, client, admin)
    item, qr = created["item"], created["qr"]
    identity = item["ref"]["id"]
    expected_qr = (
        f'larenor:inventory:v1:{scope(app)["coreId"]}:'
        f'{scope(app)["homeId"]}:{identity}'
    )
    assert set(created) == {"item", "qr"}
    assert qr == {"schemaVersion": 1, "format": "larenor_inventory_v1", "value": expected_qr}
    assert item == {
        "schemaVersion": 1,
        "ref": {**scope(app), "kind": "inventory_item", "id": identity},
        "revision": 1,
        "label": "Kahve değirmeni",
        "links": {
            "schemaVersion": 1,
            "roomId": "2" * 32,
            "deviceId": "3" * 32,
            "documentIds": ["4" * 32, "5" * 32],
        },
    }
    assert all(secret not in qr["value"] for secret in (item["label"], "4" * 32, admin["accessToken"]))
    with app.state.core.db.connection() as connection:
        row = connection.execute(
            "SELECT nonce,ciphertext FROM inventory_items WHERE id=?", (identity,)
        ).fetchone()
        assert len(row["nonce"]) == 12 and b"Kahve" not in row["ciphertext"]

    with TestClient(create_app(settings)) as restarted:
        fetched = restarted.get(root(app) + f"/items/{identity}", headers=auth(admin))
        assert fetched.status_code == 200
        assert fetched.json()["item"] == item


def test_closed_versioned_link_contract_rejects_duplicates_extras_and_bounds(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    invalid = []
    invalid.append(body() | {"schemaVersion": 2})
    invalid.append(body() | {"extra": "private"})
    invalid.append(body() | {"documentIds": ["4" * 32, "4" * 32]})
    invalid.append(body() | {"documentIds": [f"{value:032x}" for value in range(17)]})
    invalid.append(body() | {"roomId": "INVALID"})
    invalid.append(body() | {"readerIds": ["6" * 32, "6" * 32]})
    for value in invalid:
        response = client.post(root(app) + "/items", headers=auth(admin), json=value)
        assert response.status_code == 400, response.text
        assert response.json()["error"]["code"] == "invalid_request"
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM inventory_items").fetchone()[0] == 0


def test_qr_resolution_hides_foreign_or_unauthorized_items_and_dispatches_nothing(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    allowed_user = create_user(client, admin, "inventory.reader")
    allowed = activate(client, "inventory.reader")
    create_user(client, admin, "inventory.denied")
    denied = activate(client, "inventory.denied")
    created = create_item(app, client, admin, readers=[allowed_user["id"]])
    item, qr = created["item"], created["qr"]
    path = root(app) + "/items/" + item["ref"]["id"]
    resolve = root(app) + "/qr/resolve"

    assert client.get(path, headers=auth(allowed)).json()["item"] == item
    assert client.post(resolve, headers=auth(allowed), json=qr).json()["item"] == item
    assert client.get(path, headers=auth(denied)).status_code == 404
    assert client.post(resolve, headers=auth(denied), json=qr).status_code == 404
    assert client.post(resolve, json=qr).status_code == 401

    foreign = dict(qr)
    foreign["value"] = foreign["value"].replace(scope(app)["homeId"], "a" * 32)
    assert client.post(resolve, headers=auth(allowed), json=foreign).status_code == 404
    for malformed in ("broken", qr["value"] + ":extra", qr["value"].upper()):
        response = client.post(resolve, headers=auth(allowed), json={**qr, "value": malformed})
        assert response.status_code == 400
    assert client.patch(path, headers=auth(admin), json={}).status_code == 405
    assert client.delete(path, headers=auth(admin)).status_code == 405
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM home_assistant_commands").fetchone()[0] == 0
    assert "Kahve" not in json.dumps(qr, ensure_ascii=False)
