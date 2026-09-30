import uuid

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import ApiError
from larenor_server.plugins.media_playback_models import (
    MediaPlaybackIntent,
    MediaPlaybackReceipt,
    MediaPlaybackTarget,
    PrivateMediaPlaybackAuthority,
)
from larenor_server.personal_channels.models import StopChannelExecutionRequest


INSTALLATION = "1" * 32
FIRST_ITEM = "2" * 32
SECOND_ITEM = "3" * 32
CREATE = "4" * 32
START = "5" * 32
CANCEL = "6" * 32
TARGET = "jellyfin-player:living-room"


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
        "durationSeconds": 60,
    }


class Playback:
    def __init__(self, authorities, *, lose_ack=False):
        self.authorities = authorities
        self.lose_ack = lose_ack
        self.commands = []
        self.intents = {}
        self.before_effect = None
        self.after_effect = None
        self.before_prepare = None
        self.assert_actor = None

    def _catalog(self, _actor, request):
        authority = self.authorities.get(request.itemId)
        if authority is None or authority.mediaKey != request.mediaKey:
            raise ApiError("media_playback_item_changed", 409)
        return authority

    def _prepared(self, body):
        authority = self._catalog(None, body)
        self.intents[body.requestId] = authority.itemId
        return {
            "intent": MediaPlaybackIntent(
                **body.model_dump(),
                playbackRevision=len(self.commands) + 1,
                expiresAt=253402300799,
                targets=[
                    MediaPlaybackTarget(
                        targetId=TARGET,
                        targetRevision=len(self.commands) + 10,
                        name="Living room",
                        available=True,
                        currentItemId=None,
                        positionSeconds=0,
                        qualityObservation=None,
                    )
                ],
            ).model_dump()
        }

    def prepare(self, actor, body):
        if self.before_prepare is not None:
            self.before_prepare()
        if self.assert_actor is not None:
            self.assert_actor(actor)
        return self._prepared(body)

    def _prepare_scoped(self, _actor_id, _family_id, _actor_revision, body,
                        _assert_current):
        if self.before_prepare is not None:
            self.before_prepare()
        return self._prepared(body)

    def _command_scoped(self, _actor_id, _family_id, _actor_revision, body,
                        _assert_current, *, effect_gate=None):
        return self.command(None, body, effect_gate=effect_gate)

    def command(self, _actor, body, *, effect_gate=None):
        if self.before_effect is not None:
            self.before_effect()
        if effect_gate is not None and effect_gate() is not True:
            raise ApiError("media_playback_worker_unavailable", 503)
        self.commands.append(body)
        if self.after_effect is not None:
            self.after_effect()
        if effect_gate is not None and effect_gate() is not True:
            raise ApiError("media_playback_worker_unavailable", 503)
        if self.lose_ack:
            raise ApiError("media_playback_worker_unavailable", 503)
        return {
            "receipt": MediaPlaybackReceipt(
                requestId=body.requestId,
                intentId=body.intentId,
                installationId=INSTALLATION,
                itemId=self.intents[body.intentId],
                targetId=body.targetId,
                playbackRevision=body.expectedPlaybackRevision + 1,
                state="succeeded",
                code="authenticated_readback",
            ).model_dump()
        }

def _create(client, pair, clock):
    created = client.post(
        "/api/v1/media/personal-channels",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": CREATE,
            "name": "Continuous cinema",
            "startsAt": int(clock.now) - 10,
            "loop": True,
            "sources": [
                _source(FIRST_ITEM, "movie:tmdb:603", "First"),
                _source(SECOND_ITEM, "movie:tmdb:604", "Second"),
            ],
        },
    )
    assert created.status_code == 201, created.text
    channel = created.json()["channel"]
    programme = next(
        item
        for item in channel["programmes"]
        if item["occurrenceStartsAt"] <= clock.now < item["occurrenceEndsAt"]
    )
    return channel, programme


def test_continuous_execution_progresses_once_per_occurrence_and_survives_restart(server):
    app, client, settings, clock = server
    pair = ready(server)
    authorities = {
        FIRST_ITEM: _authority(FIRST_ITEM, "movie:tmdb:603"),
        SECOND_ITEM: _authority(SECOND_ITEM, "movie:tmdb:604"),
    }
    playback = Playback(authorities)
    app.state.core.personal_channels.media_playback = playback
    channel, programme = _create(client, pair, clock)
    missing = client.get(
        f"/api/v1/media/personal-channels/{channel['channelId']}/continuous",
        headers=auth(pair),
    )
    assert missing.status_code == 404

    started = client.post(
        f"/api/v1/media/personal-channels/{channel['channelId']}/continuous",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": START,
            "expectedChannelRevision": channel["revision"],
            "expectedProgrammeRevision": programme["revision"],
            "programmeId": programme["programmeId"],
            "occurrenceStartsAt": programme["occurrenceStartsAt"],
            "targetId": TARGET,
        },
    )
    assert started.status_code == 200, started.text
    assert started.json()["execution"]["code"] == "authenticated_readback"
    assert len(playback.commands) == 1

    clock.now = programme["occurrenceEndsAt"] + 5
    app.state.core.personal_channels.tick()
    assert len(playback.commands) == 2

    restarted_app = create_app(settings)
    restarted_app.state.core.personal_channels.media_playback = playback
    restarted_app.state.core.personal_channels.tick()
    assert len(playback.commands) == 2


def test_continuous_execution_survives_access_expiry_without_foreground_refresh(
        server):
    app, client, _settings, clock = server
    pair = ready(server)
    playback = Playback({
        FIRST_ITEM: _authority(FIRST_ITEM, "movie:tmdb:603"),
        SECOND_ITEM: _authority(SECOND_ITEM, "movie:tmdb:604"),
    })
    app.state.core.personal_channels.media_playback = playback
    channel, programme = _create(client, pair, clock)
    started = client.post(
        f"/api/v1/media/personal-channels/{channel['channelId']}/continuous",
        headers=auth(pair),
        json={
            "schemaVersion": 1, "requestId": START,
            "expectedChannelRevision": channel["revision"],
            "expectedProgrammeRevision": programme["revision"],
            "programmeId": programme["programmeId"],
            "occurrenceStartsAt": programme["occurrenceStartsAt"],
            "targetId": TARGET,
        },
    )
    assert started.status_code == 200 and len(playback.commands) == 1

    clock.now += 901
    app.state.core.personal_channels.tick(channel["channelId"])

    assert len(playback.commands) == 2
    with app.state.core.db.connection() as connection:
        execution = connection.execute(
            "SELECT state,code FROM personal_channel_executions WHERE channel_id=?",
            (channel["channelId"],),
        ).fetchone()
    assert (execution["state"], execution["code"]) == (
        "active", "authenticated_readback")


def test_access_rotation_between_reservation_and_prepare_keeps_family_authority(
        server):
    app, client, _settings, clock = server
    pair = ready(server)
    playback = Playback({
        FIRST_ITEM: _authority(FIRST_ITEM, "movie:tmdb:603"),
        SECOND_ITEM: _authority(SECOND_ITEM, "movie:tmdb:604"),
    })
    app.state.core.personal_channels.media_playback = playback
    channel, programme = _create(client, pair, clock)
    rotated = {}

    def rotate():
        playback.before_prepare = None
        response = client.post(
            "/api/v1/auth/refresh", json={"refreshToken": pair["refreshToken"]})
        assert response.status_code == 200, response.text
        rotated.update(response.json())

    def assert_actor(actor):
        with app.state.core.db.connection() as connection:
            app.state.core.auth.assert_current(connection, actor)

    playback.before_prepare = rotate
    playback.assert_actor = assert_actor
    started = client.post(
        f"/api/v1/media/personal-channels/{channel['channelId']}/continuous",
        headers=auth(pair),
        json={
            "schemaVersion": 1, "requestId": START,
            "expectedChannelRevision": channel["revision"],
            "expectedProgrammeRevision": programme["revision"],
            "programmeId": programme["programmeId"],
            "occurrenceStartsAt": programme["occurrenceStartsAt"],
            "targetId": TARGET,
        },
    )

    assert rotated["sessionFamilyId"] == pair["sessionFamilyId"]
    # The old bearer was legitimately retired while this HTTP request was in
    # flight, so its final response may be 401. The durable family authority
    # must still complete, and the rotated bearer must read that exact result.
    assert started.status_code == 401, started.text
    current = client.get(
        f"/api/v1/media/personal-channels/{channel['channelId']}/continuous",
        headers=auth(rotated),
    )
    assert current.status_code == 200, current.text
    assert current.json()["execution"]["code"] == "authenticated_readback"
    assert len(playback.commands) == 1


def test_v1_database_restart_preserves_channels_and_adds_empty_execution_journal(
        server):
    app, client, settings, clock = server
    pair = ready(server)
    app.state.core.personal_channels.media_playback = Playback({
        FIRST_ITEM: _authority(FIRST_ITEM, "movie:tmdb:603"),
        SECOND_ITEM: _authority(SECOND_ITEM, "movie:tmdb:604"),
    })
    channel, _programme = _create(client, pair, clock)
    with app.state.core.db.transaction() as connection:
        connection.execute("DROP TABLE personal_channel_executions")
        connection.execute(
            "UPDATE metadata SET value='1' "
            "WHERE key='personal_channels_schema'")

    restarted = create_app(settings)
    actor = restarted.state.core.auth.authenticate(pair["accessToken"])
    channels = restarted.state.core.personal_channels.list(actor)["channels"]

    assert [item.channelId for item in channels] == [channel["channelId"]]
    with restarted.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT value FROM metadata WHERE key='personal_channels_schema'"
        ).fetchone()[0] == "2"
        assert connection.execute(
            "SELECT COUNT(*) FROM personal_channel_executions").fetchone()[0] == 0


def test_lost_ack_is_never_replayed_and_missed_boundary_moves_forward(server):
    app, client, settings, clock = server
    pair = ready(server)
    authorities = {
        FIRST_ITEM: _authority(FIRST_ITEM, "movie:tmdb:603"),
        SECOND_ITEM: _authority(SECOND_ITEM, "movie:tmdb:604"),
    }
    playback = Playback(authorities, lose_ack=True)
    app.state.core.personal_channels.media_playback = playback
    channel, programme = _create(client, pair, clock)
    body = {
        "schemaVersion": 1,
        "requestId": START,
        "expectedChannelRevision": channel["revision"],
        "expectedProgrammeRevision": programme["revision"],
        "programmeId": programme["programmeId"],
        "occurrenceStartsAt": programme["occurrenceStartsAt"],
        "targetId": TARGET,
    }
    root = f"/api/v1/media/personal-channels/{channel['channelId']}"
    started = client.post(f"{root}/continuous", headers=auth(pair), json=body)
    assert started.status_code == 200, started.text
    assert started.json()["execution"]["state"] == "dispatching"
    assert started.json()["execution"]["code"] == "effect_unknown"
    assert len(playback.commands) == 1

    replay = client.post(f"{root}/continuous", headers=auth(pair), json=body)
    assert replay.status_code == 200
    app.state.core.personal_channels.tick()
    assert len(playback.commands) == 1

    playback.lose_ack = False
    clock.now = programme["occurrenceEndsAt"] + 5
    restarted_app = create_app(settings)
    restarted_app.state.core.personal_channels.media_playback = playback
    restarted_app.state.core.personal_channels.tick()
    assert len(playback.commands) == 2


def test_cancel_and_source_revision_drift_stop_future_dispatch(server):
    app, client, _settings, clock = server
    pair = ready(server)
    authorities = {
        FIRST_ITEM: _authority(FIRST_ITEM, "movie:tmdb:603"),
        SECOND_ITEM: _authority(SECOND_ITEM, "movie:tmdb:604"),
    }
    playback = Playback(authorities)
    app.state.core.personal_channels.media_playback = playback
    channel, programme = _create(client, pair, clock)
    root = f"/api/v1/media/personal-channels/{channel['channelId']}"
    started = client.post(
        f"{root}/continuous",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": START,
            "expectedChannelRevision": channel["revision"],
            "expectedProgrammeRevision": programme["revision"],
            "programmeId": programme["programmeId"],
            "occurrenceStartsAt": programme["occurrenceStartsAt"],
            "targetId": TARGET,
        },
    )
    assert started.status_code == 200
    assert len(playback.commands) == 1

    authorities.pop(SECOND_ITEM)
    refreshed = client.get(root, headers=auth(pair))
    assert refreshed.status_code == 200
    clock.now = programme["occurrenceEndsAt"] + 5
    app.state.core.personal_channels.tick()
    status = client.get(f"{root}/continuous", headers=auth(pair))
    assert status.status_code == 200
    assert status.json()["execution"]["code"] == "source_changed"
    assert len(playback.commands) == 1

    cancelled = client.post(
        f"{root}/cancel",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": CANCEL,
            "expectedRevision": refreshed.json()["channel"]["revision"],
        },
    )
    assert cancelled.status_code == 200, cancelled.text
    app.state.core.personal_channels.tick()
    assert len(playback.commands) == 1


def test_fresh_target_is_required_before_any_playback_effect(server):
    app, client, _settings, clock = server
    pair = ready(server)
    authorities = {
        FIRST_ITEM: _authority(FIRST_ITEM, "movie:tmdb:603"),
        SECOND_ITEM: _authority(SECOND_ITEM, "movie:tmdb:604"),
    }
    playback = Playback(authorities)
    app.state.core.personal_channels.media_playback = playback
    channel, programme = _create(client, pair, clock)
    response = client.post(
        f"/api/v1/media/personal-channels/{channel['channelId']}/continuous",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": START,
            "expectedChannelRevision": channel["revision"],
            "expectedProgrammeRevision": programme["revision"],
            "programmeId": programme["programmeId"],
            "occurrenceStartsAt": programme["occurrenceStartsAt"],
            "targetId": "jellyfin-player:foreign",
        },
    )
    assert response.status_code == 200, response.text
    assert response.json()["execution"]["code"] == "target_unavailable"
    assert playback.commands == []


def test_logout_retires_progression_before_next_programme(server):
    app, client, _settings, clock = server
    pair = ready(server)
    authorities = {
        FIRST_ITEM: _authority(FIRST_ITEM, "movie:tmdb:603"),
        SECOND_ITEM: _authority(SECOND_ITEM, "movie:tmdb:604"),
    }
    playback = Playback(authorities)
    app.state.core.personal_channels.media_playback = playback
    channel, programme = _create(client, pair, clock)
    started = client.post(
        f"/api/v1/media/personal-channels/{channel['channelId']}/continuous",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": START,
            "expectedChannelRevision": channel["revision"],
            "expectedProgrammeRevision": programme["revision"],
            "programmeId": programme["programmeId"],
            "occurrenceStartsAt": programme["occurrenceStartsAt"],
            "targetId": TARGET,
        },
    )
    assert started.status_code == 200
    assert client.post("/api/v1/auth/logout", headers=auth(pair)).status_code == 204
    clock.now = programme["occurrenceEndsAt"] + 5
    app.state.core.personal_channels.tick()
    assert len(playback.commands) == 1
    with app.state.core.db.connection() as connection:
        row = connection.execute(
            "SELECT state,code FROM personal_channel_executions WHERE channel_id=?",
            (channel["channelId"],),
        ).fetchone()
    assert (row["state"], row["code"]) == (
        "needs_attention",
        "authority_changed",
    )


def test_cancel_at_effect_gate_prevents_post_and_post_send_cancel_is_unknown(
        server):
    app, client, _settings, clock = server
    pair = ready(server)
    principal = app.state.core.auth.authenticate(pair["accessToken"])
    authorities = {
        FIRST_ITEM: _authority(FIRST_ITEM, "movie:tmdb:603"),
        SECOND_ITEM: _authority(SECOND_ITEM, "movie:tmdb:604"),
    }

    def scenario(*, after_effect):
        playback = Playback(authorities)
        app.state.core.personal_channels.media_playback = playback
        channel, programme = _create(client, pair, clock)

        def cancel():
            with app.state.core.db.connection() as connection:
                revision = connection.execute(
                    "SELECT revision FROM personal_channel_executions "
                    "WHERE channel_id=?", (channel["channelId"],),
                ).fetchone()["revision"]
            app.state.core.personal_channels.stop_execution(
                principal,
                channel["channelId"],
                StopChannelExecutionRequest(
                    schemaVersion=1,
                    requestId=("8" if after_effect else "7") * 32,
                    expectedExecutionRevision=revision,
                ),
            )

        if after_effect:
            playback.after_effect = cancel
        else:
            playback.before_effect = cancel
        response = client.post(
            f"/api/v1/media/personal-channels/{channel['channelId']}/continuous",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "requestId": uuid.uuid4().hex,
                "expectedChannelRevision": channel["revision"],
                "expectedProgrammeRevision": programme["revision"],
                "programmeId": programme["programmeId"],
                "occurrenceStartsAt": programme["occurrenceStartsAt"],
                "targetId": TARGET,
            },
        )
        assert response.status_code == 200, response.text
        assert response.json()["execution"]["state"] == "cancelled"
        app.state.core.personal_channels.tick(channel["channelId"])
        return playback

    denied = scenario(after_effect=False)
    assert denied.commands == []
    sent = scenario(after_effect=True)
    assert len(sent.commands) == 1
