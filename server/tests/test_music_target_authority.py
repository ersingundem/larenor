"""Server-only authority for retained Music Assistant playback targets."""

from conftest import auth
from larenor_server.plugins.music_playback_models import VerifiedMusicPlayer
from test_admin import activate, create
from test_music_playback import discovered, player


BASE = "/api/v1/admin/media/music-assistant/target-authority"
RETAINED = "/api/v1/admin/media/music-assistant/retained"


def cast(identifier="cast-living", *, group=(), capabilities=None):
    return VerifiedMusicPlayer(
        playerId=identifier,
        name="Living Chromecast",
        provider="cast--main",
        targetKind="chromecast" if not group else "chromecast_group",
        available=True,
        enabled=True,
        playbackState="idle",
        volumeLevel=20,
        muted=False,
        groupMembers=list(group),
        queueId=identifier,
        capabilities=capabilities
        or [
            "play",
            "pause",
            "stop",
            "next_previous",
            "volume_set",
            "volume_mute",
            "queue",
        ],
    )


def retained_provider_revisions(server, pair):
    response = server[1].get(RETAINED, headers=auth(pair))
    assert response.status_code == 200, response.text
    installation = response.json()["installations"][0]
    return [
        {
            "id": item["id"],
            "providerDomain": item["providerDomain"],
            "revision": item["revision"],
        }
        for item in installation["providers"]
        if item["state"] == "ready"
    ]


def inventory_request(server, pair, setup, readiness, playback):
    return {
        "installationId": setup["installationId"],
        "expectedInstallationRevision": setup["installationRevision"],
        "expectedCoreRevision": readiness["revision"],
        "expectedPlayerRevision": playback["revision"],
        "expectedProviderRevisions": retained_provider_revisions(server, pair),
    }


def preview_request(server, pair, setup, readiness, playback, **changes):
    body = {
        **inventory_request(server, pair, setup, readiness, playback),
        "requestId": "6" * 32,
        "targetId": "homepod-living",
        "expectedProvider": "airplay--main",
        "expectedTransport": "airplay",
        "expectedKind": "device",
        "expectedQueueId": "homepod-living",
        "expectedGroupMemberIds": [],
        "operation": "volume",
        "volumeLevel": 45,
        "muted": None,
        "mediaUris": [],
    }
    return body | changes


def test_inventory_projects_exact_provider_player_queue_and_target_capabilities(server):
    pair, setup, readiness, worker, playback = discovered(
        server,
        [player(), cast(), cast("cast-whole", group=("cast-living",))],
    )
    expected_providers = retained_provider_revisions(server, pair)
    response = server[1].post(
        BASE + "/inventory",
        headers=auth(pair),
        json=inventory_request(server, pair, setup, readiness, playback),
    )
    assert response.status_code == 200, response.text
    inventory = response.json()["inventory"]
    assert inventory["providerRevisions"] == expected_providers
    assert inventory["installAvailable"] is False
    assert [
        (item["transport"], item["kind"], item["queueId"])
        for item in inventory["targets"]
    ] == [
        ("airplay", "device", "homepod-living"),
        ("chromecast", "device", "cast-living"),
        ("chromecast", "group", "cast-whole"),
    ]
    assert inventory["targets"][0]["playbackState"] == "paused"
    assert inventory["targets"][0]["homePod"] is True
    assert inventory["targets"][2]["groupMemberIds"] == ["cast-living"]
    assert "queue" in inventory["targets"][2]["capabilities"]
    assert worker.calls == []


def test_preview_confirm_is_one_use_idempotent_and_effect_unavailable(server):
    pair, setup, readiness, worker, playback = discovered(server)
    intent = preview_request(server, pair, setup, readiness, playback)
    first_preview = server[1].post(
        BASE + "/previews", headers=auth(pair), json=intent
    )
    second_preview = server[1].post(
        BASE + "/previews", headers=auth(pair), json=intent
    )
    assert first_preview.status_code == 201
    assert first_preview.json() == second_preview.json()
    preview = first_preview.json()["preview"]
    assert preview["effectAvailable"] is False
    assert preview["blockers"] == ["effect_unavailable"]
    confirm = {
        "requestId": "7" * 32,
        "previewId": preview["id"],
        "expectedPreviewRevision": 1,
        "planHash": preview["planHash"],
    }
    first = server[1].post(BASE + "/commands", headers=auth(pair), json=confirm)
    second = server[1].post(BASE + "/commands", headers=auth(pair), json=confirm)
    replay = server[1].post(
        BASE + "/commands",
        headers=auth(pair),
        json=confirm | {"requestId": "8" * 32},
    )
    assert first.status_code == 201 and first.json() == second.json()
    assert replay.status_code == 409
    command = first.json()["command"]
    assert command["state"] == "blocked"
    assert command["errorCode"] == "effect_unavailable"
    assert command["result"] is None
    assert command["target"]["queueId"] == "homepod-living"
    assert worker.calls == []


def test_provider_revision_change_after_preview_fails_closed(server):
    app, client, _, _ = server
    pair, setup, readiness, worker, playback = discovered(server)
    intent = preview_request(server, pair, setup, readiness, playback)
    preview = client.post(
        BASE + "/previews", headers=auth(pair), json=intent
    ).json()["preview"]
    with app.state.core.db.transaction() as connection:
        row = connection.execute(
            "SELECT * FROM music_provider_setups WHERE installation_id=?",
            (setup["installationId"],),
        ).fetchone()
        stored = app.state.core.music_provider_setups._decode(row)
        changed = dict(row)
        changed["revision"] += 1
        app.state.core.music_provider_setups._save(connection, changed, stored)
    stale = client.post(
        BASE + "/commands",
        headers=auth(pair),
        json={
            "requestId": "9" * 32,
            "previewId": preview["id"],
            "expectedPreviewRevision": 1,
            "planHash": preview["planHash"],
        },
    )
    assert stale.status_code == 409


def test_target_queue_and_capability_changes_fail_closed(server):
    _app, client, _, _ = server

    pair, setup, readiness, worker, playback = discovered(
        server, [cast(capabilities=["play"])]
    )
    unsupported = preview_request(
        server,
        pair,
        setup,
        readiness,
        playback,
        requestId="a" * 32,
        targetId="cast-living",
        expectedProvider="cast--main",
        expectedTransport="chromecast",
        expectedQueueId="cast-living",
        operation="queue_clear",
        volumeLevel=None,
    )
    denied = client.post(BASE + "/previews", headers=auth(pair), json=unsupported)
    assert denied.status_code == 409
    assert denied.json()["error"]["code"] == "music_player_capability_unavailable"
    changed_queue = client.post(
        BASE + "/previews",
        headers=auth(pair),
        json=unsupported
        | {
            "requestId": "b" * 32,
            "operation": "play",
            "expectedQueueId": "other-queue",
        },
    )
    assert changed_queue.status_code == 409
    assert worker.calls == []


def test_authority_is_admin_session_bound_and_settings_pin_is_not_authority(server):
    _app, client, _, _ = server
    pair, setup, readiness, worker, playback = discovered(server)
    body = inventory_request(server, pair, setup, readiness, playback)
    create(client, pair, "music-target-member")
    member = activate(client, "music-target-member")
    for headers, status in (
        ({}, 401),
        ({"X-Larenor-Settings-PIN": "1234"}, 401),
        (auth(member) | {"X-Larenor-Settings-PIN": "1234"}, 403),
    ):
        response = client.post(BASE + "/inventory", headers=headers, json=body)
        assert response.status_code == status
    assert client.post("/api/v1/auth/logout", headers=auth(pair)).status_code == 204
    assert (
        client.post(BASE + "/inventory", headers=auth(pair), json=body).status_code
        == 401
    )
    assert worker.calls == []


def test_secret_fields_and_missing_provider_revision_are_rejected_without_receipt(server):
    pair, setup, readiness, worker, playback = discovered(server)
    base = preview_request(server, pair, setup, readiness, playback)
    for changed in (
        {key: value for key, value in base.items() if key != "expectedProviderRevisions"},
        base | {"cookie": "private-cookie"},
    ):
        response = server[1].post(
            BASE + "/previews", headers=auth(pair), json=changed
        )
        assert response.status_code == 400
        assert "private-cookie" not in response.text
    assert worker.calls == []
