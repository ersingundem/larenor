from conftest import auth, login, ready


def _scope(client, pair):
    context = client.get("/api/v1/context", headers=auth(pair)).json()
    root = f"/api/v1/resource-reservations/{context['coreId']}/{context['homeId']}"
    response = client.get(root + "/authority", headers=auth(pair))
    assert response.status_code == 200
    value = response.json()
    assert set(value) == {"schemaVersion", "authority", "calendarRevision", "resource"}
    resource_root = root + "/" + value["resource"]["id"]
    return resource_root, value


def _authority(value, revision=None):
    return {
        "schemaVersion": 1,
        **value["authority"],
        "expectedCalendarRevision": value["calendarRevision"] if revision is None else revision,
    }


def test_authenticated_route_creates_reads_and_exports_bounded_state(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    root, bootstrap = _scope(client, pair)
    empty = client.post(root + "/snapshot", headers=auth(pair), json=_authority(bootstrap))
    assert empty.status_code == 200
    assert empty.json()["reservations"] == []

    command_id = "10" * 16
    create = client.post(root + "/commands/create", headers=auth(pair), json={
        **_authority(bootstrap),
        "commandId": command_id,
        "timezone": "UTC",
        "localStart": "2026-11-01T10:00:00",
        "fold": 0,
        "durationSeconds": 3600,
        "units": 1,
        "recurrence": {"frequency": "none", "count": 1},
    })
    assert create.status_code == 200
    receipt = create.json()
    assert receipt["commandId"] == command_id
    assert receipt["expectedCalendarRevision"] == 1
    assert receipt["calendarRevision"] == 2
    assert receipt["reservation"]["localStart"] == "2026-11-01T10:00:00"

    current = dict(bootstrap, calendarRevision=2)
    snapshot = client.post(root + "/snapshot", headers=auth(pair), json=_authority(current))
    assert snapshot.status_code == 200
    assert [item["id"] for item in snapshot.json()["reservations"]] == [
        receipt["reservation"]["id"]
    ]
    exported = client.post(root + "/export", headers=auth(pair), json={
        **_authority(current), "limit": 1,
    })
    assert exported.status_code == 200
    assert len(exported.json()["reservations"]) == 1
    assert "commandId" not in str(exported.json())


def test_lost_ack_receipt_is_read_once_without_replaying_the_command(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    root, bootstrap = _scope(client, pair)
    command_id = "20" * 16
    command = {
        **_authority(bootstrap),
        "commandId": command_id,
        "timezone": "UTC",
        "localStart": "2026-11-02T10:00:00",
        "fold": 0,
        "durationSeconds": 3600,
        "units": 1,
        "recurrence": {"frequency": "none", "count": 1},
    }
    assert client.post(root + "/commands/create", headers=auth(pair), json=command).status_code == 200

    # The client still owns revision 1 because the write acknowledgement was lost.
    first = client.post(
        root + "/receipts/" + command_id,
        headers=auth(pair),
        json=_authority(bootstrap),
    )
    second = client.post(
        root + "/receipts/" + command_id,
        headers=auth(pair),
        json=_authority(bootstrap),
    )
    assert first.status_code == second.status_code == 200
    assert first.json() == second.json()
    assert first.json()["calendarRevision"] == 2
    stale_replay = client.post(root + "/commands/create", headers=auth(pair), json=command)
    assert stale_replay.status_code == 409


def test_route_rejects_wrong_scope_stale_revision_and_unbounded_reads(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    root, bootstrap = _scope(client, pair)
    wrong = root.rsplit("/", 1)[0] + "/" + ("ff" * 16)
    assert client.post(wrong + "/snapshot", headers=auth(pair), json=_authority(bootstrap)).status_code == 404
    stale = _authority(bootstrap)
    stale["accountRevision"] += 1
    response = client.post(root + "/snapshot", headers=auth(pair), json=stale)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "authority_changed"
    assert client.post(root + "/export", headers=auth(pair), json={
        **_authority(bootstrap), "limit": 257,
    }).status_code == 400
    assert client.get(root + "/../authority").status_code in {401, 404}


def test_admin_manages_multiple_resources_with_exact_idempotent_revisions(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    context = client.get("/api/v1/context", headers=auth(pair)).json()
    root = f"/api/v1/resource-reservations/{context['coreId']}/{context['homeId']}/resources"
    initial = client.get(root, headers=auth(pair)).json()
    assert initial["catalogRevision"] == 1
    assert initial["canManage"] is True
    assert len(initial["resources"]) == 1

    command = {
        "schemaVersion": 1, "commandId": "30" * 16,
        "expectedCatalogRevision": 1, "label": "Guest room",
        "timezone": "Europe/Istanbul", "capacity": 2,
    }
    created = client.post(root + "/commands/create", headers=auth(pair), json=command)
    replay = client.post(root + "/commands/create", headers=auth(pair), json=command)
    assert created.status_code == replay.status_code == 200
    assert created.json() == replay.json()
    item = created.json()["resource"]
    assert created.json()["catalogRevision"] == 2
    assert item == {"id": item["id"], "revision": 1, "label": "Guest room",
                    "timezone": "Europe/Istanbul", "capacity": 2, "active": True}
    conflict = client.post(root + "/commands/create", headers=auth(pair), json={
        **command, "label": "Changed",
    })
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency_conflict"

    update = {
        "schemaVersion": 1, "commandId": "31" * 16,
        "expectedCatalogRevision": 2, "expectedResourceRevision": 1,
        "label": "Guest suite", "timezone": "Europe/Berlin", "capacity": 3,
    }
    changed = client.post(
        f"{root}/{item['id']}/commands/update", headers=auth(pair), json=update,
    )
    assert changed.status_code == 200
    assert changed.json()["catalogRevision"] == 3
    assert changed.json()["resource"]["revision"] == 2
    assert changed.json()["resource"]["timezone"] == "Europe/Berlin"
    selected = client.get(
        root.rsplit("/resources", 1)[0] + f"/{item['id']}/authority",
        headers=auth(pair),
    )
    assert selected.status_code == 200
    assert selected.json()["resource"] == changed.json()["resource"]

    disabled = client.post(
        f"{root}/{item['id']}/commands/deactivate", headers=auth(pair), json={
            "schemaVersion": 1, "commandId": "32" * 16,
            "expectedCatalogRevision": 3, "expectedResourceRevision": 2,
        },
    )
    assert disabled.status_code == 200
    assert disabled.json()["resource"]["active"] is False
    assert len(client.get(root, headers=auth(pair)).json()["resources"]) == 2


def test_catalog_role_dst_and_tamper_boundaries_fail_closed(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    context = client.get("/api/v1/context", headers=auth(admin)).json()
    root = f"/api/v1/resource-reservations/{context['coreId']}/{context['homeId']}/resources"
    created_user = client.post("/api/v1/admin/users", headers=auth(admin), json={
        "username": "calendar.member", "role": "member",
        "initialPassword": "Synthetic temporary password 2026",
    }).json()["user"]
    temporary = login(client, "calendar.member", "Synthetic temporary password 2026").json()
    member = client.post("/api/v1/auth/password", headers=auth(temporary), json={
        "currentPassword": "Synthetic temporary password 2026",
        "newPassword": "Synthetic member password 2026",
    }).json()
    listing = client.get(root, headers=auth(member))
    assert listing.status_code == 200 and listing.json()["canManage"] is False
    denied = client.post(root + "/commands/create", headers=auth(member), json={
        "schemaVersion": 1, "commandId": "40" * 16,
        "expectedCatalogRevision": 1, "label": "Denied",
        "timezone": "UTC", "capacity": 1,
    })
    assert denied.status_code == 403
    invalid_dst = client.post(root + "/commands/create", headers=auth(admin), json={
        "schemaVersion": 1, "commandId": "41" * 16,
        "expectedCatalogRevision": 1, "label": "Invalid zone",
        "timezone": "Europe/Imaginary", "capacity": 1,
    })
    assert invalid_dst.status_code == 400
    assert created_user["id"] == member["user"]["id"]

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE resource_reservation_catalog SET label='tampered' WHERE core_id=? AND home_id=?",
            (context["coreId"], context["homeId"]),
        )
    tampered = client.get(root, headers=auth(admin))
    assert tampered.status_code == 503
    assert tampered.json()["error"]["code"] == "server_unavailable"
