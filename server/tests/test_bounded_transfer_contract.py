"""Versioned bounded-transfer fixture captured from authenticated production HTTP."""

import base64
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch
from uuid import UUID

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.files import private_create
from test_bounded_blob_product_provider import paths, upload_headers
from test_bounded_transfer import user_revision


FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "contracts/bounded-transfer.v1.json"
)


def _selected_headers(response):
    names = (
        "content-type",
        "content-length",
        "x-larenor-trace-id",
        "x-larenor-blob-content-length",
        "x-larenor-blob-sha256",
        "x-larenor-blob-content-type",
        "x-larenor-service-revision",
        "cache-control",
        "accept-ranges",
    )
    return {name: response.headers[name] for name in names}


def actual_contract(root: Path):
    clock = Clock()
    settings = Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )
    private_create(settings.key_file, bytes(range(32)))
    contexts = iter(("a" * 32, "b" * 32))
    account_ids = iter(("0" * 32, "f" * 32))
    with (
        patch(
            "larenor_server.context.secrets",
            SimpleNamespace(token_hex=lambda _size: next(contexts)),
        ),
        patch(
            "larenor_server.core.uuid",
            SimpleNamespace(uuid4=lambda: UUID(hex=next(account_ids))),
        ),
    ):
        app = create_app(settings)

    payload = "Larenor ortak aktarım".encode()
    upload_id = "5" * 32
    download_id = "6" * 32
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        scope = app.state.core.context
        base = f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}"
        with patch(
            "larenor_server.home_resources.service.uuid",
            SimpleNamespace(uuid4=lambda: UUID(hex="3" * 32)),
        ):
            created = client.post(
                base,
                headers=auth(admin),
                json={"kind": "resource", "label": "Ortak aktarım", "order": 0},
            )
        assert created.status_code == 201, created.text
        record = created.json()["record"]
        upload_path, descriptor_path, download_path = paths(record)
        headers = upload_headers(
            app,
            admin,
            record,
            payload,
            request_id=upload_id,
            content_type="text/plain; charset=utf-8",
        )
        uploaded = client.put(
            upload_path + upload_id,
            headers=headers,
            content=payload,
        )
        assert uploaded.status_code == 201, uploaded.text
        descriptor = client.get(descriptor_path, headers=auth(admin))
        assert descriptor.status_code == 200, descriptor.text

        request = {
            "requestId": download_id,
            "expectedUserRevision": user_revision(app, admin["user"]["id"]),
            "expectedRevision": record["revision"],
            "expectedAclRevision": record["aclRevision"],
            "expectedServiceRevision": 1,
            "deadlineMs": 5000,
        }
        downloaded = client.post(download_path, headers=auth(admin), json=request)
        assert downloaded.status_code == 200, downloaded.text
        receipt_path = f"{download_path}/transfers/{download_id}"
        receipt = client.get(receipt_path, headers=auth(admin))
        history = client.get(
            f"{download_path}/transfers?limit=20",
            headers=auth(admin),
        )
        assert receipt.status_code == history.status_code == 200

        stale_request = {**request, "requestId": "7" * 32, "expectedServiceRevision": 2}
        stale = client.post(download_path, headers=auth(admin), json=stale_request)
        ranged_request = {**request, "requestId": "8" * 32}
        ranged = client.post(
            download_path,
            headers={**auth(admin), "Range": "bytes=1-"},
            json=ranged_request,
        )
        assert stale.status_code == 409
        assert ranged.status_code == 400
        assert client.get(
            f"{download_path}/transfers?limit=20",
            headers=auth(admin),
        ).json() == history.json()

        safe_upload_headers = {
            key.lower(): value
            for key, value in headers.items()
            if key.lower() != "authorization"
        }
        result = {
            "schemaVersion": 1,
            "context": scope.model_dump(),
            "target": record,
            "userRevision": request["expectedUserRevision"],
            "upload": {
                "method": "PUT",
                "path": upload_path + upload_id,
                "requestHeaders": safe_upload_headers,
                "payloadBase64": base64.b64encode(payload).decode("ascii"),
                "status": uploaded.status_code,
                "response": uploaded.json(),
            },
            "descriptor": {
                "method": "GET",
                "path": descriptor_path,
                "status": descriptor.status_code,
                "response": descriptor.json(),
            },
            "download": {
                "method": "POST",
                "path": download_path,
                "request": request,
                "status": downloaded.status_code,
                "responseHeaders": _selected_headers(downloaded),
                "wireBase64": base64.b64encode(downloaded.content).decode("ascii"),
            },
            "receipt": {
                "method": "GET",
                "path": receipt_path,
                "status": receipt.status_code,
                "response": receipt.json(),
            },
            "history": {
                "method": "GET",
                "path": f"{download_path}/transfers?limit=20",
                "status": history.status_code,
                "response": history.json(),
            },
            "errors": {
                "staleRevision": {
                    "request": stale_request,
                    "status": stale.status_code,
                    "response": stale.json(),
                },
                "range": {
                    "request": ranged_request,
                    "status": ranged.status_code,
                    "response": ranged.json(),
                },
            },
        }
        raw = json.dumps(result)
        digest = hashlib.sha256(payload).hexdigest()
        assert digest in raw
        assert all(
            secret not in raw
            for secret in (admin["accessToken"], admin["refreshToken"])
        )
        return result


def test_bounded_transfer_contract_matches_actual_authenticated_http(tmp_path):
    assert actual_contract(tmp_path.resolve()) == json.loads(FIXTURE.read_text())


def test_contract_keeps_failures_content_free_and_out_of_history():
    fixture = json.loads(FIXTURE.read_text())
    receipt = fixture["receipt"]["response"]["receipt"]
    history = fixture["history"]["response"]["receipts"]
    assert history == [receipt]
    assert receipt["state"] == "completed"
    assert fixture["errors"] == {
        "staleRevision": {
            "request": fixture["errors"]["staleRevision"]["request"],
            "status": 409,
            "response": {
                "error": {
                    "code": "revision_conflict",
                    "message": "The referenced revision changed.",
                }
            },
        },
        "range": {
            "request": fixture["errors"]["range"]["request"],
            "status": 400,
            "response": {
                "error": {
                    "code": "invalid_request",
                    "message": "The request is invalid.",
                }
            },
        },
    }
    assert "payloadBase64" not in fixture["receipt"]
    assert "payloadBase64" not in fixture["history"]


if __name__ == "__main__":
    with TemporaryDirectory(prefix="larenor-bounded-transfer-contract-") as root:
        FIXTURE.write_text(
            json.dumps(actual_contract(Path(root).resolve()), indent=2) + "\n"
        )
