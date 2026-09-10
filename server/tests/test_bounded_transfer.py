"""Bounded binary transfer contract over the real FastAPI/HTTP boundary."""
from dataclasses import dataclass
import hashlib
import struct

import pytest
from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.bounded_transfer.models import BlobDescriptor, TransferLimits
from larenor_server.config import Settings
from larenor_server.errors import ApiError


@dataclass
class SyntheticProvider:
    blobs: dict[str, BlobDescriptor]

    def resolve(self, resource_id: str) -> BlobDescriptor | None:
        return self.blobs.get(resource_id)


def fixture(tmp_path, *, limits=TransferLimits()):
    root = tmp_path.resolve()
    clock = Clock()
    settings = Settings(root / "data", root / "secrets/vault.key", clock=clock,
                        login_ip_limit=100, login_account_limit=100, login_global_limit=100)
    provider = SyntheticProvider({})
    app = create_app(settings, blob_provider=provider, transfer_limits=limits)
    return app, settings, clock, provider


def resource(client, app, admin):
    scope = app.state.core.context
    base = f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}"
    response = client.post(base, headers=auth(admin), json={
        "kind": "resource", "label": "Paketli tanılama", "order": 0})
    assert response.status_code == 201, response.text
    return response.json()["record"]


def user_revision(app, user_id):
    with app.state.core.db.connection() as connection:
        return connection.execute("SELECT revision FROM users WHERE id=?", (user_id,)).fetchone()[0]


def request_body(app, admin, record, *, service_revision=1, deadline_ms=5_000):
    return {
        "expectedUserRevision": user_revision(app, admin["user"]["id"]),
        "expectedRevision": record["revision"],
        "expectedAclRevision": record["aclRevision"],
        "expectedServiceRevision": service_revision,
        "deadlineMs": deadline_ms,
    }


def decode(body: bytes):
    header = struct.Struct(">4s32sQBI")
    frames = []
    offset = 0
    while offset < len(body):
        magic, trace, sequence, final, length = header.unpack_from(body, offset)
        offset += header.size
        payload = body[offset:offset + length]
        assert len(payload) == length
        offset += length
        frames.append((magic, trace.decode("ascii"), sequence, bool(final), payload))
    assert offset == len(body)
    return frames


def test_explicit_post_stream_has_exact_secret_free_metadata_and_monotonic_frames(tmp_path):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        payload = "Larenor Türkçe tanılama".encode()
        provider.blobs[record["ref"]["id"]] = BlobDescriptor(
            resource_id=record["ref"]["id"], service_revision=1,
            content_type="text/plain; charset=utf-8", content=payload)
        path = (f"/api/v1/home-resources/{record['ref']['coreId']}/"
                f"{record['ref']['homeId']}/{record['ref']['id']}/blob")

        response = client.post(path, headers=auth(admin), json=request_body(app, admin, record))

        assert response.status_code == 200
        assert response.headers["content-type"] == "application/vnd.larenor.blob-stream.v1"
        assert response.headers["x-larenor-blob-content-type"] == "text/plain; charset=utf-8"
        assert response.headers["x-larenor-blob-content-length"] == str(len(payload))
        assert response.headers["x-larenor-blob-sha256"] == hashlib.sha256(payload).hexdigest()
        assert response.headers["x-larenor-service-revision"] == "1"
        trace = response.headers["x-larenor-trace-id"]
        assert len(trace) == 32 and trace.isascii() and trace.isalnum()
        assert not any(secret in str(dict(response.headers)) for secret in (admin["accessToken"], admin["refreshToken"]))
        frames = decode(response.content)
        assert [frame[2] for frame in frames] == list(range(len(frames)))
        assert all(frame[0] == b"LRB1" and frame[1] == trace for frame in frames)
        assert frames[-1][3:] == (True, b"")
        assert b"".join(frame[4] for frame in frames[:-1]) == payload
        assert int(response.headers["content-length"]) == len(response.content)

        assert client.get(path, headers=auth(admin)).status_code == 405
        ranged = client.post(path, headers={**auth(admin), "Range": "bytes=1-"},
                             json=request_body(app, admin, record))
        assert ranged.status_code == 400 and ranged.json()["error"]["code"] == "invalid_request"


@pytest.mark.parametrize("changed", ["user", "resource", "acl", "service", "missing"])
def test_open_revalidates_all_revisions_and_packaged_provider(tmp_path, changed):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock)); record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(identity, 3, "application/octet-stream", b"fixture")
        body = request_body(app, admin, record, service_revision=3)
        if changed == "user": body["expectedUserRevision"] += 1
        elif changed == "resource": body["expectedRevision"] += 1
        elif changed == "acl": body["expectedAclRevision"] += 1
        elif changed == "service": body["expectedServiceRevision"] += 1
        elif changed == "missing": provider.blobs.clear()
        ref = record["ref"]
        response = client.post(
            f"/api/v1/home-resources/{ref['coreId']}/{ref['homeId']}/{identity}/blob",
            headers=auth(admin), json=body)
        assert response.status_code == (404 if changed == "missing" else 409)
        assert response.json()["error"]["code"] == ("not_found" if changed == "missing" else "revision_conflict")


def test_stream_aborts_without_success_frame_after_cancel_deadline_auth_loss_or_late_change(tmp_path):
    app, settings, clock, provider = fixture(tmp_path, limits=TransferLimits(chunk_bytes=3))
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock)); record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(identity, 1, "application/octet-stream", b"abcdef")
        actor = app.state.core.auth.authenticate(admin["accessToken"])
        values = request_body(app, admin, record, deadline_ms=20)

        cancelled = False
        opened = app.state.core.bounded_transfers.open(
            actor, record["ref"]["coreId"], record["ref"]["homeId"], identity,
            **app.state.core.bounded_transfers.python_arguments(values),
            cancelled=lambda: cancelled)
        assert next(opened.frames).endswith(b"abc")
        cancelled = True
        with pytest.raises(ApiError, match="transfer_cancelled"):
            next(opened.frames)
        opened.close()

        opened = app.state.core.bounded_transfers.open(
            actor, record["ref"]["coreId"], record["ref"]["homeId"], identity,
            **app.state.core.bounded_transfers.python_arguments(values), cancelled=lambda: False)
        assert next(opened.frames).endswith(b"abc")
        clock.now += .021
        with pytest.raises(ApiError, match="request_timeout"):
            next(opened.frames)
        opened.close(); clock.now -= .021

        opened = app.state.core.bounded_transfers.open(
            actor, record["ref"]["coreId"], record["ref"]["homeId"], identity,
            **app.state.core.bounded_transfers.python_arguments(values), cancelled=lambda: False)
        assert next(opened.frames).endswith(b"abc")
        client.post("/api/v1/auth/logout", headers=auth(admin))
        with pytest.raises(ApiError, match="invalid_session"):
            next(opened.frames)
        opened.close()

        admin = ready((app, client, settings, clock)); actor = app.state.core.auth.authenticate(admin["accessToken"])
        values = request_body(app, admin, record, deadline_ms=20)
        opened = app.state.core.bounded_transfers.open(
            actor, record["ref"]["coreId"], record["ref"]["homeId"], identity,
            **app.state.core.bounded_transfers.python_arguments(values), cancelled=lambda: False)
        assert next(opened.frames).endswith(b"abc")
        provider.blobs[identity] = BlobDescriptor(identity, 2, "application/octet-stream", b"defaced")
        with pytest.raises(ApiError, match="revision_conflict"):
            next(opened.frames)
        opened.close()


def test_size_actor_quota_and_one_active_stream_are_bounded(tmp_path):
    limits = TransferLimits(max_blob_bytes=8, actor_bytes_per_window=12, chunk_bytes=4,
                            max_active_streams=2, max_active_per_actor=1)
    app, settings, clock, provider = fixture(tmp_path, limits=limits)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock)); record = resource(client, app, admin)
        identity = record["ref"]["id"]
        actor = app.state.core.auth.authenticate(admin["accessToken"])
        values = request_body(app, admin, record)
        provider.blobs[identity] = BlobDescriptor(identity, 1, "application/octet-stream", b"123456789")
        with pytest.raises(ApiError, match="payload_too_large"):
            app.state.core.bounded_transfers.open(
                actor, record["ref"]["coreId"], record["ref"]["homeId"], identity,
                **app.state.core.bounded_transfers.python_arguments(values), cancelled=lambda: False)

        provider.blobs[identity] = BlobDescriptor(identity, 1, "application/octet-stream", b"12345678")
        first = app.state.core.bounded_transfers.open(
            actor, record["ref"]["coreId"], record["ref"]["homeId"], identity,
            **app.state.core.bounded_transfers.python_arguments(values), cancelled=lambda: False)
        with pytest.raises(ApiError, match="rate_limited"):
            app.state.core.bounded_transfers.open(
                actor, record["ref"]["coreId"], record["ref"]["homeId"], identity,
                **app.state.core.bounded_transfers.python_arguments(values), cancelled=lambda: False)
        first.close()
        provider.blobs[identity] = BlobDescriptor(identity, 1, "application/octet-stream", b"12345")
        with pytest.raises(ApiError, match="rate_limited"):
            app.state.core.bounded_transfers.open(
                actor, record["ref"]["coreId"], record["ref"]["homeId"], identity,
                **app.state.core.bounded_transfers.python_arguments(values), cancelled=lambda: False)
