import json
import sqlite3
import threading
from unittest import mock

import pytest
from pydantic import ValidationError

from conftest import auth, login
from larenor_server.longform_sessions.models import UpdateLongformSessionRequest
from larenor_server.longform_sessions.service import LongformSessionService
from larenor_server.longform_sessions.schema import migrate_longform_sessions
from larenor_server.plugins.music_playback_models import (
    MusicLongformChapter,
    MusicLongformItem,
    MusicLongformWorkerResult,
)
from test_music_manager_api import MANAGER, ready_manager
from test_music_playback import BASE as PLAYBACK_BASE, player, queue


MEDIA_URI = "audiobookshelf://audiobook/book-one"
SESSIONS = "/api/v1/media/longform/sessions"


def _enforce_timer_worker_media(worker):
    """Give the owned fixture the production worker's exact-media contract."""
    execute = worker.execute_music_playback

    def guarded(action, *, deadline, gate):
        expected = action.expectedCurrentItemUri
        observed = next((item for item in worker.queues
                         if item.queueId == action.request.expectedQueueId), None)
        if (expected is not None
                and (observed is None or not observed.active
                     or observed.currentItemUri != expected)):
            raise RuntimeError("fixture_music_queue_readback_changed")
        result = execute(action, deadline=deadline, gate=gate)
        return (result if expected is None
                else result.model_copy(update={"queue": observed}))

    worker.execute_music_playback = guarded


def _longform(provider):
    return MusicLongformWorkerResult(items=[MusicLongformItem(
        uri=MEDIA_URI, name="Book One", mediaType="audiobook",
        providerInstanceId=provider, durationSeconds=3600,
        resumePositionSeconds=900, fullyPlayed=False,
        chapters=[MusicLongformChapter(
            position=0, name="Opening", startSeconds=0, endSeconds=600)],
    )])


def _ready(server):
    app, client, _, _ = server
    pair, setup, readiness, worker, manager = ready_manager(server)
    _enforce_timer_worker_media(worker)
    worker.players = [player().model_copy(update={"playbackState": "playing"})]
    worker.queues = [queue(current=MEDIA_URI, position=900)]
    refreshed = client.post(MANAGER + "/refresh", headers=auth(pair), json={
        "requestId": "2" * 32,
        "installationId": setup["installationId"],
        "expectedInstallationRevision": setup["installationRevision"],
        "expectedCoreRevision": readiness["revision"],
    })
    assert refreshed.status_code == 200, refreshed.text
    manager = refreshed.json()["manager"]
    provider = manager["providers"][0]["providerInstanceId"]
    worker.read_music_longform = lambda _action, **_kwargs: _longform(provider)
    opened = client.post(SESSIONS + "/open", headers=auth(pair), json={
        "schemaVersion": 2, "requestId": "3" * 32,
        "installationId": setup["installationId"],
        "expectedInstallationRevision": setup["installationRevision"],
        "expectedCoreRevision": readiness["revision"],
        "expectedManagerRevision": manager["revision"], "limit": 25,
        "mediaUri": MEDIA_URI, "providerInstanceId": provider,
        "takeover": False,
    })
    assert opened.status_code == 201, opened.text
    return pair, setup, readiness, worker, manager, opened.json()["session"]


def _schedule(server, prepared, *, request="4", seconds=60):
    pair, setup, readiness, _worker, manager, session = prepared
    deadline = int(server[3].now) + seconds
    response = server[1].post(
        SESSIONS + "/" + session["sessionId"], headers=auth(pair), json={
            "schemaVersion": 2, "requestId": request * 32,
            "installationId": setup["installationId"],
            "expectedInstallationRevision": setup["installationRevision"],
            "expectedCoreRevision": readiness["revision"],
            "expectedManagerRevision": manager["revision"], "limit": 25,
            "mediaUri": MEDIA_URI,
            "providerInstanceId": session["providerInstanceId"],
            "takeover": False, "expectedRevision": session["revision"],
            "positionSeconds": session["positionSeconds"],
            "playbackState": "playing", "sleepTimerEndsAt": deadline,
            "sleepTimerTarget": {
                "targetId": "homepod-living",
                "expectedProvider": "airplay--main",
                "expectedTargetKind": "homepod",
                "expectedQueueId": "homepod-living",
                "expectedGroupMembers": [],
            },
            "bookmarks": [],
        })
    assert response.status_code == 200, response.text
    return response.json()["session"]


def test_deadline_dispatches_one_authority_bound_pause_with_readback(server):
    prepared = _ready(server)
    worker = prepared[3]
    scheduled = _schedule(server, prepared)
    assert scheduled["sleepTimerState"] == "scheduled"
    assert scheduled["sleepTimerTargetId"] == "homepod-living"
    assert worker.calls == []

    server[3].now += 60
    assert server[0].state.core.longform_sessions.tick() is True
    assert len(worker.calls) == 1
    assert worker.calls[0].request.operation == "pause"
    assert worker.calls[0].request.targetId == "homepod-living"
    with server[0].state.core.db.connection() as connection:
        timer = connection.execute(
            "SELECT * FROM longform_sleep_timers").fetchone()
        assert timer["state"] == "succeeded"
        assert timer["outcome"] == "authenticated_readback"
    assert server[0].state.core.longform_sessions.tick() is False
    assert len(worker.calls) == 1


def test_cancelled_or_revoked_timer_performs_no_device_io(server):
    prepared = _ready(server)
    pair, setup, readiness, worker, manager, _ = prepared
    scheduled = _schedule(server, prepared)
    cleared = server[1].post(
        SESSIONS + "/" + scheduled["sessionId"], headers=auth(pair), json={
            "schemaVersion": 2, "requestId": "5" * 32,
            "installationId": setup["installationId"],
            "expectedInstallationRevision": setup["installationRevision"],
            "expectedCoreRevision": readiness["revision"],
            "expectedManagerRevision": manager["revision"], "limit": 25,
            "mediaUri": MEDIA_URI,
            "providerInstanceId": scheduled["providerInstanceId"],
            "takeover": False, "expectedRevision": scheduled["revision"],
            "positionSeconds": scheduled["positionSeconds"],
            "playbackState": "playing", "sleepTimerEndsAt": None,
            "sleepTimerTarget": None, "bookmarks": [],
        })
    assert cleared.status_code == 200, cleared.text
    assert cleared.json()["session"]["sleepTimerState"] == "cancelled"
    server[3].now += 60
    assert server[0].state.core.longform_sessions.tick() is False
    assert worker.calls == []

    # A second timer loses authority when its session family is revoked.
    current = cleared.json()["session"]
    prepared = pair, setup, readiness, worker, manager, current
    _schedule(server, prepared, request="6")
    with server[0].state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE session_families SET revoked_at=? WHERE id=?",
            (server[3].now, pair["sessionFamilyId"]),
        )
    server[3].now += 60
    assert server[0].state.core.longform_sessions.tick() is False
    assert worker.calls == []
    with server[0].state.core.db.connection() as connection:
        timer = connection.execute(
            "SELECT * FROM longform_sleep_timers ORDER BY generation DESC LIMIT 1"
        ).fetchone()
        assert (timer["state"], timer["outcome"]) == (
            "cancelled", "authority_retired")


def test_lost_ack_is_unknown_and_never_redispatched_after_restart(server):
    prepared = _ready(server)
    worker = prepared[3]
    _schedule(server, prepared)
    calls = []

    def lost(action, *, deadline, gate):
        assert gate() is True
        calls.append(action.request.requestId)
        raise TimeoutError("fixture lost response")

    worker.execute_music_playback = lost
    server[3].now += 60
    assert server[0].state.core.longform_sessions.tick() is False
    assert len(calls) == 1
    assert server[0].state.core.longform_sessions.tick() is False
    assert len(calls) == 1

    core = server[0].state.core
    restarted = LongformSessionService(
        core.db, core.auth, core.settings,
        core.longform_sessions._key, core.context, core.music_playback,
    )
    restarted.validate_storage()
    assert restarted.tick() is False
    assert len(calls) == 1
    with core.db.connection() as connection:
        timer = connection.execute(
            "SELECT * FROM longform_sleep_timers").fetchone()
        assert (timer["state"], timer["outcome"]) == (
            "needs_attention", "effect_unknown")
        stored = core.music_playback._decode(connection.execute(
            "SELECT * FROM music_playback").fetchone())
        commands = [item for item in stored.commands
                    if item.request.requestId == timer["id"]]
        assert len(commands) == 1 and commands[0].state == "pending"
    assert "private-mass-token" not in json.dumps(calls)


@pytest.mark.parametrize("lost_ack", [False, True])
def test_takeover_during_pause_preserves_dispatch_outcome(server, lost_ack):
    prepared = _ready(server)
    _pair, setup, readiness, worker, manager, session = prepared
    _schedule(server, prepared)
    successor = login(
        server[1], "admin", "Synthetic new password 2026", "Timer successor"
    ).json()
    execute = worker.execute_music_playback
    effect_crossed = threading.Event()
    release_receipt = threading.Event()
    tick_outcomes = []
    tick_failures = []

    def pause_then_takeover(action, *, deadline, gate):
        result = execute(action, deadline=deadline, gate=gate)
        effect_crossed.set()
        assert release_receipt.wait(5)
        if lost_ack:
            raise TimeoutError("fixture response lost after pause")
        return result

    service = server[0].state.core.longform_sessions
    real_tick = service.tick

    def dispatch():
        try:
            tick_outcomes.append(real_tick())
        except BaseException as error:
            tick_failures.append(error)

    worker.execute_music_playback = pause_then_takeover
    dispatch_thread = threading.Thread(target=dispatch, daemon=True)
    server[3].now += 60
    # The lifespan dispatcher uses the public tick attribute every second.
    # Hold it on a no-op while this test's owned thread drives the exact
    # dispatch window, avoiding a race between two otherwise valid callers.
    with mock.patch.object(service, "tick", return_value=False):
        dispatch_thread.start()
        assert effect_crossed.wait(5)
        # A successor's newly authorized catalog is independent of the original
        # family's provider snapshot. Read the current pending-command revision
        # and let the real catalog guard prove that authority before takeover.
        try:
            current = server[1].get(
                PLAYBACK_BASE + "/" + setup["installationId"],
                headers=auth(successor),
            )
            assert current.status_code == 200, current.text
            takeover_body = {
                "schemaVersion": 2, "requestId": "a" * 32,
                "installationId": setup["installationId"],
                "expectedInstallationRevision": setup[
                    "installationRevision"],
                "expectedCoreRevision": readiness["revision"],
                "expectedManagerRevision": current.json()["playback"][
                    "revision"],
                "limit": 25,
                "mediaUri": MEDIA_URI,
                "providerInstanceId": session["providerInstanceId"],
                "takeover": True,
            }
            response = server[1].post(
                SESSIONS + "/open", headers=auth(successor),
                json=takeover_body,
            )
        finally:
            release_receipt.set()
            dispatch_thread.join(5)

    assert not dispatch_thread.is_alive()
    assert tick_failures == []
    assert tick_outcomes == [not lost_ack]
    assert response.status_code == 409, response.text
    assert response.json()["error"]["code"] == (
        "longform_sleep_timer_dispatch_in_progress")
    assert len(worker.calls) == 1
    with server[0].state.core.db.connection() as connection:
        timer = connection.execute(
            "SELECT * FROM longform_sleep_timers").fetchone()
        assert (timer["state"], timer["outcome"]) == (
            ("needs_attention", "effect_unknown") if lost_ack
            else ("succeeded", "authenticated_readback"))
        current = connection.execute(
            "SELECT * FROM longform_sessions").fetchone()
        assert current["family_id"] != successor["sessionFamilyId"]
    assert server[0].state.core.longform_sessions.tick() is False
    assert len(worker.calls) == 1

    # Once the terminal outcome is durable, an authorized successor can take
    # over from a fresh provider snapshot without changing that outcome or
    # replaying the old pause.
    current = server[1].get(
        PLAYBACK_BASE + "/" + setup["installationId"],
        headers=auth(successor),
    )
    assert current.status_code == 200, current.text
    takeover_body["expectedManagerRevision"] = current.json()["playback"][
        "revision"]
    takeover = server[1].post(
        SESSIONS + "/open", headers=auth(successor), json=takeover_body,
    )
    assert takeover.status_code == 201, takeover.text
    terminal = takeover.json()["session"]
    assert terminal["ownedByCurrentSession"] is True
    assert terminal["sleepTimerState"] == (
        "needs_attention" if lost_ack else "enforced")
    assert terminal["sleepTimerCode"] == (
        "effect_unknown" if lost_ack else "authenticated_readback")
    assert len(worker.calls) == 1


def test_fresh_provider_media_drift_fails_closed_before_pause(server):
    prepared = _ready(server)
    worker = prepared[3]
    _schedule(server, prepared)
    core = server[0].state.core
    # The persisted Core snapshot still names MEDIA_URI. Only the provider's
    # fresh queue changes before the deadline.
    worker.queues = [queue(current="spotify://track/unrelated")]
    server[3].now += 60

    assert core.longform_sessions.tick() is False
    assert worker.calls == []
    with core.db.connection() as connection:
        timer = connection.execute(
            "SELECT * FROM longform_sleep_timers").fetchone()
        assert timer["state"] == "needs_attention"


def test_unchanged_timer_keeps_identity_during_last_minute_progress(server):
    prepared = _ready(server)
    pair, setup, readiness, worker, manager, _ = prepared
    scheduled = _schedule(server, prepared)
    with server[0].state.core.db.connection() as connection:
        timer_id = connection.execute(
            "SELECT id FROM longform_sleep_timers").fetchone()["id"]
    server[3].now += 30

    response = server[1].post(
        SESSIONS + "/" + scheduled["sessionId"], headers=auth(pair), json={
            "schemaVersion": 2, "requestId": "9" * 32,
            "installationId": setup["installationId"],
            "expectedInstallationRevision": setup["installationRevision"],
            "expectedCoreRevision": readiness["revision"],
            "expectedManagerRevision": manager["revision"], "limit": 25,
            "mediaUri": MEDIA_URI,
            "providerInstanceId": scheduled["providerInstanceId"],
            "takeover": False, "expectedRevision": scheduled["revision"],
            "positionSeconds": scheduled["positionSeconds"] + 1,
            "playbackState": "playing",
            "sleepTimerEndsAt": scheduled["sleepTimerEndsAt"],
            "sleepTimerTarget": {
                "targetId": "homepod-living",
                "expectedProvider": "airplay--main",
                "expectedTargetKind": "homepod",
                "expectedQueueId": "homepod-living",
                "expectedGroupMembers": [],
            },
            "bookmarks": [],
        })

    assert response.status_code == 200, response.text
    with server[0].state.core.db.connection() as connection:
        timer = connection.execute(
            "SELECT * FROM longform_sleep_timers WHERE state='pending'"
        ).fetchone()
        assert timer["id"] == timer_id
        assert timer["session_revision"] == response.json()["session"]["revision"]
    assert worker.calls == []
    server[3].now += 30
    assert server[0].state.core.longform_sessions.tick() is True
    assert len(worker.calls) == 1


@pytest.mark.parametrize("version", [1, True, "2"])
def test_v2_request_rejects_legacy_or_non_integer_schema(version):
    with pytest.raises(ValidationError):
        UpdateLongformSessionRequest.model_validate({
            "schemaVersion": version, "requestId": "9" * 32,
            "installationId": "1" * 32,
            "expectedInstallationRevision": 1,
            "expectedCoreRevision": 1, "expectedManagerRevision": 1,
            "limit": 25, "mediaUri": MEDIA_URI,
            "providerInstanceId": "spotify--fixture", "takeover": False,
            "expectedRevision": 1, "positionSeconds": 1,
            "playbackState": "playing", "sleepTimerEndsAt": None,
            "sleepTimerTarget": None, "bookmarks": [],
        })


def test_v1_migration_preserves_existing_session_rows_and_adds_empty_journal():
    connection = sqlite3.connect(":memory:")
    connection.row_factory = sqlite3.Row
    connection.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)")
    migrate_longform_sessions(connection)
    connection.execute(
        "INSERT INTO longform_sessions VALUES(" + ",".join("?" for _ in range(23)) + ")",
        (
            "1" * 32, "2" * 32, "3" * 32, 1, 7, "4" * 64,
            "5" * 32, 2, 3, 4, "provider", MEDIA_URI, "audiobook",
            "Book", 3600.0, 900.0, "playing", 1788611400, "[]",
            "6" * 32, "7" * 64, 1788609600, "8" * 64,
        ),
    )
    connection.execute("DROP TABLE longform_sleep_timers")
    connection.execute(
        "UPDATE metadata SET value='1' WHERE key='longform_session_schema'"
    )

    migrate_longform_sessions(connection)

    assert connection.execute(
        "SELECT COUNT(*) FROM longform_sessions").fetchone()[0] == 1
    assert connection.execute(
        "SELECT sleep_ends_at FROM longform_sessions").fetchone()[0] == 1788611400
    assert connection.execute(
        "SELECT COUNT(*) FROM longform_sleep_timers").fetchone()[0] == 0
    assert connection.execute(
        "SELECT value FROM metadata WHERE key='longform_session_schema'"
    ).fetchone()[0] == "2"
