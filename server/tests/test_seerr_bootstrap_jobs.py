"""Durable encrypted Seerr bootstrap intent bound to its Jellyfin source."""

from fastapi.testclient import TestClient

from conftest import auth
from larenor_server.app import create_app
from test_media_installations_api import ExecutionBackend, prepared
from test_media_service_bootstraps import BootstrapBackend


BASE = "/api/v1/admin/media/seerr-bootstraps"


def ready_stack(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()

    jellyfin = client.post(
        "/api/v1/admin/media/installations", headers=auth(pair), json=body
    ).json()["installation"]
    jellyfin = app.state.core.media_installations.tick()["installation"]
    assert jellyfin["state"] == "container_started"

    app.state.core.media_service_bootstraps.backend = BootstrapBackend()
    source = client.post(
        "/api/v1/admin/media/bootstraps",
        headers=auth(pair),
        json={
            "requestId": "d" * 32,
            "installationId": jellyfin["id"],
            "expectedInstallationRevision": jellyfin["revision"],
        },
    ).json()["bootstrap"]
    source = app.state.core.media_service_bootstraps.tick()["bootstrap"]
    assert source["state"] == "wiring_partial"

    seerr = client.post(
        "/api/v1/admin/media/installations",
        headers=auth(pair),
        json=body | {"requestId": "e" * 32, "serviceId": "seerr"},
    ).json()["installation"]
    seerr = app.state.core.media_installations.tick()["installation"]
    assert seerr["state"] == "container_started"
    return pair, source, seerr


def request(source, seerr, request_id="f" * 32):
    return {
        "requestId": request_id,
        "installationId": seerr["id"],
        "expectedInstallationRevision": seerr["revision"],
        "sourceBootstrapId": source["id"],
        "expectedSourceBootstrapRevision": source["revision"],
    }


def test_admin_queues_encrypted_seerr_bootstrap_and_reads_it_after_restart(server):
    app, client, settings, _ = server
    pair, source, seerr = ready_stack(server)
    response = client.post(BASE, headers=auth(pair), json=request(source, seerr))
    assert response.status_code == 201, response.text
    record = response.json()["bootstrap"]
    assert record == {
        "id": record["id"],
        "requestId": "f" * 32,
        "installationId": seerr["id"],
        "sourceBootstrapId": source["id"],
        "sourceBootstrapRevision": source["revision"],
        "serviceId": "seerr",
        "revision": 1,
        "state": "queued",
        "phase": "queued",
        "errorCode": None,
        "installAvailable": False,
        "createdAt": "2026-09-05T12:00:00.000Z",
        "updatedAt": "2026-09-05T12:00:00.000Z",
    }
    private = app.state.core.seerr_bootstraps.private_payload(record["id"])
    assert private.sourceBootstrapId == source["id"]
    assert private.sourceBootstrapRevision == source["revision"]
    assert len(private.credential) >= 32
    assert private.credential not in response.text + repr(private)

    with app.state.core.db.connection() as connection:
        stored = connection.execute(
            "SELECT ciphertext FROM media_seerr_bootstraps"
        ).fetchone()[0]
    assert private.credential.encode() not in stored

    with TestClient(create_app(settings)) as reopened:
        assert reopened.get(
            BASE + "/" + record["id"], headers=auth(pair)
        ).json() == {"bootstrap": record}


def test_create_is_idempotent_but_rejects_source_or_revision_drift(server):
    app, client, _, _ = server
    pair, source, seerr = ready_stack(server)
    body = request(source, seerr)
    first = client.post(BASE, headers=auth(pair), json=body)
    assert first.status_code == 201
    assert client.post(BASE, headers=auth(pair), json=body).json() == first.json()

    drift = client.post(
        BASE,
        headers=auth(pair),
        json=body | {"requestId": "a" * 32, "expectedSourceBootstrapRevision": 1},
    )
    assert drift.status_code == 409
    assert drift.json()["error"]["code"] == "seerr_bootstrap_source_changed"

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE media_service_bootstraps SET revision=revision+1 "
            "WHERE id=?",
            (source["id"],),
        )
    stored = client.get(BASE + "/" + first.json()["bootstrap"]["id"], headers=auth(pair))
    assert stored.status_code == 503
    assert stored.json()["error"]["code"] == "seerr_bootstrap_storage_unavailable"


def test_create_rejects_public_secrets_and_non_seerr_installation(server):
    app, client, _, _ = server
    pair, source, seerr = ready_stack(server)
    for extra in (
        {"credential": "S" * 40},
        {"apiKey": "A" * 40},
        {"hostname": "jellyfin"},
        {"sourceBootstrapRevision": source["revision"]},
    ):
        response = client.post(BASE, headers=auth(pair), json=request(source, seerr) | extra)
        assert response.status_code == 400
        assert "S" * 40 not in response.text

    with app.state.core.db.connection() as connection:
        jellyfin_installation = connection.execute(
            "SELECT installation_id FROM media_service_bootstraps WHERE id=?",
            (source["id"],),
        ).fetchone()[0]
        jellyfin_revision = connection.execute(
            "SELECT revision FROM media_installations WHERE id=?",
            (jellyfin_installation,),
        ).fetchone()[0]
    wrong = client.post(
        BASE,
        headers=auth(pair),
        json=request(source, seerr)
        | {
            "requestId": "b" * 32,
            "installationId": jellyfin_installation,
            "expectedInstallationRevision": jellyfin_revision,
        },
    )
    assert wrong.status_code == 409
    assert wrong.json()["error"]["code"] == "seerr_installation_changed"


def test_list_is_admin_only_bounded_and_contains_no_private_values(server):
    app, client, _, _ = server
    pair, source, seerr = ready_stack(server)
    record = client.post(BASE, headers=auth(pair), json=request(source, seerr)).json()
    response = client.get(BASE + "?limit=1", headers=auth(pair))
    assert response.status_code == 200
    assert response.json() == {"bootstraps": [record["bootstrap"]], "nextBefore": None}
    assert "credential" not in response.text and "apiKey" not in response.text
    assert client.get(BASE + "?limit=0", headers=auth(pair)).status_code == 400

