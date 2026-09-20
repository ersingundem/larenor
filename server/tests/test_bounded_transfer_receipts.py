"""Durable bounded-transfer receipts distinguish history from a replay."""

from fastapi.testclient import TestClient
import pytest

from conftest import auth, login, ready
from larenor_server.app import create_app
from larenor_server.bounded_transfer.models import BlobDescriptor
from larenor_server.errors import StartupError
from test_bounded_transfer import fixture, request_body, resource


def _path(record):
    ref = record["ref"]
    return (
        f"/api/v1/home-resources/{ref['coreId']}/{ref['homeId']}/"
        f"{ref['id']}/blob"
    )


def test_completed_receipt_survives_restart_and_exact_request_is_history_not_replay(tmp_path):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "application/octet-stream", b"durable fixture"
        )
        body = request_body(app, admin, record)
        response = client.post(_path(record), headers=auth(admin), json=body)
        assert response.status_code == 200

    restarted = create_app(settings, blob_provider=provider)
    with TestClient(restarted) as client:
        admin = login(client, "admin", "Synthetic new password 2026").json()
        calls = []
        original = provider.resolve

        def resolve(resource_id):
            calls.append(resource_id)
            return original(resource_id)

        provider.resolve = resolve
        receipt = client.get(
            f"{_path(record)}/transfers/{body['requestId']}", headers=auth(admin)
        )
        assert receipt.status_code == 200
        assert receipt.json()["receipt"] == {
            "requestId": body["requestId"],
            "traceId": body["requestId"],
            "state": "completed",
            "contentLength": len(b"durable fixture"),
            "sha256": response.headers["x-larenor-blob-sha256"],
            "contentType": "application/octet-stream",
            "serviceRevision": 1,
            "createdAt": clock.now,
            "updatedAt": clock.now,
        }
        history = client.get(
            f"{_path(record)}/transfers", headers=auth(admin)
        )
        assert history.status_code == 200
        assert history.json() == {"receipts": [receipt.json()["receipt"]]}

        replay = client.post(_path(record), headers=auth(admin), json=body)
        assert replay.status_code == 409
        assert replay.json()["error"]["code"] == "transfer_replay"
        assert calls == [], "durable replay must not reopen its packaged provider"


def test_restart_marks_accepted_without_final_frame_interrupted(tmp_path):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "application/octet-stream", b"partial fixture"
        )
        body = request_body(app, admin, record)
        actor = app.state.core.auth.authenticate(admin["accessToken"])
        app.state.core.bounded_transfers.open(
            actor,
            record["ref"]["coreId"],
            record["ref"]["homeId"],
            identity,
            **app.state.core.bounded_transfers.python_arguments(body),
            cancelled=lambda: False,
        )

    restarted = create_app(settings, blob_provider=provider)
    with TestClient(restarted) as client:
        admin = login(client, "admin", "Synthetic new password 2026").json()
        response = client.get(
            f"{_path(record)}/transfers/{body['requestId']}", headers=auth(admin)
        )
        assert response.status_code == 200
        assert response.json()["receipt"]["state"] == "interrupted"


def test_receipt_authentication_failure_blocks_restart(tmp_path):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "application/octet-stream", b"authenticated fixture"
        )
        response = client.post(
            _path(record), headers=auth(admin), json=request_body(app, admin, record)
        )
        assert response.status_code == 200
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE bounded_transfer_receipts SET authentication_tag=?", ("0" * 64,)
            )

    with pytest.raises(StartupError, match="bounded_transfer_storage_invalid"):
        create_app(settings, blob_provider=provider)
