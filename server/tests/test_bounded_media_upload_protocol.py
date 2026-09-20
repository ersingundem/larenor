"""Media payloads are authenticated before product-blob persistence."""

import hashlib
import uuid

from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.bounded_transfer.media_policy import validate_media_payload
from test_bounded_blob_product_provider import fixture, paths, upload_headers
from test_bounded_transfer import resource


def test_closed_document_image_audio_and_video_payload_contract():
    cases = {
        "text/plain; charset=utf-8": "Larenor Türkçe".encode(),
        "application/json": b'{"safe":true}',
        "application/pdf": b"%PDF-1.7\n%%EOF",
        "image/png": b"\x89PNG\r\n\x1a\n\x00",
        "image/jpeg": b"\xff\xd8\xff\xe0\x00\xff\xd9",
        "image/webp": b"RIFF0000WEBPVP8 ",
        "audio/mpeg": b"ID3\x04\x00\x00\x00",
        "audio/flac": b"fLaC0000",
        "audio/wav": b"RIFF0000WAVEfmt ",
        "audio/ogg": b"OggS0000",
        "video/mp4": b"\x00\x00\x00\x10ftypisom\x00\x00\x00\x00",
        "video/webm": b"\x1a\x45\xdf\xa3\x01",
    }

    for content_type, payload in cases.items():
        validate_media_payload(content_type, payload)


def test_invalid_first_media_upload_leaves_no_state_and_request_id_can_be_corrected(tmp_path):
    app, settings, clock = fixture(tmp_path)
    request_id = uuid.uuid4().hex
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        upload, descriptor, _download = paths(record)
        wrong = b"not a PDF"

        rejected = client.put(
            upload + request_id,
            headers=upload_headers(
                app,
                admin,
                record,
                wrong,
                request_id=request_id,
                content_type="application/pdf",
            ),
            content=wrong,
        )

        assert rejected.status_code == 400
        assert rejected.json() == {
            "error": {"code": "invalid_request", "message": "The request is invalid."}
        }
        assert client.get(descriptor, headers=auth(admin)).status_code == 404
        with app.state.core.db.connection() as connection:
            assert connection.execute(
                "SELECT COUNT(*) FROM bounded_blob_objects"
            ).fetchone()[0] == 0
            assert connection.execute(
                "SELECT COUNT(*) FROM bounded_blob_uploads"
            ).fetchone()[0] == 0

        corrected = b"verified document"
        accepted = client.put(
            upload + request_id,
            headers=upload_headers(
                app, admin, record, corrected, request_id=request_id
            ),
            content=corrected,
        )
        assert accepted.status_code == 201, accepted.text
        assert accepted.json()["blob"]["serviceRevision"] == 1


def test_invalid_media_replacement_preserves_current_object_and_journal(tmp_path):
    app, settings, clock = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        upload, descriptor, _download = paths(record)
        original = b"trusted original"
        original_id = uuid.uuid4().hex
        created = client.put(
            upload + original_id,
            headers=upload_headers(
                app, admin, record, original, request_id=original_id
            ),
            content=original,
        )
        assert created.status_code == 201
        baseline = client.get(descriptor, headers=auth(admin)).json()["blob"]

        invalid = [
            ("text/html", b"<script>alert(1)</script>"),
            ("image/svg+xml", b"<svg/>"),
            ("application/octet-stream", b"opaque"),
            ("text/plain; charset=utf-8; name=page.html", b"safe"),
            ("image/png", b"wrong signature"),
            ("application/json", b'{"broken":'),
        ]
        for content_type, payload in invalid:
            request_id = uuid.uuid4().hex
            rejected = client.put(
                upload + request_id,
                headers=upload_headers(
                    app,
                    admin,
                    record,
                    payload,
                    request_id=request_id,
                    service_revision=1,
                    content_type=content_type,
                ),
                content=payload,
            )
            assert rejected.status_code == 400, content_type
            assert rejected.json()["error"]["code"] == "invalid_request"
            assert client.get(descriptor, headers=auth(admin)).json()["blob"] == baseline

        with app.state.core.db.connection() as connection:
            assert connection.execute(
                "SELECT COUNT(*) FROM bounded_blob_objects"
            ).fetchone()[0] == 1
            assert connection.execute(
                "SELECT COUNT(*) FROM bounded_blob_uploads"
            ).fetchone()[0] == 1
            row = connection.execute(
                "SELECT sha256,service_revision FROM bounded_blob_objects"
            ).fetchone()
            assert tuple(row) == (hashlib.sha256(original).hexdigest(), 1)
