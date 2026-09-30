"""Focused restart/session-family regression for F21 watch-party authority."""

from conftest import auth, login
from test_media_archive_core_read import configured
from test_media_playback import _request


BASE = "/api/v1/media/watch-parties"
PASSWORD = "Synthetic new password 2026"


def test_leader_rejoin_rebinds_exact_session_family_before_next_command(server):
    _app, client, _settings, clock = server
    original, installation, current, _reader, _worker, _body = configured(server)
    created = client.post(BASE, headers=auth(original), json={
        **_request(installation, current, request_id="1" * 32),
        "schemaVersion": 1,
        "expiresAt": int(clock.now) + 3600,
        "toleranceMs": 750,
    })
    assert created.status_code == 201, created.text
    room = created.json()["snapshot"]
    invite = created.json()["inviteCode"]

    restarted_family = login(
        client, "admin", PASSWORD, device="Restarted F21 client"
    ).json()
    rejoined = client.post(
        f"{BASE}/{room['authority']['roomId']}/join",
        headers=auth(restarted_family),
        json={
            "schemaVersion": 1,
            "requestId": "2" * 32,
            "inviteCode": invite,
            "expectedRoomRevision": room["revision"],
        },
    )
    assert rejoined.status_code == 200, rejoined.text
    snapshot = rejoined.json()["snapshot"]
    leader = next(
        value for value in snapshot["participants"]
        if value["accountId"] == restarted_family["user"]["id"]
    )
    command = {
        "schemaVersion": 1,
        "requestId": "3" * 32,
        "expectedRoomRevision": snapshot["revision"],
        "expectedLeaderRevision": leader["revision"],
        "action": "play",
        "positionMs": 1000,
    }

    accepted = client.post(
        f"{BASE}/{room['authority']['roomId']}/commands",
        headers=auth(restarted_family), json=command,
    )
    assert accepted.status_code == 200, accepted.text

    # The previous family is still an authenticated account session but is no
    # longer the selected leader authority after the explicit rejoin.
    stale = client.post(
        f"{BASE}/{room['authority']['roomId']}/commands",
        headers=auth(original), json={
            **command,
            "requestId": "4" * 32,
            "expectedRoomRevision": accepted.json()["snapshot"]["revision"],
        },
    )
    assert stale.status_code == 404

