"""A hidden blob never reaches the provider or reveals its size/revision."""

from fastapi.testclient import TestClient
import pytest

from conftest import auth, ready
from test_admin import activate, create as create_user
from test_bounded_transfer import fixture, request_body, resource
from larenor_server.bounded_transfer.models import BlobDescriptor


@pytest.mark.parametrize("probe", ["oversize", "stale_service", "provider_missing"])
def test_hidden_blob_is_denied_before_packaged_provider_resolution(tmp_path, probe):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        create_user(client, admin)
        member = activate(client, "member")
        record = resource(client, app, admin)
        ref = record["ref"]
        blob = BlobDescriptor(ref["id"], 2, "application/octet-stream", b"x" * (256 * 1024 + 1))
        provider.blobs[ref["id"]] = blob
        expected = request_body(app, member, record, service_revision=1)
        path = (f"/api/v1/home-resources/{ref['coreId']}/{ref['homeId']}/"
                f"{ref['id']}/blob")
        missing = f"/api/v1/home-resources/{ref['coreId']}/{ref['homeId']}/{'f' * 32}/blob"
        if probe == "provider_missing":
            provider.blobs.clear()
        elif probe == "oversize":
            expected["expectedServiceRevision"] = 2
        calls = []
        original = provider.resolve

        def resolve(resource_id):
            calls.append(resource_id)
            return original(resource_id)

        provider.resolve = resolve
        response = client.post(path, headers=auth(member), json=expected)
        absent = client.post(missing, headers=auth(member), json=expected)

        assert response.status_code == absent.status_code == 404
        assert response.json() == absent.json()
        assert calls == []
