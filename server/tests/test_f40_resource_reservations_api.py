from conftest import auth, ready


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
