import base64
import hashlib
import threading
from contextlib import contextmanager

import pytest

from conftest import auth
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.power_recovery import service as power_service
from larenor_server.offline_media.models import ReadOfflineMediaChunkRequest
from larenor_server.plugins.media_playback_models import OfflineMediaChunkReadback
from test_f27_offline_media_api import (
    BASE,
    CONTENT,
    create_body,
    setup,
)


def _hold(app, value=True):
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE power_recovery_state SET gate_state=? WHERE id=1",
            ("held" if value else "open",),
        )


def _active(app):
    with app.state.core.db.connection() as connection:
        return app.state.core.power_recovery._active_work(connection)


def _isolate_offline_drain(monkeypatch):
    expected = (
        "offline_media_grants",
        "state='transferring' AND expires_at>:now",
    )
    assert expected in power_service._ACTIVE_WORK
    monkeypatch.setattr(power_service, "_ACTIVE_WORK", (expected,))


def _chunk(grant, revision=1, offset=0, request="b" * 32):
    return {
        "schemaVersion": 1,
        "requestId": request,
        "expectedRevision": revision,
        "offset": offset,
    }


def _queue_drain(app, now):
    event, run, step = "d" * 32, "e" * 32, "f" * 32
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "INSERT INTO power_recovery_events VALUES(?,?,?,?,?,?,?,?)",
            (event, 1, 1, "lowBattery", 10, 30, now, now),
        )
        connection.execute(
            "INSERT INTO power_recovery_runs VALUES(?,?,?,?,?,?,NULL,NULL)",
            (run, 1, event, "draining", now, now),
        )
        connection.execute(
            "INSERT INTO power_recovery_steps VALUES(?,?,?,?,?,?,?,?,?,?)",
            (step, run, 1, "drainActiveWork", None, None, "queued",
             "pending", now, now),
        )
        connection.execute(
            "UPDATE power_recovery_state SET source_state='lowBattery',"
            "last_sequence=1,last_observed_at=?,active_run_id=? WHERE id=1",
            (now, run),
        )
    return step


def _step(app, step):
    with app.state.core.db.connection() as connection:
        return dict(connection.execute(
            "SELECT state,result_code FROM power_recovery_steps "
            "WHERE step_id=?", (step,)).fetchone())


def test_hold_blocks_new_grant_and_first_transfer_without_worker_io(
    server, monkeypatch
):
    app, client, _settings, _clock = server
    _isolate_offline_drain(monkeypatch)
    pair, installation, current, worker = setup(server)
    admitted = create_body(installation, current, request_id="a" * 32)
    assert client.post(BASE + "/grants", headers=auth(pair), json=admitted).status_code == 201

    _hold(app)
    blocked_create = client.post(
        BASE + "/grants",
        headers=auth(pair),
        json=create_body(installation, current, request_id="1" * 32),
    )
    blocked_chunk = client.post(
        BASE + f"/grants/{'a' * 32}/chunk",
        headers=auth(pair),
        json=_chunk("a" * 32),
    )
    blocked_progress = client.post(
        BASE + f"/grants/{'a' * 32}/progress",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": "c" * 32,
            "expectedRevision": 1,
            "downloadedBytes": 4,
            "contentSha256": None,
        },
    )

    assert blocked_create.status_code == 503
    assert blocked_create.json()["error"]["code"] == "power_recovery_held"
    assert blocked_chunk.status_code == 503
    assert blocked_chunk.json()["error"]["code"] == "power_recovery_held"
    assert blocked_progress.status_code == 503
    assert blocked_progress.json()["error"]["code"] == "power_recovery_held"
    replay = client.post(BASE + "/grants", headers=auth(pair), json=admitted)
    assert replay.status_code == 201
    assert replay.json()["manifest"]["grantId"] == "a" * 32
    assert worker.calls == []
    retained = client.get(BASE + f"/grants/{'a' * 32}", headers=auth(pair))
    assert retained.json()["manifest"]["state"] == "granted"
    assert _active(app) is False

    # A hold that begins after provider preflight but before grant persistence
    # must win the final same-database admission check.
    _hold(app, False)
    original_catalog = app.state.core.offline_media.media_playback._catalog

    def hold_after_catalog(*args, **kwargs):
        value = original_catalog(*args, **kwargs)
        _hold(app)
        return value

    monkeypatch.setattr(
        app.state.core.offline_media.media_playback,
        "_catalog",
        hold_after_catalog,
    )
    raced = client.post(
        BASE + "/grants",
        headers=auth(pair),
        json=create_body(installation, current, request_id="0" * 32),
    )
    assert raced.status_code == 503
    assert raced.json()["error"]["code"] == "power_recovery_held"
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT 1 FROM offline_media_grants WHERE id=?", ("0" * 32,)
        ).fetchone() is None


def test_hold_wins_same_database_race_before_first_transfer(server, monkeypatch):
    app, client, _settings, _clock = server
    _isolate_offline_drain(monkeypatch)
    pair, installation, current, worker = setup(server)
    grant = "2" * 32
    assert client.post(
        BASE + "/grants",
        headers=auth(pair),
        json=create_body(installation, current, request_id=grant),
    ).status_code == 201
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    started = threading.Event()
    outcome = []

    def read():
        started.set()
        try:
            app.state.core.offline_media.chunk(
                actor,
                grant,
                ReadOfflineMediaChunkRequest.model_validate(_chunk(grant)),
            )
        except Exception as error:
            outcome.append(error)

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE power_recovery_state SET gate_state='held' WHERE id=1"
        )
        thread = threading.Thread(target=read)
        thread.start()
        assert started.wait(1)
        assert worker.calls == []
    thread.join(2)

    assert not thread.is_alive()
    assert len(outcome) == 1
    assert getattr(outcome[0], "code", None) == "power_recovery_held"
    assert worker.calls == []
    assert _active(app) is False


class _BlockingWorker:
    def __init__(self):
        self.entered = threading.Event()
        self.release = threading.Event()
        self.calls = 0

    def read_offline_media_chunk(
        self, authority, *, request_id, offset, length, deadline, gate
    ):
        assert gate() is True
        self.calls += 1
        self.entered.set()
        assert self.release.wait(2)
        return OfflineMediaChunkReadback(
            itemId=authority.itemId,
            offset=offset,
            contentLength=len(CONTENT),
            contentType="video/mp4",
            dataBase64=base64.b64encode(
                CONTENT[offset:offset + min(length, 4)]
            ).decode(),
        )


def test_admitted_io_is_durable_drain_work_across_hold_and_restart(
    server, monkeypatch
):
    app, client, settings, clock = server
    _isolate_offline_drain(monkeypatch)
    worker = _BlockingWorker()
    pair, installation, current, _unused = setup(server, worker=worker)
    grant = "3" * 32
    assert client.post(
        BASE + "/grants",
        headers=auth(pair),
        json=create_body(installation, current, request_id=grant),
    ).status_code == 201
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    outcome = []

    thread = threading.Thread(
        target=lambda: outcome.append(
            app.state.core.offline_media.chunk(
                actor,
                grant,
                ReadOfflineMediaChunkRequest.model_validate(_chunk(grant)),
            )
        )
    )
    thread.start()
    assert worker.entered.wait(1)
    _hold(app)
    assert _active(app) is True

    restarted = create_app(settings)
    assert _active(restarted) is True
    drain = _queue_drain(app, int(clock()))
    assert app.state.core.power_recovery.tick() is False
    assert _step(app, drain) == {"state": "queued", "result_code": "pending"}

    worker.release.set()
    thread.join(2)
    assert not thread.is_alive()
    assert outcome[0][0] == CONTENT[:4]

    progress = client.post(
        BASE + f"/grants/{grant}/progress",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": "4" * 32,
            "expectedRevision": 1,
            "downloadedBytes": 4,
            "contentSha256": None,
        },
    )
    assert progress.status_code == 200
    assert progress.json()["manifest"]["state"] == "transferring"
    assert progress.json()["manifest"]["revision"] == 2
    second = client.post(
        BASE + f"/grants/{grant}/chunk",
        headers=auth(pair),
        json=_chunk(grant, revision=2, offset=4, request="a" * 32),
    )
    assert second.status_code == 200
    assert second.content == CONTENT[4:]
    complete = client.post(
        BASE + f"/grants/{grant}/progress",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": "b" * 32,
            "expectedRevision": 2,
            "downloadedBytes": len(CONTENT),
            "contentSha256": hashlib.sha256(CONTENT).hexdigest(),
        },
    )
    assert complete.status_code == 200
    assert complete.json()["manifest"]["state"] == "complete"
    assert _active(app) is False
    assert app.state.core.power_recovery.tick() is True
    assert _step(app, drain) == {
        "state": "succeeded",
        "result_code": "no_active_work",
    }

    # An abandoned durable transfer blocks shutdown only until its bounded grant
    # expiry. Expiry never converts it into a successful download.
    _hold(app, False)
    abandoned = "5" * 32
    assert client.post(
        BASE + "/grants",
        headers=auth(pair),
        json=create_body(installation, current, request_id=abandoned),
    ).status_code == 201
    read = client.post(
        BASE + f"/grants/{abandoned}/chunk",
        headers=auth(pair),
        json=_chunk(abandoned, request="6" * 32),
    )
    assert read.status_code == 200
    _hold(app)
    assert _active(app) is True
    clock.now = 1788613200
    assert _active(app) is False


def test_revoke_releases_durable_drain_without_replaying_worker(
    server, monkeypatch
):
    app, client, _settings, _clock = server
    _isolate_offline_drain(monkeypatch)
    pair, installation, current, worker = setup(server)
    grant = "7" * 32
    assert client.post(
        BASE + "/grants",
        headers=auth(pair),
        json=create_body(installation, current, request_id=grant),
    ).status_code == 201
    assert client.post(
        BASE + f"/grants/{grant}/chunk",
        headers=auth(pair),
        json=_chunk(grant, request="8" * 32),
    ).status_code == 200
    _hold(app)
    assert _active(app) is True

    revoked = client.post(
        BASE + f"/grants/{grant}/revoke",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": "9" * 32,
            "expectedRevision": 1,
        },
    )
    assert revoked.status_code == 200
    assert revoked.json()["manifest"]["state"] == "revoked"
    assert _active(app) is False
    assert len(worker.calls) == 1


def test_actual_inflight_io_survives_expiry_and_revoke_in_drain(server, monkeypatch):
    app, client, _settings, clock = server
    _isolate_offline_drain(monkeypatch)
    worker = _BlockingWorker()
    pair, installation, current, _unused = setup(server, worker=worker)
    grant = "c" * 32
    body = {
        **create_body(installation, current, request_id=grant),
        "expiresAt": 1788610200,
    }
    assert client.post(
        BASE + "/grants",
        headers=auth(pair),
        json=body,
    ).status_code == 201
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    outcome = []

    def read():
        try:
            outcome.append(app.state.core.offline_media.chunk(
                actor,
                grant,
                ReadOfflineMediaChunkRequest.model_validate(
                    _chunk(grant, request="d" * 32)),
            ))
        except Exception as error:
            outcome.append(error)

    thread = threading.Thread(target=read)
    thread.start()
    assert worker.entered.wait(1)
    _hold(app)
    clock.now = body["expiresAt"]
    revoked = client.post(
        BASE + f"/grants/{grant}/revoke",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": "e" * 32,
            "expectedRevision": 1,
        },
    )
    assert revoked.status_code == 200
    assert revoked.json()["manifest"]["state"] == "revoked"
    # Durable grant state no longer accounts for this operation; only the
    # exact process-local worker flight keeps orderly shutdown blocked.
    assert _active(app) is True

    worker.release.set()
    thread.join(2)
    assert not thread.is_alive()
    assert getattr(outcome[0], "code", None) == "media_playback_worker_unavailable"
    assert _active(app) is False


def test_first_transfer_rollback_releases_process_activity(server, monkeypatch):
    app, client, _settings, _clock = server
    _isolate_offline_drain(monkeypatch)
    pair, installation, current, worker = setup(server)
    grant = "f" * 32
    assert client.post(
        BASE + "/grants",
        headers=auth(pair),
        json=create_body(installation, current, request_id=grant),
    ).status_code == 201
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    offline = app.state.core.offline_media
    transaction = offline.db.transaction

    @contextmanager
    def fail_before_commit():
        with transaction() as connection:
            yield connection
            raise RuntimeError("synthetic admission rollback")

    monkeypatch.setattr(offline.db, "transaction", fail_before_commit)
    with pytest.raises(RuntimeError, match="synthetic admission rollback"):
        offline.chunk(
            actor,
            grant,
            ReadOfflineMediaChunkRequest.model_validate(
                _chunk(grant, request="0" * 32)),
        )

    assert offline.power_recovery_active() is False
    assert worker.calls == []
    with transaction() as connection:
        row = connection.execute(
            "SELECT state FROM offline_media_grants WHERE id=?", (grant,)
        ).fetchone()
    assert row["state"] == "granted"


def test_active_work_provider_registration_is_bounded_and_fails_closed(
    server, monkeypatch
):
    app, _client, _settings, clock = server
    _isolate_offline_drain(monkeypatch)
    recovery = app.state.core.power_recovery
    before = len(recovery._active_work_providers)

    def unavailable():
        raise RuntimeError("synthetic observer failure")

    recovery.register_active_work(unavailable)
    recovery.register_active_work(unavailable)
    assert len(recovery._active_work_providers) == before + 1
    assert _active(app) is True
    drain = _queue_drain(app, int(clock()))
    assert recovery.tick() is False
    assert _step(app, drain) == {"state": "queued", "result_code": "pending"}

    additions = []
    while len(recovery._active_work_providers) < 16:
        additions.append(lambda: False)
        recovery.register_active_work(additions[-1])
    with pytest.raises(StartupError, match="power_recovery_provider_invalid"):
        recovery.register_active_work(lambda: False)


@pytest.mark.parametrize("invalid", [None, 1])
def test_invalid_active_work_observation_fails_drain_closed(
    server, monkeypatch, invalid
):
    app, _client, _settings, clock = server
    _isolate_offline_drain(monkeypatch)
    recovery = app.state.core.power_recovery
    recovery.register_active_work(lambda: invalid)

    drain = _queue_drain(app, int(clock()))
    assert recovery.tick() is False
    assert _step(app, drain) == {"state": "queued", "result_code": "pending"}
