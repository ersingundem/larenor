"""Durable, secret-safe Music Assistant bootstrap jobs."""

import time

from fastapi.testclient import TestClient

from conftest import auth
from larenor_server.app import create_app
from larenor_server.plugins.music_assistant_core_models import (
    AuthenticatedMusicAssistantReadback,
)
from test_media_installations_api import ExecutionBackend, prepared
from test_music_assistant_core_wiring import authenticated_peer


BASE = "/api/v1/admin/media/music-assistant-bootstraps"
TOKEN = "private-managed-music-assistant-token"


class Backend:
    def __init__(self):
        self.calls = []

    def bootstrap_music_assistant(self, private, *, deadline, gate):
        self.calls.append((private, deadline, gate))
        assert deadline > time.monotonic() and gate() is True
        return AuthenticatedMusicAssistantReadback(
            token=TOKEN,
            serverId="mass-managed-fixture",
            serverVersion="2.10.4",
            schemaVersion=65,
        )


def ready(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()
    queued = client.post(
        "/api/v1/admin/media/installations",
        headers=auth(pair),
        json=body | {"serviceId": "music_assistant"},
    ).json()["installation"]
    installed = app.state.core.media_installations.tick()["installation"]
    assert installed["state"] == "container_started"
    authenticated_peer(server, pair, "home_assistant")
    authenticated_peer(server, pair, "jellyfin")
    return pair, queued, installed


def request(installed, request_id="f" * 32):
    return {
        "requestId": request_id,
        "installationId": installed["id"],
        "expectedInstallationRevision": installed["revision"],
    }


def family_id(app, installation_id):
    with app.state.core.db.connection() as connection:
        return connection.execute(
            "SELECT family_id FROM media_installations WHERE id=?",
            (installation_id,),
        ).fetchone()[0]


def test_admin_queues_encrypted_idempotent_job_and_reads_it_after_restart(server):
    app, client, settings, _ = server
    pair, _, installed = ready(server)
    body = request(installed)

    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 201, response.text
    job = response.json()["bootstrap"]
    assert job["serviceId"] == "music_assistant"
    assert job["state"] == "queued" and job["phase"] == "queued"
    assert job["installAvailable"] is False
    assert client.post(BASE, headers=auth(pair), json=body).json() == response.json()

    private = app.state.core.music_assistant_bootstraps.private_payload(job["id"])
    assert private.installationId == installed["id"]
    assert len(private.credential) >= 32
    assert private.credential not in response.text + repr(private)
    with app.state.core.db.connection() as connection:
        stored = connection.execute(
            "SELECT ciphertext FROM media_music_assistant_bootstraps WHERE id=?",
            (job["id"],),
        ).fetchone()[0]
    assert private.credential.encode() not in stored
    injected = "S" * 48
    rejected = client.post(
        BASE,
        headers=auth(pair),
        json=request(installed, "e" * 32) | {"credential": injected},
    )
    assert rejected.status_code == 400 and injected not in rejected.text

    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(BASE + "/" + job["id"], headers=auth(pair)).json() == {
            "bootstrap": job
        }
        assert restarted.post(BASE, headers=auth(pair), json=body).json() == {
            "bootstrap": job
        }
        schema = restarted.get("/api/v1/openapi.json", headers=auth(pair)).text
        assert private.credential not in schema


def test_tick_records_core_readback_once_without_public_secret(server):
    app, client, settings, _ = server
    pair, _, installed = ready(server)
    backend = Backend()
    app.state.core.music_assistant_bootstraps.backend = backend
    queued = client.post(BASE, headers=auth(pair), json=request(installed)).json()[
        "bootstrap"
    ]

    terminal = app.state.core.music_assistant_bootstraps.tick()["bootstrap"]
    assert terminal == queued | {
        "revision": 3,
        "state": "succeeded",
        "phase": "complete",
    }
    assert len(backend.calls) == 1
    assert TOKEN not in repr(terminal) + repr(backend.calls[0][0])
    readiness = client.get(
        "/api/v1/admin/media/music-assistant/" + installed["id"],
        headers=auth(pair),
    )
    assert readiness.status_code == 200
    assert readiness.json()["readiness"]["serverVersion"] == "2.10.4"
    assert TOKEN not in readiness.text
    with app.state.core.db.connection() as connection:
        assert TOKEN not in "\n".join(connection.iterdump())
    assert app.state.core.music_assistant_bootstraps.tick() is None

    with TestClient(create_app(settings)) as restarted:
        stored = restarted.get(BASE + "/" + queued["id"], headers=auth(pair))
        assert stored.json()["bootstrap"] == terminal
        assert restarted.app.state.core.music_assistant_bootstraps.tick() is None


def test_revoked_authority_fails_closed_before_worker_dispatch(server):
    app, client, _, _ = server
    pair, _, installed = ready(server)
    backend = Backend()
    app.state.core.music_assistant_bootstraps.backend = backend
    queued = client.post(BASE, headers=auth(pair), json=request(installed)).json()[
        "bootstrap"
    ]
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE session_families SET revoked_at=? WHERE id=?",
            (int(time.time()), family_id(app, installed["id"])),
        )

    terminal = app.state.core.music_assistant_bootstraps.tick()["bootstrap"]
    assert terminal == queued | {
        "revision": 2,
        "state": "needs_attention",
        "phase": "complete",
        "errorCode": "music_assistant_bootstrap_authority_changed",
    }
    assert backend.calls == []
    assert app.state.core.music_assistant_bootstraps.tick() is None


def test_worker_effect_then_authority_change_never_records_core_readback(server):
    app, client, _, _ = server
    pair, _, installed = ready(server)
    backend = Backend()
    original = backend.bootstrap_music_assistant

    def revoke(*args, **kwargs):
        result = original(*args, **kwargs)
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE session_families SET revoked_at=? WHERE id=?",
                (int(time.time()), family_id(app, installed["id"])),
            )
        return result

    backend.bootstrap_music_assistant = revoke
    app.state.core.music_assistant_bootstraps.backend = backend
    queued = client.post(BASE, headers=auth(pair), json=request(installed)).json()[
        "bootstrap"
    ]
    terminal = app.state.core.music_assistant_bootstraps.tick()["bootstrap"]

    assert terminal["state"] == "needs_attention"
    assert terminal["errorCode"] == "music_assistant_bootstrap_authority_changed"
    assert len(backend.calls) == 1
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM music_assistant_core WHERE installation_id=?",
            (installed["id"],),
        ).fetchone()[0] == 0
