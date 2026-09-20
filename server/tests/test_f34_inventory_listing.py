"""F34 inventory listing: scoped keyset pages and authenticated cursors."""

from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from test_admin import activate, create as create_user
from test_f34_inventory_foundation import body, root


def _create(app, client, admin, label, *, readers=()):
    response = client.post(
        root(app) + "/items",
        headers=auth(admin),
        json=body(readers=readers) | {"label": label},
    )
    assert response.status_code == 201, response.text
    return response.json()["item"]


def test_admin_pages_every_item_once_in_stable_identity_order(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    created = [_create(app, client, admin, label) for label in ("C", "A", "B")]

    first = client.get(root(app) + "/items", headers=auth(admin), params={"limit": 2})
    assert first.status_code == 200, first.text
    first_page = first.json()
    assert set(first_page) == {"schemaVersion", "verified", "items", "nextCursor"}
    assert first_page["schemaVersion"] == 1 and first_page["verified"] is True
    assert len(first_page["items"]) == 2
    assert isinstance(first_page["nextCursor"], str)
    assert 1 <= len(first_page["nextCursor"]) <= 512

    second = client.get(
        root(app) + "/items",
        headers=auth(admin),
        params={"limit": 2, "cursor": first_page["nextCursor"]},
    )
    assert second.status_code == 200, second.text
    second_page = second.json()
    assert len(second_page["items"]) == 1 and second_page["nextCursor"] is None
    listed = first_page["items"] + second_page["items"]
    assert [item["ref"]["id"] for item in listed] == sorted(
        item["ref"]["id"] for item in created
    )


def test_pages_hide_ungranted_items_and_cursor_is_actor_bound(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    reader_record = create_user(client, admin, "inventory.page.reader")
    reader = activate(client, "inventory.page.reader")
    allowed = _create(
        app,
        client,
        admin,
        "Allowed",
        readers=[reader_record["id"]],
    )
    _create(app, client, admin, "Private")

    page = client.get(root(app) + "/items", headers=auth(reader), params={"limit": 1})
    assert page.status_code == 200, page.text
    assert page.json()["items"] == [allowed]
    assert page.json()["nextCursor"] is None

    admin_page = client.get(root(app) + "/items", headers=auth(admin), params={"limit": 1})
    cursor = admin_page.json()["nextCursor"]
    replay = client.get(
        root(app) + "/items",
        headers=auth(reader),
        params={"limit": 1, "cursor": cursor},
    )
    assert replay.status_code == 400
    assert replay.json()["error"]["code"] == "invalid_request"


def test_cursor_survives_restart_but_tamper_and_invalid_bounds_fail_closed(server):
    app, client, settings, _clock = server
    admin = ready(server)
    for label in ("One", "Two", "Three"):
        _create(app, client, admin, label)
    first = client.get(root(app) + "/items", headers=auth(admin), params={"limit": 1})
    cursor = first.json()["nextCursor"]

    with TestClient(create_app(settings)) as restarted:
        from conftest import login

        current = login(restarted, "admin", "Synthetic new password 2026").json()
        page = restarted.get(
            root(app) + "/items",
            headers=auth(current),
            params={"limit": 1, "cursor": cursor},
        )
        assert page.status_code == 200, page.text

    replacement = "A" if cursor[-1] != "A" else "B"
    tampered = cursor[:-1] + replacement
    response = client.get(
        root(app) + "/items",
        headers=auth(admin),
        params={"limit": 1, "cursor": tampered},
    )
    assert response.status_code == 400
    for invalid in (0, 101):
        assert client.get(
            root(app) + "/items", headers=auth(admin), params={"limit": invalid}
        ).status_code == 400
