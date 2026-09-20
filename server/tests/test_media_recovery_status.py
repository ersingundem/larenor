"""S06.6 verified media results and durable recovery projection."""

import json
from types import SimpleNamespace

from fastapi.testclient import TestClient

from conftest import auth, login
from larenor_server.app import create_app
from test_music_assistant_bootstrap_jobs import (
    Backend as MusicAssistantBackend,
    ready as music_assistant_ready,
    request as music_assistant_request,
)
from test_qbittorrent_config_jobs import (
    Backend as QbittorrentBackend,
    queue as queue_qbittorrent,
)
from test_seerr_bootstrap_dispatch import Backend as SeerrBackend
from test_seerr_bootstrap_jobs import (
    ready_stack as seerr_ready_stack,
    request as seerr_request,
)
from test_music_assistant_core_wiring import authenticated_peer


BASE = "/api/v1/admin/media/recovery-status"


def _service(document, service_id):
    return next(item for item in document["services"]
                if item["serviceId"] == service_id)


def test_container_receipt_is_distinct_from_verified_music_assistant_result(server):
    app, client, _, _ = server
    pair, _, installation = music_assistant_ready(server)

    container_only = client.get(BASE, headers=auth(pair))
    assert container_only.status_code == 200
    assert _service(container_only.json(), "music_assistant") == {
        "serviceId": "music_assistant",
        "sourceId": installation["id"],
        "sourceKind": "installation",
        "revision": installation["revision"],
        "resultState": "partial",
        "containerState": "started",
        "serviceState": "unverified",
        "recoveryAction": "configure",
        "automaticRetry": False,
        "errorCode": None,
        "updatedAt": installation["updatedAt"],
    }

    app.state.core.music_assistant_bootstraps.backend = MusicAssistantBackend()
    queued = client.post(
        "/api/v1/admin/media/music-assistant-bootstraps",
        headers=auth(pair), json=music_assistant_request(installation),
    )
    assert queued.status_code == 201
    terminal = app.state.core.music_assistant_bootstraps.tick()["bootstrap"]
    assert terminal["state"] == "succeeded"

    verified = _service(client.get(BASE, headers=auth(pair)).json(),
                        "music_assistant")
    assert verified == {
        "serviceId": "music_assistant",
        "sourceId": terminal["id"],
        "sourceKind": "bootstrap",
        "revision": terminal["revision"],
        "resultState": "verified",
        "containerState": "started",
        "serviceState": "verified",
        "recoveryAction": "none",
        "automaticRetry": False,
        "errorCode": None,
        "updatedAt": terminal["updatedAt"],
    }
    assert "private-managed-music-assistant-token" not in json.dumps(verified)

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "DELETE FROM music_assistant_core WHERE installation_id=?",
            (installation["id"],),
        )
    missing_readback = _service(
        client.get(BASE, headers=auth(pair)).json(), "music_assistant")
    assert missing_readback["resultState"] == "partial"
    assert missing_readback["serviceState"] == "unverified"
    assert missing_readback["recoveryAction"] == "review"


def test_uncertain_cancellation_is_retained_idempotently_across_restart(server):
    app, client, settings, _ = server
    pair, _, queued, backend = queue_qbittorrent(server)
    backend.action = lambda: client.post(
        "/api/v1/admin/media/qbittorrent-configurations/"
        + queued["id"] + "/cancel",
        headers=auth(pair), json={"expectedRevision": 2},
    )
    terminal = app.state.core.qbittorrent_configurations.tick()["configuration"]
    assert terminal["state"] == "needs_attention"

    before = client.get(BASE, headers=auth(pair))
    assert before.status_code == 200
    result = _service(before.json(), "qbittorrent")
    assert result["sourceId"] == terminal["id"]
    assert result["resultState"] == "needs_attention"
    assert result["recoveryAction"] == "review"
    assert result["automaticRetry"] is False
    assert result["errorCode"] == "qbittorrent_config_cancellation_uncertain"

    with app.state.core.db.connection() as connection:
        count = connection.execute(
            "SELECT COUNT(*) FROM media_qbittorrent_configurations"
        ).fetchone()[0]
    with TestClient(create_app(settings)) as restarted:
        first = restarted.get(BASE, headers=auth(pair))
        second = restarted.get(BASE, headers=auth(pair))
        assert first.status_code == 200 and first.json() == before.json()
        assert second.json() == first.json()
        with restarted.app.state.core.db.connection() as connection:
            assert connection.execute(
                "SELECT COUNT(*) FROM media_qbittorrent_configurations"
            ).fetchone()[0] == count


def test_authority_loss_has_no_worker_effect_and_result_stays_secret_free(server):
    app, client, settings, _ = server
    pair, _, queued, backend = queue_qbittorrent(
        server, backend=QbittorrentBackend())
    with app.state.core.db.connection() as connection:
        connection.execute(
            "UPDATE session_families SET revoked_at=?",
            (int(settings.clock()),),
        )

    terminal = app.state.core.qbittorrent_configurations.tick()["configuration"]
    assert terminal["state"] == "needs_attention"
    assert terminal["errorCode"] == "qbittorrent_config_authority_changed"
    assert backend.calls == []
    assert client.get(BASE, headers=auth(pair)).status_code == 401

    replacement = login(
        client, "admin", "Synthetic new password 2026", "Recovery tablet"
    ).json()
    response = client.get(BASE, headers=auth(replacement))
    assert response.status_code == 200
    result = _service(response.json(), "qbittorrent")
    assert result["sourceId"] == queued["id"]
    assert result["resultState"] == "needs_attention"
    assert result["serviceState"] == "unverified"
    assert result["recoveryAction"] == "review"
    assert result["errorCode"] == "qbittorrent_config_authority_changed"
    encoded = json.dumps(response.json())
    assert "credential" not in encoded and "apiKey" not in encoded


def test_projection_covers_all_six_managed_services_from_durable_readbacks(server):
    app, client, _, _ = server
    pair, jellyfin_bootstrap, seerr_installation = seerr_ready_stack(server)

    app.state.core.seerr_bootstraps.backend = SeerrBackend()
    queued_seerr = client.post(
        "/api/v1/admin/media/seerr-bootstraps", headers=auth(pair),
        json=seerr_request(jellyfin_bootstrap, seerr_installation),
    )
    assert queued_seerr.status_code == 201
    assert app.state.core.seerr_bootstraps.tick()["bootstrap"]["state"] == (
        "succeeded")

    with app.state.core.db.connection() as connection:
        seerr_row = connection.execute(
            "SELECT * FROM media_installations WHERE id=?",
            (seerr_installation["id"],),
        ).fetchone()
        installation_request = app.state.core.media_installations._decode(
            seerr_row).request.model_dump(mode="json")
    queued_music = client.post(
        "/api/v1/admin/media/installations", headers=auth(pair),
        json=installation_request | {
            "requestId": "9" * 32, "serviceId": "music_assistant"},
    )
    assert queued_music.status_code == 201, queued_music.text
    music_installation = app.state.core.media_installations.tick()["installation"]
    assert music_installation["state"] == "container_started"

    authenticated_peer(server, pair, "home_assistant")
    authenticated_peer(server, pair, "jellyfin")
    app.state.core.music_assistant_bootstraps.backend = MusicAssistantBackend()
    queued_music_bootstrap = client.post(
        "/api/v1/admin/media/music-assistant-bootstraps",
        headers=auth(pair), json=music_assistant_request(music_installation),
    )
    assert queued_music_bootstrap.status_code == 201
    assert app.state.core.music_assistant_bootstraps.tick()["bootstrap"]["state"] == (
        "succeeded")

    response = client.get(BASE, headers=auth(pair))
    assert response.status_code == 200
    document = response.json()
    assert [item["serviceId"] for item in document["services"]] == [
        "qbittorrent", "sonarr", "radarr", "jellyfin", "seerr",
        "music_assistant",
    ]
    projected = {item["serviceId"]: item for item in document["services"]}
    assert all(projected[item]["resultState"] == "verified" for item in (
        "qbittorrent", "sonarr", "radarr", "seerr", "music_assistant"))
    assert projected["jellyfin"]["resultState"] == "partial"
    assert projected["jellyfin"]["serviceState"] == "verified"
    assert projected["jellyfin"]["recoveryAction"] == "review"
    assert document["state"] == "incomplete"
    encoded = json.dumps(document)
    for private_name in ("credential", "apiKey", "token", "baseUrl"):
        assert private_name not in encoded


def test_failed_bootstrap_cannot_reuse_stale_authenticated_readback(server):
    app, client, _, _ = server
    pair, jellyfin_bootstrap, _ = seerr_ready_stack(server)
    manager = app.state.core.media_service_bootstraps
    with manager.db.transaction() as connection:
        row = manager._find(connection, jellyfin_bootstrap["id"])
        private = manager._decode(row)
        assert private.readback is not None
        changed = dict(row)
        changed.update(
            revision=row["revision"] + 1, state="needs_attention",
            error_code="bootstrap_wiring_failed",
            updated_at=row["updated_at"] + 1,
        )
        manager._save(connection, changed, private)

    result = _service(client.get(BASE, headers=auth(pair)).json(), "jellyfin")
    assert result["resultState"] == "needs_attention"
    assert result["serviceState"] == "unverified"
    assert result["recoveryAction"] == "review"


def test_unknown_future_installation_service_fails_closed(server, monkeypatch):
    app, client, _, _ = server
    pair, _, installation = music_assistant_ready(server)
    manager = app.state.core.media_installations
    original = manager._decode

    def widened(row):
        decoded = original(row)
        if row["id"] == installation["id"]:
            return SimpleNamespace(
                request=SimpleNamespace(serviceId="future_media_service"))
        return decoded

    monkeypatch.setattr(manager, "_decode", widened)
    response = client.get(BASE, headers=auth(pair))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == (
        "media_installation_storage_unavailable")
