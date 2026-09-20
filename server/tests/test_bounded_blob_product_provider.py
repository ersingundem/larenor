"""A persisted product blob is uploaded and downloaded through closed contracts."""

import hashlib
import sqlite3
import uuid

import pytest
from fastapi.testclient import TestClient

from conftest import Clock, auth, login, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import StartupError
from test_admin import activate, create as create_user
from test_bounded_transfer import decode, request_body, resource, user_revision


def fixture(tmp_path):
    root = tmp_path.resolve()
    clock = Clock()
    settings = Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )
    return create_app(settings), settings, clock


def paths(record):
    ref = record["ref"]
    blob = (
        f"/api/v1/home-resources/{ref['coreId']}/{ref['homeId']}/"
        f"{ref['id']}/blob"
    )
    return blob + "/uploads/", blob + "/descriptor", blob


def upload_headers(app, pair, record, payload, *, request_id=None, service_revision=0,
                   content_type="text/plain; charset=utf-8"):
    return {
        **auth(pair),
        "Content-Type": content_type,
        "Content-Length": str(len(payload)),
        "X-Larenor-Content-Sha256": hashlib.sha256(payload).hexdigest(),
        "X-Larenor-Expected-User-Revision": str(
            user_revision(app, pair["user"]["id"])
        ),
        "X-Larenor-Expected-Resource-Revision": str(record["revision"]),
        "X-Larenor-Expected-Acl-Revision": str(record["aclRevision"]),
        "X-Larenor-Expected-Service-Revision": str(service_revision),
        "X-Larenor-Upload-Request-Id": request_id or uuid.uuid4().hex,
    }


def test_production_provider_upload_descriptor_download_and_restart(tmp_path):
    app, settings, clock = fixture(tmp_path)
    payload = "Larenor ev belgesi: garanti 2028".encode()
    request_id = uuid.uuid4().hex
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        upload, descriptor, download = paths(record)
        headers = upload_headers(
            app, admin, record, payload, request_id=request_id
        )

        stored = client.put(upload + request_id, headers=headers, content=payload)

        assert stored.status_code == 201, stored.text
        expected = {
            "requestId": request_id,
            "resourceId": record["ref"]["id"],
            "serviceRevision": 1,
            "contentLength": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "contentType": "text/plain; charset=utf-8",
            "createdAt": clock.now,
            "updatedAt": clock.now,
        }
        assert stored.json() == {"blob": expected}
        assert client.get(descriptor, headers=auth(admin)).json() == {
            "blob": {key: value for key, value in expected.items() if key != "requestId"}
        }

        body = request_body(app, admin, record, service_revision=1)
        streamed = client.post(download, headers=auth(admin), json=body)
        assert streamed.status_code == 200, streamed.text
        assert b"".join(frame[4] for frame in decode(streamed.content)[:-1]) == payload

    assert payload not in settings.database_file.read_bytes()
    restarted = create_app(settings)
    with TestClient(restarted) as client:
        admin = login(client, "admin", "Synthetic new password 2026").json()
        upload, descriptor, download = paths(record)
        assert client.get(descriptor, headers=auth(admin)).json()["blob"][
            "serviceRevision"
        ] == 1
        body = request_body(restarted, admin, record, service_revision=1)
        streamed = client.post(download, headers=auth(admin), json=body)
        assert b"".join(frame[4] for frame in decode(streamed.content)[:-1]) == payload


def test_replace_is_atomic_revisioned_and_request_idempotent(tmp_path):
    app, settings, clock = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        upload, descriptor, download = paths(record)
        first = b"first verified document"
        first_id = uuid.uuid4().hex
        first_headers = upload_headers(
            app, admin, record, first, request_id=first_id
        )
        response = client.put(upload + first_id, headers=first_headers, content=first)
        assert response.status_code == 201

        replay = client.put(upload + first_id, headers=first_headers, content=first)
        assert replay.status_code == 200
        assert replay.json() == response.json()

        changed_replay = client.put(
            upload + first_id,
            headers={
                **first_headers,
                "X-Larenor-Content-Sha256": hashlib.sha256(b"other").hexdigest(),
                "Content-Length": "5",
            },
            content=b"other",
        )
        assert changed_replay.status_code == 409
        assert changed_replay.json()["error"]["code"] == "idempotency_conflict"

        second = b"second verified document"
        second_id = uuid.uuid4().hex
        clock.now += 1
        replaced = client.put(
            upload + second_id,
            headers=upload_headers(
                app,
                admin,
                record,
                second,
                request_id=second_id,
                service_revision=1,
            ),
            content=second,
        )
        assert replaced.status_code == 200, replaced.text
        assert replaced.json()["blob"]["serviceRevision"] == 2
        assert replaced.json()["blob"]["createdAt"] == response.json()["blob"]["createdAt"]
        assert replaced.json()["blob"]["updatedAt"] == clock.now
        assert client.get(descriptor, headers=auth(admin)).json()["blob"] == {
            key: value for key, value in replaced.json()["blob"].items()
            if key != "requestId"
        }

        stale = client.post(
            download,
            headers=auth(admin),
            json=request_body(app, admin, record, service_revision=1),
        )
        assert stale.status_code == 409
        current = client.post(
            download,
            headers=auth(admin),
            json=request_body(app, admin, record, service_revision=2),
        )
        assert b"".join(frame[4] for frame in decode(current.content)[:-1]) == second


@pytest.mark.parametrize(
    "mutation,code,status",
    [
        ("length", "invalid_request", 400),
        ("digest", "invalid_request", 400),
        ("content_type", "invalid_request", 400),
        ("oversize", "payload_too_large", 413),
        ("service", "revision_conflict", 409),
        ("resource", "revision_conflict", 409),
        ("acl", "revision_conflict", 409),
        ("user", "revision_conflict", 409),
    ],
)
def test_invalid_or_stale_upload_never_replaces_product_blob(
    tmp_path, mutation, code, status
):
    app, settings, clock = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        upload, descriptor, _download = paths(record)
        original = b"trusted"
        first_id = uuid.uuid4().hex
        assert client.put(
            upload + first_id,
            headers=upload_headers(
                app, admin, record, original, request_id=first_id
            ),
            content=original,
        ).status_code == 201

        payload = b"x" * (256 * 1024 + 1) if mutation == "oversize" else b"changed"
        request_id = uuid.uuid4().hex
        headers = upload_headers(
            app,
            admin,
            record,
            payload,
            request_id=request_id,
            service_revision=1,
        )
        if mutation == "length":
            headers["Content-Length"] = str(len(payload) + 1)
        elif mutation == "digest":
            headers["X-Larenor-Content-Sha256"] = "0" * 64
        elif mutation == "content_type":
            headers["Content-Type"] = "text/plain\r\nx-private: secret"
        elif mutation in {"service", "resource", "acl", "user"}:
            field = {
                "service": "X-Larenor-Expected-Service-Revision",
                "resource": "X-Larenor-Expected-Resource-Revision",
                "acl": "X-Larenor-Expected-Acl-Revision",
                "user": "X-Larenor-Expected-User-Revision",
            }[mutation]
            headers[field] = str(int(headers[field]) + 1)

        response = client.put(upload + request_id, headers=headers, content=payload)
        assert response.status_code == status, response.text
        assert response.json()["error"]["code"] == code
        blob = client.get(descriptor, headers=auth(admin)).json()["blob"]
        assert blob["serviceRevision"] == 1
        assert blob["sha256"] == hashlib.sha256(original).hexdigest()


def test_write_authority_and_resource_lifecycle_bound_product_blob(tmp_path):
    app, settings, clock = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        create_user(client, admin)
        member = activate(client, "member")
        record = resource(client, app, admin)
        upload, descriptor, _download = paths(record)
        payload = b"private home document"
        request_id = uuid.uuid4().hex

        hidden = client.put(
            upload + request_id,
            headers=upload_headers(
                app, member, record, payload, request_id=request_id
            ),
            content=payload,
        )
        assert hidden.status_code == 404

        ref = record["ref"]
        grant = (
            f"/api/v1/admin/home-resources/{ref['coreId']}/{ref['homeId']}/"
            f"{ref['id']}/grants/{member['user']['id']}"
        )
        granted = client.put(
            grant,
            headers=auth(admin),
            json={
                "expectedAclRevision": 1,
                "permissions": {"read": True, "write": False},
            },
        ).json()["grant"]
        readable = {**record, "aclRevision": granted["aclRevision"]}
        read_only_id = uuid.uuid4().hex
        denied = client.put(
            upload + read_only_id,
            headers=upload_headers(
                app, member, readable, payload, request_id=read_only_id
            ),
            content=payload,
        )
        assert denied.status_code == 403

        write_grant = client.put(
            grant,
            headers=auth(admin),
            json={
                "expectedAclRevision": granted["aclRevision"],
                "permissions": {"read": True, "write": True},
            },
        ).json()["grant"]
        writable = {**record, "aclRevision": write_grant["aclRevision"]}
        accepted_id = uuid.uuid4().hex
        accepted = client.put(
            upload + accepted_id,
            headers=upload_headers(
                app, member, writable, payload, request_id=accepted_id
            ),
            content=payload,
        )
        assert accepted.status_code == 201
        assert client.get(descriptor, headers=auth(member)).status_code == 200

        deleted = client.delete(
            f"/api/v1/admin/home-resources/{ref['coreId']}/{ref['homeId']}/{ref['id']}",
            params={
                "expectedRevision": record["revision"],
                "expectedAclRevision": write_grant["aclRevision"],
            },
            headers=auth(admin),
        )
        assert deleted.status_code == 204
        assert client.get(descriptor, headers=auth(admin)).status_code == 404
        with app.state.core.db.connection() as connection:
            assert connection.execute(
                "SELECT COUNT(*) FROM bounded_blob_objects"
            ).fetchone()[0] == 0


def test_ciphertext_or_upload_journal_tamper_fails_closed_on_restart(tmp_path):
    app, settings, clock = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        upload, _descriptor, _download = paths(record)
        payload = b"never plaintext in sqlite"
        request_id = uuid.uuid4().hex
        assert client.put(
            upload + request_id,
            headers=upload_headers(
                app, admin, record, payload, request_id=request_id
            ),
            content=payload,
        ).status_code == 201

    connection = sqlite3.connect(settings.database_file)
    connection.execute(
        "UPDATE bounded_blob_objects SET ciphertext=?", (b"tampered",)
    )
    connection.commit()
    connection.close()
    with pytest.raises(StartupError, match="bounded_blob_storage_invalid"):
        create_app(settings)
