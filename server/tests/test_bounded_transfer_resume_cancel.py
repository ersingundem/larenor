"""S08.10 resumable download, explicit cancellation, and lease cleanup."""

import uuid

import pytest
from fastapi.testclient import TestClient

from larenor_server.errors import ApiError
from test_bounded_transfer import (
    fixture,
    request_body,
    resource,
)
from larenor_server.bounded_transfer.models import BlobDescriptor, TransferLimits
from conftest import auth, ready


def _open(core, actor, record, values, *, cancelled=lambda: False):
    return core.bounded_transfers.open(
        actor,
        record["ref"]["coreId"],
        record["ref"]["homeId"],
        record["ref"]["id"],
        **core.bounded_transfers.python_arguments(values),
        cancelled=cancelled,
    )


def _payload(frame):
    return frame[49:]


def test_interrupted_transfer_resumes_exact_bytes_and_cleans_both_leases(tmp_path):
    app, settings, clock, provider = fixture(
        tmp_path, limits=TransferLimits(chunk_bytes=3)
    )
    # Use the real HTTP fixture lifecycle for auth and resource setup, then the
    # service seam for deterministic interruption between frames.
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        content = b"abcdefghi"
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "audio/mpeg", content
        )
        actor = app.state.core.auth.authenticate(admin["accessToken"])
        first = request_body(app, admin, record)
        opened = _open(app.state.core, actor, record, first)
        assert _payload(next(opened.frames)) == b"abc"
        opened.close()
        assert app.state.core.bounded_transfers.receipt(
            actor,
            record["ref"]["coreId"],
            record["ref"]["homeId"],
            identity,
            first["requestId"],
        )["receipt"]["state"] == "interrupted"
        assert app.state.core.bounded_transfers._active == 0
        assert not app.state.core.bounded_transfers._active_requests

        resumed = request_body(app, admin, record)
        resumed.update(
            resumeRequestId=first["requestId"],
            resumeOffset=3,
        )
        continuation = _open(app.state.core, actor, record, resumed)
        assert continuation.metadata.resume_offset == 3
        frames = list(continuation.frames)
        assert b"".join(_payload(frame) for frame in frames[:-1]) == b"defghi"
        assert _payload(frames[-1]) == b""
        receipt = app.state.core.bounded_transfers.receipt(
            actor,
            record["ref"]["coreId"],
            record["ref"]["homeId"],
            identity,
            resumed["requestId"],
        )["receipt"]
        assert receipt["state"] == "completed"
        assert receipt["contentLength"] == len(content)
        assert app.state.core.bounded_transfers._active == 0
        assert not app.state.core.bounded_transfers._active_requests


def test_explicit_cancel_is_idempotent_and_resume_fails_on_changed_source(tmp_path):
    app, settings, clock, provider = fixture(
        tmp_path, limits=TransferLimits(chunk_bytes=3)
    )
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "image/png", b"\x89PNG\r\n\x1a\nfixture"
        )
        actor = app.state.core.auth.authenticate(admin["accessToken"])
        values = request_body(app, admin, record)
        opened = _open(app.state.core, actor, record, values)
        next(opened.frames)

        first = app.state.core.bounded_transfers.cancel(
            actor,
            record["ref"]["coreId"],
            record["ref"]["homeId"],
            identity,
            values["requestId"],
        )
        second = app.state.core.bounded_transfers.cancel(
            actor,
            record["ref"]["coreId"],
            record["ref"]["homeId"],
            identity,
            values["requestId"],
        )
        assert first == second
        assert first["receipt"]["state"] == "interrupted"
        ref = record["ref"]
        path = (
            f"/api/v1/home-resources/{ref['coreId']}/{ref['homeId']}/"
            f"{identity}/blob"
        )
        history = client.get(
            path + "/transfers/events", headers=auth(admin)
        ).json()
        assert [
            (event["sequence"], event["kind"], event["receipt"]["state"])
            for event in history["events"]
        ] == [(1, "accepted", "accepted"), (2, "result", "interrupted")]
        assert {
            event["receipt"]["requestId"] for event in history["events"]
        } == {values["requestId"]}
        with pytest.raises(ApiError, match="transfer_cancelled"):
            next(opened.frames)
        assert app.state.core.bounded_transfers._active == 0
        assert not app.state.core.bounded_transfers._active_requests

        provider.blobs[identity] = BlobDescriptor(
            identity, 2, "image/png", b"\x89PNG\r\n\x1a\nchanged"
        )
        resumed = request_body(app, admin, record, service_revision=2)
        resumed.update(
            requestId=uuid.uuid4().hex,
            resumeRequestId=values["requestId"],
            resumeOffset=3,
        )
        with pytest.raises(ApiError, match="revision_conflict"):
            _open(app.state.core, actor, record, resumed)
        assert app.state.core.bounded_transfers._active == 0
        assert not app.state.core.bounded_transfers._active_requests


def test_http_resume_and_cancel_routes_keep_closed_metadata(tmp_path):
    app, settings, clock, provider = fixture(
        tmp_path, limits=TransferLimits(chunk_bytes=3)
    )
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        content = b"abcdefghi"
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "video/webm", content
        )
        actor = app.state.core.auth.authenticate(admin["accessToken"])
        first = request_body(app, admin, record)
        opened = _open(app.state.core, actor, record, first)
        assert _payload(next(opened.frames)) == b"abc"
        opened.close()

        resumed = request_body(app, admin, record)
        resumed.update(
            resumeRequestId=first["requestId"],
            resumeOffset=3,
        )
        ref = record["ref"]
        path = (
            f"/api/v1/home-resources/{ref['coreId']}/{ref['homeId']}/"
            f"{identity}/blob"
        )
        response = client.post(path, headers=auth(admin), json=resumed)
        assert response.status_code == 200
        assert response.headers["x-larenor-resume-offset"] == "3"
        assert response.headers["x-larenor-blob-content-length"] == str(
            len(content)
        )
        assert response.headers["accept-ranges"] == "none"
        assert b"def" in response.content and b"ghi" in response.content
        assert b"abc" not in response.content

        cancelled = client.delete(
            path + "/transfers/" + first["requestId"],
            headers=auth(admin),
        )
        assert cancelled.status_code == 200
        assert cancelled.json()["receipt"]["state"] == "interrupted"
        assert "token" not in cancelled.text.lower()


def test_resume_requires_exact_interrupted_receipt_and_never_leaks_a_lease(
    tmp_path,
):
    app, settings, clock, provider = fixture(
        tmp_path, limits=TransferLimits(chunk_bytes=3)
    )
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "audio/mpeg", b"abcdefghi"
        )
        actor = app.state.core.auth.authenticate(admin["accessToken"])

        missing = request_body(app, admin, record)
        missing.update(
            resumeRequestId=uuid.uuid4().hex,
            resumeOffset=3,
        )
        with pytest.raises(ApiError, match="not_found"):
            _open(app.state.core, actor, record, missing)

        completed = request_body(app, admin, record)
        list(_open(app.state.core, actor, record, completed).frames)
        replay = request_body(app, admin, record)
        replay.update(
            resumeRequestId=completed["requestId"],
            resumeOffset=3,
        )
        with pytest.raises(ApiError, match="revision_conflict"):
            _open(app.state.core, actor, record, replay)

        assert app.state.core.bounded_transfers._active == 0
        assert not app.state.core.bounded_transfers._active_by_actor
        assert not app.state.core.bounded_transfers._active_requests
