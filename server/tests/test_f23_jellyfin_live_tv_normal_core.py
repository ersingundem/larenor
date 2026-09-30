import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from support.f23_jellyfin_fixture import JellyfinLiveTvFixture


PROGRAM = JellyfinLiveTvFixture.program_id
SERVER = JellyfinLiveTvFixture.server_id
TOKEN = JellyfinLiveTvFixture.token


@pytest.fixture
def jellyfin_live_tv():
    state = JellyfinLiveTvFixture(1790757000)
    try:
        yield state
    finally:
        state.close()


def _configured(server, upstream):
    app, client, _settings, _clock = server
    actor = ready(server)
    saved = client.post("/api/v1/admin/services", headers=auth(actor), json={
        "kind": "jellyfin", "name": "Jellyfin Live TV",
        "baseUrl": upstream.url, "credentials": {"apiKey": TOKEN},
    })
    assert saved.status_code == 201, saved.text
    service = saved.json()["service"]
    principal = app.state.core.auth.authenticate(actor["accessToken"])
    app.state.core.services.record_verification(
        principal, service["id"], service["revision"],
        state="authenticated", version="10.11.1",
    )
    return actor, service


def _source(client, actor, service, *, request_id="4" * 32):
    response = client.put("/api/v1/media/live-tv/jellyfin-source", headers=auth(actor), json={
        "schemaVersion": 1, "requestId": request_id,
        "expectedRevision": 0, "serviceId": service["id"],
        "expectedServiceRevision": 1, "providerKind": "iptv",
        "timeZone": "Europe/Istanbul", "quotaBytes": 10_737_418_240,
    })
    assert response.status_code == 200, response.text
    return response.json()["snapshot"]


def test_normal_core_configures_real_jellyfin_guide_and_reconciles_lost_create(
    server, jellyfin_live_tv
):
    _app, client, _settings, clock = server
    clock.now = 1790757000  # 2026-09-30 08:30:00 UTC
    actor, service = _configured(server, jellyfin_live_tv)
    root = "/api/v1/media/live-tv"
    options = client.get(root + "/source-options", headers=auth(actor))
    assert options.status_code == 200, options.text
    assert options.json()["expectedRevision"] == 0
    assert options.json()["services"] == [{
        "serviceId": service["id"], "serviceRevision": 1,
        "name": "Jellyfin Live TV", "version": "10.11.1",
    }]
    snapshot = _source(client, actor, service)
    assert snapshot["programmes"][0]["programmeId"] == PROGRAM
    assert snapshot["parallelTuners"] == 1
    public_snapshot = str(snapshot)
    assert TOKEN not in public_snapshot and SERVER not in public_snapshot

    jellyfin_live_tv.drop_next_create_response = True
    body = {
        "schemaVersion": 1, "requestId": "5" * 32,
        "expectedSourceRevision": snapshot["authority"]["sourceRevision"],
        "expectedProviderRevision": snapshot["authority"]["providerRevision"],
        "programmeId": PROGRAM,
    }
    first = client.post(root + "/recordings", headers=auth(actor), json=body)
    assert first.status_code == 503
    recovered = client.post(root + "/recordings", headers=auth(actor), json=body)
    assert recovered.status_code == 201, recovered.text
    assert len(jellyfin_live_tv.timers) == 1
    recording = recovered.json()["recording"]
    cancelled = client.post(
        root + f'/recordings/{recording["recordingId"]}/cancel',
        headers=auth(actor), json={
            "schemaVersion": 1, "requestId": "6" * 32,
            "expectedRevision": recording["revision"],
        },
    )
    assert cancelled.status_code == 200, cancelled.text
    assert cancelled.json()["recording"]["state"] == "cancelled"
    # The first create reached Jellyfin but its response was lost. Retrying the
    # Larenor request reconciles the marker and never sends a second POST.
    assert sum(method == "POST" for method, _path in jellyfin_live_tv.calls) == 1
    assert sum(method == "DELETE" for method, _path in jellyfin_live_tv.calls) == 1


def test_service_revision_drift_blocks_timer_mutation(server, jellyfin_live_tv):
    _app, client, _settings, clock = server
    clock.now = 1790757000
    actor, service = _configured(server, jellyfin_live_tv)
    snapshot = _source(client, actor, service)
    changed = client.patch(
        f'/api/v1/admin/services/{service["id"]}', headers=auth(actor), json={
            "name": "Renamed Jellyfin", "baseUrl": jellyfin_live_tv.url,
            "expectedRevision": service["revision"],
        },
    )
    assert changed.status_code == 200, changed.text
    result = client.post(
        "/api/v1/media/live-tv/recordings", headers=auth(actor), json={
            "schemaVersion": 1, "requestId": "7" * 32,
            "expectedSourceRevision": snapshot["authority"]["sourceRevision"],
            "expectedProviderRevision": snapshot["authority"]["providerRevision"],
            "programmeId": PROGRAM,
        },
    )
    assert result.status_code == 409
    assert result.json()["error"]["code"] == "live_tv_source_changed"
    assert not any(method == "POST" for method, _path in jellyfin_live_tv.calls)


def test_secret_free_source_reopens_with_live_jellyfin_authority(
    server, jellyfin_live_tv
):
    _app, client, settings, clock = server
    clock.now = 1790757000
    actor, service = _configured(server, jellyfin_live_tv)
    before = _source(client, actor, service)
    with TestClient(create_app(settings)) as restarted:
        observed = restarted.get("/api/v1/media/live-tv", headers=auth(actor))
        assert observed.status_code == 200, observed.text
        after = observed.json()["snapshot"]
        assert after["authority"] == before["authority"]
        options = restarted.get(
            "/api/v1/media/live-tv/source-options", headers=auth(actor)
        )
        assert options.status_code == 200, options.text
        assert options.json()["expectedRevision"] == 1


def test_interrupted_jellyfin_timer_restarts_as_new_guarded_timer(
    server, jellyfin_live_tv
):
    _app, client, _settings, clock = server
    clock.now = 1790757000
    actor, service = _configured(server, jellyfin_live_tv)
    snapshot = _source(client, actor, service)
    root = "/api/v1/media/live-tv"
    scheduled = client.post(root + "/recordings", headers=auth(actor), json={
        "schemaVersion": 1, "requestId": "8" * 32,
        "expectedSourceRevision": snapshot["authority"]["sourceRevision"],
        "expectedProviderRevision": snapshot["authority"]["providerRevision"],
        "programmeId": PROGRAM,
    })
    assert scheduled.status_code == 201, scheduled.text
    first_timer = next(iter(jellyfin_live_tv.timers.values()))
    first_timer["Status"] = "Error"
    observed = client.get(root, headers=auth(actor))
    assert observed.status_code == 200, observed.text
    recording = observed.json()["snapshot"]["recordings"][0]
    assert recording["state"] == "interrupted"
    restarted = client.post(
        root + f'/recordings/{recording["recordingId"]}/restart',
        headers=auth(actor), json={
            "schemaVersion": 1, "requestId": "9" * 32,
            "expectedRevision": recording["revision"],
        },
    )
    assert restarted.status_code == 200, restarted.text
    result = restarted.json()["recording"]
    assert result["state"] == "scheduled" and result["restartCount"] == 1
    assert len(jellyfin_live_tv.timers) == 2


def test_completed_recording_survives_jellyfin_timer_retirement(
    server, jellyfin_live_tv
):
    _app, client, _settings, clock = server
    clock.now = 1790757000
    actor, service = _configured(server, jellyfin_live_tv)
    snapshot = _source(client, actor, service)
    root = "/api/v1/media/live-tv"
    scheduled = client.post(root + "/recordings", headers=auth(actor), json={
        "schemaVersion": 1, "requestId": "a" * 32,
        "expectedSourceRevision": snapshot["authority"]["sourceRevision"],
        "expectedProviderRevision": snapshot["authority"]["providerRevision"],
        "programmeId": PROGRAM,
    })
    assert scheduled.status_code == 201, scheduled.text
    timer_id = next(iter(jellyfin_live_tv.timers))
    jellyfin_live_tv.timers.pop(timer_id)
    jellyfin_live_tv.recordings.append({
        "TimerId": timer_id, "MediaSources": [{"Size": 1_234_567}],
    })
    observed = client.get(root, headers=auth(actor))
    assert observed.status_code == 200, observed.text
    recording = observed.json()["snapshot"]["recordings"][0]
    assert recording["state"] == "completed"
    assert recording["bytesWritten"] == 1_234_567


def _schedule(client, actor, snapshot, request_id='b'*32):
    response = client.post('/api/v1/media/live-tv/recordings', headers=auth(actor), json={
        'schemaVersion':1, 'requestId':request_id,
        'expectedSourceRevision':snapshot['authority']['sourceRevision'],
        'expectedProviderRevision':snapshot['authority']['providerRevision'],
        'programmeId':PROGRAM,
    })
    assert response.status_code == 201, response.text
    return response.json()['recording']


def test_unknown_recording_size_never_becomes_zero_byte_evidence(server, jellyfin_live_tv):
    app, client, _settings, clock = server
    clock.now = 1790757000
    actor, service = _configured(server, jellyfin_live_tv)
    snapshot = _source(client, actor, service)
    _schedule(client, actor, snapshot)
    timer_id = next(iter(jellyfin_live_tv.timers))
    jellyfin_live_tv.timers[timer_id]['Status'] = 'InProgress'
    jellyfin_live_tv.recordings.append({'TimerId':timer_id, 'Status':'InProgress'})
    result = client.get('/api/v1/media/live-tv', headers=auth(actor))
    assert result.status_code == 200, result.text
    assert result.json()['snapshot']['usedBytes'] is None
    assert result.json()['snapshot']['recordings'][0]['state'] == 'uncertain'
    # Unknown source size also prevents any new admission.
    with app.state.core.db.connection() as connection:
        source = app.state.core.live_tv._source(connection.execute('SELECT * FROM live_tv_source').fetchone())
        with pytest.raises(Exception, match='live_tv_recorder_unavailable'):
            app.state.core.live_tv._storage_usage(connection, source)


def test_background_quota_stop_retains_partial_bytes_and_reconciles_lost_cancel(server, jellyfin_live_tv):
    app, client, settings, clock = server
    clock.now = 1790757000
    actor, service = _configured(server, jellyfin_live_tv)
    snapshot = _source(client, actor, service)
    recording = _schedule(client, actor, snapshot, request_id='c'*32)
    timer_id = next(iter(jellyfin_live_tv.timers))
    jellyfin_live_tv.timers[timer_id]['Status'] = 'InProgress'
    size = 12 * 1024**3
    jellyfin_live_tv.recordings.append({'TimerId':timer_id, 'Status':'InProgress', 'MediaSources':[{'Size':size}]})
    jellyfin_live_tv.drop_next_cancel_response = True
    app.state.core.live_tv._next_tick = 0
    with pytest.raises(Exception, match='live_tv_recorder_unavailable'):
        app.state.core.live_tv.tick()
    with app.state.core.db.connection() as connection:
        assert connection.execute('SELECT state FROM live_tv_quota_stops').fetchone()[0] == 'pending'
    # New Core sees the committed intent, observes absence, never repeats DELETE.
    restarted_app = create_app(settings)
    assert restarted_app.state.core.live_tv.tick() is True
    with restarted_app.state.core.db.connection() as connection:
        row = connection.execute('SELECT * FROM live_tv_recordings WHERE id=?',(recording['recordingId'],)).fetchone()
        assert row['state'] == 'partial' and row['bytes_written'] == size
        assert connection.execute('SELECT state FROM live_tv_quota_stops').fetchone()[0] == 'completed'
    with TestClient(restarted_app) as reopened:
        result = reopened.get('/api/v1/media/live-tv', headers=auth(actor))
        assert result.status_code == 200, result.text
        assert result.json()['snapshot']['usedBytes'] == size
    assert sum(method=='DELETE' for method,_path in jellyfin_live_tv.calls) == 1
