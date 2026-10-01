import asyncio

from fastapi.testclient import TestClient
import pytest

from conftest import auth, login
from larenor_server.app import create_app
from larenor_server.errors import ApiError
from larenor_server.offline_media.api import _content
from larenor_server.plugins.media_playback_models import (
    PlaybackInfoReadback,
    PrivateMediaPlaybackAuthority,
    local_playback_profile_digest,
)
from test_f27_offline_media_api import CONTENT, create_body, setup
from test_jellyfin_playback_runtime import local_profile


BASE = "/api/v1/media/offline/playback-leases"


@pytest.mark.parametrize('operation', ['head', 'renew', 'renew_after_read'])
def test_expiry_crossing_authority_or_renew_cas_never_reactivates_lease(
        server, monkeypatch, operation):
    app, client, _settings, clock = server
    pair, installation, current, worker = setup(server)
    body = lease_body(server, pair, installation, current)
    assert client.post(BASE, headers=auth(pair), json=body).status_code == 201
    service = app.state.core.offline_media
    if operation == 'renew_after_read':
        original = service._playback_owned

        def crossing(*args, **kwargs):
            row = original(*args, **kwargs)
            clock.now += 120
            return row

        monkeypatch.setattr(service, '_playback_owned', crossing)
    else:
        original = app.state.core.media_playback._gate

        def crossing(*args, **kwargs):
            result = original(*args, **kwargs)
            clock.now += 120
            return result

        monkeypatch.setattr(app.state.core.media_playback, '_gate', crossing)
    path = BASE + '/' + body['requestId']
    if operation == 'head':
        denied = client.head(path + '/content', headers=auth(pair))
    else:
        denied = client.post(path + '/renew', headers=auth(pair), json={
            'schemaVersion': 1, 'requestId': '7' * 32,
            'expectedRevision': 1})
    assert denied.status_code == 409
    assert service._playback_leases[body['requestId']]['revision'] == 1
    assert worker.calls == []


def test_observation_expiring_during_final_authority_gate_cannot_issue_lease(
        server, monkeypatch):
    app, client, _settings, clock = server
    pair, installation, current, worker = setup(server)
    body = lease_body(server, pair, installation, current)
    original = app.state.core.media_playback._gate
    checks = []

    def cross_expiry(*args, **kwargs):
        checks.append(True)
        result = original(*args, **kwargs)
        if len(checks) == 2:
            # The create preflight is first; consume's final authority gate
            # crosses the observation's inclusive expiry boundary.
            clock.now += 30
        return result

    monkeypatch.setattr(app.state.core.media_playback, '_gate', cross_expiry)
    denied = client.post(BASE, headers=auth(pair), json=body)
    assert denied.status_code == 404
    assert denied.json()['error']['code'] == 'not_found'
    assert not app.state.core.offline_media._playback_leases
    assert worker.calls == []


def test_capacity_rejection_preserves_unconsumed_current_observation(
        server, monkeypatch):
    import larenor_server.offline_media.service as lease_service
    app, client, _settings, _clock = server
    pair, installation, current, worker = setup(server)
    monkeypatch.setattr(lease_service, 'MAX_PLAYBACK_LEASES_PER_ACTOR', 1)
    first_body = lease_body(server, pair, installation, current)
    first = client.post(BASE, headers=auth(pair), json=first_body)
    assert first.status_code == 201
    pending = lease_body(
        server, pair, installation, current, request_id='2' * 32)
    limited = client.post(BASE, headers=auth(pair), json=pending)
    assert limited.status_code == 429
    retired = client.post(
        BASE + '/' + first_body['requestId'] + '/retire', headers=auth(pair),
        json={'schemaVersion': 1, 'requestId': '3' * 32,
              'expectedRevision': 1})
    assert retired.status_code == 200
    recovered = client.post(BASE, headers=auth(pair), json=pending)
    assert recovered.status_code == 201
    assert client.post(BASE, headers=auth(pair), json=pending).json() == (
        recovered.json())
    monkeypatch.setattr(lease_service, 'MAX_PLAYBACK_LEASES_PER_ACTOR', 2)
    assert client.post(BASE, headers=auth(pair), json=pending | {
        'requestId': '4' * 32}).status_code == 404
    assert worker.calls == []


def playback_observation(server, pair, installation, current, *,
                         outcome="direct_play_supported"):
    core = server[0].state.core
    actor = core.auth.authenticate(pair["accessToken"])
    jellyfin = next(
        value for value in current.sources if value.serviceId == "jellyfin")
    private = PrivateMediaPlaybackAuthority(
        installationId=installation["id"],
        installationRevision=installation["revision"],
        snapshotRevision=current.snapshotRevision,
        jellyfinServiceRevision=jellyfin.serviceRevision,
        itemId="b" * 32, mediaKey="movie:tmdb:603")
    profile = local_profile()
    with core.db.connection() as connection:
        revision = connection.execute(
            "SELECT revision FROM users WHERE id=?", (actor.id,)
        ).fetchone()["revision"]
    method = {
        "direct_play_supported": "direct_play",
        "requires_remux": "direct_stream",
        "requires_transcode": "transcode",
        "contract_unknown": "unknown",
    }[outcome]
    return core.media_playback.record_playback_info_observation(
        actor, revision, private, profile,
        PlaybackInfoReadback(
            itemId=private.itemId,
            profileDigest=local_playback_profile_digest(profile),
            assurance="provider_observed_for_client_reported_profile",
            originalByteOutcome=outcome, playMethod=method,
            source=(None if method == "unknown" else {
                "container": "mkv", "bitrate": 25_000_000,
                "videoCodecs": ["hevc"], "audioCodecs": ["eac3"],
                "videoRanges": ["HDR10"],
            }),
            transcoding=(
                {"container": "ts", "videoCodec": "h264",
                 "audioCodec": "aac", "bitrate": 8_000_000,
                 "reasons": ["ContainerNotSupported"]}
                if method == "transcode" else None),
            reason=("contract_unsupported" if method == "unknown"
                    else "available")))[0]


def lease_body(server, pair, installation, current,
               request_id="1" * 32, *, outcome="direct_play_supported"):
    value = create_body(installation, current, request_id=request_id)
    return {
        key: value[key]
        for key in (
            "schemaVersion", "requestId", "installationId",
            "expectedInstallationRevision", "expectedSnapshotRevision",
            "expectedJellyfinServiceRevision", "itemId", "mediaKey",
        )
    } | {"playbackObservationId": playback_observation(
        server, pair, installation, current, outcome=outcome)}


def test_core_bound_lease_streams_exact_ranges_and_retires_without_more_io(
        server):
    pair, installation, current, worker = setup(server)
    client = server[1]
    body = lease_body(server, pair, installation, current)
    created = client.post(
        BASE, headers=auth(pair), json=body)
    assert created.status_code == 201, created.text
    replay = client.post(
        BASE, headers=auth(pair), json=body)
    assert replay.status_code == 201 and replay.json() == created.json()
    lease = created.json()["lease"]
    assert set(lease) == {
        "schemaVersion", "leaseId", "revision", "authority", "title",
        "mediaKind", "runtimeSeconds", "contentLength", "contentType",
        "byteIntegrity", "supportsByteRanges", "state", "expiresAt",
        "restartBehavior",
    }
    assert lease["leaseId"] == "1" * 32 and lease["revision"] == 1
    assert lease["authority"] == {
        "schemaVersion": 1,
        "coreId": server[0].state.core.context.coreId,
        "homeId": server[0].state.core.context.homeId,
        "accountId": pair["user"]["id"],
        "accountRevision": lease["authority"]["accountRevision"],
        "sessionFamilyId": lease["authority"]["sessionFamilyId"],
        "installationId": installation["id"],
        "installationRevision": installation["revision"],
        "snapshotRevision": current.snapshotRevision,
        "jellyfinServiceRevision": next(
            value.serviceRevision for value in current.sources
            if value.serviceId == "jellyfin"),
        "itemId": "b" * 32,
        "mediaKey": "movie:tmdb:603",
    }
    assert lease["title"] == "The Matrix" and lease["mediaKind"] == "movie"
    assert lease["runtimeSeconds"] is None
    assert lease["contentLength"] == len(CONTENT)
    assert lease["contentType"] == "application/octet-stream"
    assert lease["byteIntegrity"] == "source_bound"
    assert lease["supportsByteRanges"] is True
    assert lease["state"] == "active"
    assert lease["expiresAt"] == server[3].now + 120
    assert lease["restartBehavior"] == "terminal_invalid"

    head = client.head(
        BASE + f"/{lease['leaseId']}/content", headers={
            **auth(pair), "Range": "bytes=2-5",
        })
    assert head.status_code == 206 and head.content == b""
    assert head.headers["content-range"] == "bytes 2-5/8"
    assert head.headers["content-length"] == "4"
    assert worker.calls == []

    selected = client.get(
        BASE + f"/{lease['leaseId']}/content", headers={
            **auth(pair), "Range": "bytes=2-5",
        })
    assert selected.status_code == 206 and selected.content == CONTENT[2:6]
    assert selected.headers["content-type"] == "application/octet-stream"
    assert selected.headers["x-content-type-options"] == "nosniff"
    assert [(value[2], value[3]) for value in worker.calls] == [(2, 4)]

    before = len(worker.calls)
    invalid = client.get(
        BASE + f"/{lease['leaseId']}/content", headers={
            **auth(pair), "Range": "bytes=0-1,4-5",
        })
    assert invalid.status_code == 416
    assert invalid.headers["content-range"] == "bytes */8"
    assert len(worker.calls) == before

    renewed_body = {
        "schemaVersion": 1, "requestId": "2" * 32,
        "expectedRevision": 1,
    }
    renewed = client.post(
        BASE + f"/{lease['leaseId']}/renew",
        headers=auth(pair), json=renewed_body)
    renewed_replay = client.post(
        BASE + f"/{lease['leaseId']}/renew",
        headers=auth(pair), json=renewed_body)
    assert renewed.status_code == 200
    assert renewed_replay.json() == renewed.json()
    assert renewed.json()["lease"]["revision"] == 2

    retired_body = {
        "schemaVersion": 1, "requestId": "3" * 32,
        "expectedRevision": 2,
    }
    retired = client.post(
        BASE + f"/{lease['leaseId']}/retire",
        headers=auth(pair), json=retired_body)
    retired_replay = client.post(
        BASE + f"/{lease['leaseId']}/retire",
        headers=auth(pair), json=retired_body)
    assert retired.status_code == 200
    assert retired_replay.json() == retired.json()
    assert retired.json()["lease"]["state"] == "retired"
    denied = client.get(
        BASE + f"/{lease['leaseId']}/content", headers=auth(pair))
    assert denied.status_code == 409
    assert len(worker.calls) == before


def test_lease_family_expiry_restart_and_drift_fail_before_or_after_worker(
        server):
    app, client, _, clock = server
    pair, installation, current, worker = setup(server)
    body = lease_body(
        server, pair, installation, current, request_id="4" * 32)
    created = client.post(BASE, headers=auth(pair), json=body)
    assert created.status_code == 201
    path = BASE + f"/{'4' * 32}/content"

    other = login(client, "admin", "Synthetic new password 2026",
                  device="Other playback family").json()
    hidden = client.get(path, headers=auth(other))
    assert hidden.status_code == 404 and worker.calls == []

    clock.now += 121
    expired = client.get(path, headers=auth(pair))
    assert expired.status_code == 409 and worker.calls == []
    clock.now -= 121

    with app.state.core.offline_media._playback_lock:
        app.state.core.offline_media._playback_leases.clear()
    restarted = client.get(path, headers=auth(pair))
    assert restarted.status_code == 404 and worker.calls == []

    recreated = client.post(BASE, headers=auth(pair), json={
        **body,
        "playbackObservationId": playback_observation(
            server, pair, installation, current),
    })
    assert recreated.status_code == 201

    def drift():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE users SET revision=revision+1 WHERE id=?",
                (pair["user"]["id"],))

    worker.change = drift
    late = client.get(path, headers=auth(pair))
    # Headers may already have started, but post-worker authority drift keeps
    # the returned bytes out of the response body.
    assert late.content == b""
    assert len(worker.calls) == 1


def test_range_parser_is_bounded_and_exact(server):
    service = server[0].state.core.offline_media
    assert service.playback_range(8, None) == (0, 7, 200)
    assert service.playback_range(8, "bytes=3-") == (3, 7, 206)
    assert service.playback_range(8, "bytes=-3") == (5, 7, 206)
    assert service.playback_range(8, "bytes=0-99") == (0, 7, 206)
    for value in (
        "bytes=", "bytes=8-9", "bytes=5-4", "bytes=-0",
        "bytes=0-1,3-4", "Bytes=0-1", "bytes=000000000000000000000-",
    ):
        assert service.playback_range(8, value) is None


def test_cancelled_response_schedules_no_chunk_after_current_read(server):
    app, client, _, _clock = server
    pair, installation, current, worker = setup(server)
    body = lease_body(
        server, pair, installation, current, request_id="6" * 32)
    assert client.post(BASE, headers=auth(pair), json=body).status_code == 201
    actor = app.state.core.auth.authenticate(pair["accessToken"])

    async def consume_then_cancel():
        response = _content(
            app.state.core, actor, "6" * 32, None, head=False)
        iterator = response.body_iterator
        first = await anext(iterator)
        await iterator.aclose()
        return first

    assert asyncio.run(consume_then_cancel()) == CONTENT[:4]
    assert [(value[2], value[3]) for value in worker.calls] == [(0, 8)]


def test_authority_drift_before_content_never_reaches_worker(server):
    app, client, _, _clock = server
    pair, installation, current, worker = setup(server)
    body = lease_body(
        server, pair, installation, current, request_id="5" * 32)
    assert client.post(BASE, headers=auth(pair), json=body).status_code == 201
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE users SET revision=revision+1 WHERE id=?",
            (pair["user"]["id"],))
    denied = client.get(
        BASE + f"/{'5' * 32}/content", headers=auth(pair))
    assert denied.status_code == 409
    assert denied.json()["error"]["code"] == "offline_media_authority_changed"
    assert worker.calls == []


def test_fresh_normal_core_instance_cannot_adopt_previous_playback_lease(server):
    app, client, settings, _clock = server
    pair, installation, current, worker = setup(server)
    body = lease_body(
        server, pair, installation, current, request_id="7" * 32)
    assert client.post(BASE, headers=auth(pair), json=body).status_code == 201
    path = BASE + f"/{'7' * 32}/content"
    pending_observation = playback_observation(
        server, pair, installation, current)
    jellyfin = next(
        value for value in current.sources if value.serviceId == "jellyfin")
    private = PrivateMediaPlaybackAuthority(
        installationId=installation["id"],
        installationRevision=installation["revision"],
        snapshotRevision=current.snapshotRevision,
        jellyfinServiceRevision=jellyfin.serviceRevision,
        itemId="b" * 32, mediaKey="movie:tmdb:603")
    fresh = create_app(settings)
    with TestClient(fresh) as restarted:
        assert fresh.state.core is not app.state.core
        assert fresh.state.core.offline_media is not app.state.core.offline_media
        missing = restarted.get(path, headers=auth(pair))
        assert missing.status_code == 404
        assert missing.json()["error"]["code"] == "not_found"
        actor = fresh.state.core.auth.authenticate(pair["accessToken"])
        with pytest.raises(ApiError) as raised:
            fresh.state.core.media_playback.consume_playback_info_observation(
                actor, pending_observation, private)
        assert raised.value.status == 404
    assert worker.calls == []


def test_lease_requires_one_current_direct_play_observation(server):
    app, client, _settings, clock = server
    pair, installation, current, worker = setup(server)
    base = create_body(installation, current, request_id="8" * 32)
    request = {
        key: base[key]
        for key in (
            "schemaVersion", "requestId", "installationId",
            "expectedInstallationRevision", "expectedSnapshotRevision",
            "expectedJellyfinServiceRevision", "itemId", "mediaKey",
        )
    }
    missing = client.post(BASE, headers=auth(pair), json=request)
    assert missing.status_code == 400

    remux_id = playback_observation(
        server, pair, installation, current, outcome="requires_remux")
    remux = client.post(
        BASE, headers=auth(pair),
        json=request | {"playbackObservationId": remux_id})
    assert remux.status_code == 409
    assert remux.json()["error"]["code"] == "offline_media_unavailable"
    remux_replay = client.post(
        BASE, headers=auth(pair),
        json=request | {"playbackObservationId": remux_id})
    assert remux_replay.status_code == 404
    assert remux_replay.json()["error"]["code"] == "not_found"

    expired_id = playback_observation(server, pair, installation, current)
    clock.now += 31
    expired = client.post(
        BASE, headers=auth(pair),
        json=request | {"playbackObservationId": expired_id})
    assert expired.status_code == 404
    clock.now -= 31

    direct_id = playback_observation(server, pair, installation, current)
    first_body = request | {"playbackObservationId": direct_id}
    first = client.post(BASE, headers=auth(pair), json=first_body)
    assert first.status_code == 201, first.text
    assert client.post(
        BASE, headers=auth(pair), json=first_body).json() == first.json()
    reused = client.post(
        BASE, headers=auth(pair),
        json=first_body | {"requestId": "9" * 32})
    assert reused.status_code == 404
    assert worker.calls == []

    other = login(
        client, "admin", "Synthetic new password 2026",
        device="Other observed playback family").json()
    family_id = playback_observation(server, pair, installation, current)
    hidden = client.post(
        BASE, headers=auth(other),
        json=request | {
            "requestId": "a" * 32,
            "playbackObservationId": family_id,
        })
    assert hidden.status_code == 404
    assert app.state.core.offline_media._playback_leases.get("a" * 32) is None
