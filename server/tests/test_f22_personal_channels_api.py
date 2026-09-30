from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import ApiError
from larenor_server.plugins.media_playback_models import PrivateMediaPlaybackAuthority


INSTALLATION = "1" * 32
FIRST_ITEM = "2" * 32
SECOND_ITEM = "3" * 32
CREATE = "4" * 32
RESCHEDULE = "5" * 32
CANCEL = "6" * 32


def _authority(item_id, media_key):
    return PrivateMediaPlaybackAuthority(
        installationId=INSTALLATION,
        installationRevision=2,
        snapshotRevision=3,
        jellyfinServiceRevision=4,
        itemId=item_id,
        mediaKey=media_key,
    )


def _source(item_id, media_key, title):
    return {
        "schemaVersion": 1,
        "installationId": INSTALLATION,
        "expectedInstallationRevision": 2,
        "expectedSnapshotRevision": 3,
        "expectedJellyfinServiceRevision": 4,
        "itemId": item_id,
        "mediaKey": media_key,
        "title": title,
        "durationSeconds": 600,
    }


def _bind_catalog(app, available):
    def catalog(_actor, request):
        authority = available.get(request.itemId)
        if authority is None:
            raise ApiError("media_playback_item_changed", 409)
        assert request.installationId == authority.installationId
        assert request.expectedInstallationRevision == authority.installationRevision
        assert request.expectedSnapshotRevision == authority.snapshotRevision
        assert request.expectedJellyfinServiceRevision == authority.jellyfinServiceRevision
        assert request.mediaKey == authority.mediaKey
        return authority

    app.state.core.media_playback._catalog = catalog


def test_create_guide_live_restart_gap_reschedule_cancel_survives_core_restart(server):
    app, client, settings, clock = server
    pair = ready(server)
    root = "/api/v1/media/personal-channels"
    first = _authority(FIRST_ITEM, "movie:tmdb:603")
    second = _authority(SECOND_ITEM, "movie:tmdb:604")
    available = {FIRST_ITEM: first}
    _bind_catalog(app, available)

    created = client.post(
        root,
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": CREATE,
            "name": "Family cinema",
            "startsAt": int(clock.now) - 300,
            "loop": True,
            "sources": [_source(FIRST_ITEM, first.mediaKey, "The Matrix")],
        },
    )
    assert created.status_code == 201, created.text
    channel = created.json()["channel"]
    channel_id = channel["channelId"]
    programme = next(
        value
        for value in channel["programmes"]
        if value["occurrenceStartsAt"] <= clock.now < value["occurrenceEndsAt"]
    )
    playback_body = {
        "schemaVersion": 1,
        "expectedChannelRevision": channel["revision"],
        "expectedProgrammeRevision": programme["revision"],
        "programmeId": programme["programmeId"],
        "occurrenceStartsAt": programme["occurrenceStartsAt"],
    }
    live = client.post(
        f"{root}/{channel_id}/playback",
        headers=auth(pair),
        json={**playback_body, "mode": "live"},
    )
    restart = client.post(
        f"{root}/{channel_id}/playback",
        headers=auth(pair),
        json={**playback_body, "mode": "restart"},
    )
    assert live.status_code == 200 and live.json()["playback"]["startSeconds"] == 300
    assert restart.status_code == 200 and restart.json()["playback"]["startSeconds"] == 0

    with TestClient(create_app(settings)) as restarted:
        _bind_catalog(restarted.app, available)
        durable = restarted.get(f"{root}/{channel_id}", headers=auth(pair))
        assert durable.status_code == 200, durable.text
        assert durable.json()["channel"]["programmes"][0]["state"] == "scheduled"

        available.clear()
        gap = restarted.get(f"{root}/{channel_id}", headers=auth(pair))
        assert gap.status_code == 200, gap.text
        gap_channel = gap.json()["channel"]
        gap_programme = gap_channel["programmes"][0]
        assert (gap_programme["state"], gap_programme["reason"]) == (
            "gap",
            "deleted",
        )

        available[SECOND_ITEM] = second
        rescheduled = restarted.post(
            f"{root}/{channel_id}/programmes/{gap_programme['programmeId']}/reschedule",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "requestId": RESCHEDULE,
                "expectedRevision": gap_channel["revision"],
                "expectedProgrammeRevision": gap_programme["revision"],
                "source": _source(
                    SECOND_ITEM, second.mediaKey, "The Matrix Reloaded"
                ),
            },
        )
        assert rescheduled.status_code == 200, rescheduled.text
        active = rescheduled.json()["channel"]
        assert active["programmes"][0]["itemId"] == SECOND_ITEM
        assert active["programmes"][0]["state"] == "scheduled"

        cancelled = restarted.post(
            f"{root}/{channel_id}/cancel",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "requestId": CANCEL,
                "expectedRevision": active["revision"],
            },
        )
        assert cancelled.status_code == 200, cancelled.text
        assert cancelled.json()["channel"]["state"] == "cancelled"
