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
        canonical = client.get(
            f"{_path(record)}/transfers?limit=1", headers=auth(admin)
        )
        assert canonical.status_code == 200
        assert canonical.json() == history.json()

        replay = client.post(_path(record), headers=auth(admin), json=body)
        assert replay.status_code == 409
        assert replay.json()["error"]["code"] == "transfer_replay"
        assert calls == [], "durable replay must not reopen its packaged provider"

        changed = {**body, "deadlineMs": body["deadlineMs"] - 1}
        conflict = client.post(_path(record), headers=auth(admin), json=changed)
        assert conflict.status_code == 409
        assert conflict.json()["error"]["code"] == "idempotency_conflict"

        other = resource(client, restarted, admin)
        changed_scope = client.post(_path(other), headers=auth(admin), json=body)
        assert changed_scope.status_code == 409
        assert changed_scope.json()["error"]["code"] == "idempotency_conflict"
        assert calls == [], "conflicting envelopes must fail before provider access"


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


@pytest.mark.parametrize(
    "suffix",
    ["?unknown=1", "?limit=1", "?limit=01", "?limit=1&limit=2", "?limit=+1"],
)
def test_receipt_query_rejects_every_parameter(tmp_path, suffix):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        response = client.get(
            f"{_path(record)}/transfers/{'f' * 32}{suffix}", headers=auth(admin)
        )
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "invalid_request"


@pytest.mark.parametrize(
    "suffix", ["?unknown=1", "?limit=01", "?limit=1&limit=2", "?limit=+1"]
)
def test_history_query_accepts_only_one_canonical_limit(tmp_path, suffix):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        response = client.get(f"{_path(record)}/transfers{suffix}", headers=auth(admin))
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "invalid_request"


@pytest.mark.parametrize("surface", ["one", "history"])
def test_receipt_surfaces_reject_duplicate_authorization(tmp_path, surface):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        path = f"{_path(record)}/transfers"
        if surface == "one":
            path += f"/{'f' * 32}"
        value = auth(admin)["Authorization"]
        response = client.get(path, headers=[
            ("Authorization", value), ("Authorization", value),
        ])
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "invalid_request"


@pytest.mark.parametrize(
    "tamper",
    [
        "DROP INDEX bounded_transfer_resource_history",
        (
            "ALTER TABLE bounded_transfer_receipts RENAME TO discarded_receipts; "
            "CREATE TABLE bounded_transfer_receipts(request_id TEXT PRIMARY KEY)"
        ),
        "UPDATE metadata SET value=2 WHERE key='bounded_transfer_schema'",
    ],
)
def test_empty_receipt_schema_tamper_blocks_restart(tmp_path, tamper):
    app, settings, _clock, provider = fixture(tmp_path)
    with TestClient(app):
        with app.state.core.db.connection() as connection:
            connection.executescript(tamper)
    with pytest.raises(StartupError, match="bounded_transfer_storage_invalid"):
        create_app(settings, blob_provider=provider)


@pytest.mark.parametrize(
    "tamper",
    [
        "content_length=X'31'",
        "created_at='not-real'",
        "actor_id=X'3131313131313131313131313131313131313131313131313131313131313131'",
        "state='invented'",
    ],
)
def test_bounded_receipt_row_type_or_value_tamper_blocks_restart(tmp_path, tamper):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "application/octet-stream", b"bounded row"
        )
        assert client.post(
            _path(record), headers=auth(admin), json=request_body(app, admin, record)
        ).status_code == 200
        with app.state.core.db.connection() as connection:
            connection.execute("PRAGMA ignore_check_constraints=ON")
            connection.execute(f"UPDATE bounded_transfer_receipts SET {tamper}")
    with pytest.raises(StartupError, match="bounded_transfer_storage_invalid"):
        create_app(settings, blob_provider=provider)
