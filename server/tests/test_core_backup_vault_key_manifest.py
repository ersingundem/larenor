"""S09.1 manifest contract for the separate AES-256 vault key."""

import copy

import pytest
from conftest import auth, ready


@pytest.mark.parametrize("byte_length", [31, 33])
def test_restore_preflight_rejects_non_aes256_vault_key_length(
    server, byte_length
):
    _app, client, _settings, _clock = server
    pair = ready(server)
    plan = client.get(
        "/api/v1/admin/backups/plan",
        headers=auth(pair),
    )
    assert plan.status_code == 200
    manifest = copy.deepcopy(plan.json()["manifest"])
    vault_key = next(
        resource
        for resource in manifest["resources"]
        if resource["id"] == "vault-key"
    )
    assert vault_key["version"] == "aes256-v1"
    vault_key["byteLength"] = byte_length

    response = client.post(
        "/api/v1/admin/backups/restore/validate",
        headers=auth(pair),
        json={"manifest": manifest},
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_request"
