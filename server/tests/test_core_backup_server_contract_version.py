"""S09.1 exact Server manifest shape across backup contract versions."""

import hashlib
import json
import secrets

import pytest
from conftest import auth, ready
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from larenor_server.core_backups.models import BackupManifest
from larenor_server.core_backups.service import (
    MAGIC,
    BackupCapture,
    CoreBackupContract,
)
from larenor_server.errors import ApiError

PASSPHRASE = "Correct horse battery staple 2026"


def _manifest(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    response = client.get("/api/v1/admin/backups/plan", headers=auth(pair))
    assert response.status_code == 200
    return pair, response.json()["manifest"]


def _bundle(contract, capture):
    salt, nonce = secrets.token_bytes(16), secrets.token_bytes(12)
    aad = MAGIC + salt + nonce
    return aad + AESGCM(
        CoreBackupContract._derive_key(PASSPHRASE, salt)
    ).encrypt(nonce, CoreBackupContract._archive(capture), aad)


def _true_legacy_capture(capture):
    payloads = {
        name: value
        for name, value in capture.payloads.items()
        if name != "family-board"
    }
    payloads["component-index"] = json.dumps(
        {
            "contractVersion": 1,
            "schemas": capture.manifest.componentSchemaVersions,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("ascii")
    raw = capture.manifest.model_dump(mode="json", by_alias=True)
    raw["contractVersion"] = 1
    raw.pop("components")
    raw.pop("consistencyBoundary")
    raw["resources"] = [
        resource
        for resource in raw["resources"]
        if resource["id"] != "family-board"
    ]
    index = next(
        resource
        for resource in raw["resources"]
        if resource["id"] == "component-index"
    )
    index.update(
        version="1",
        byteLength=len(payloads["component-index"]),
        sha256=hashlib.sha256(payloads["component-index"]).hexdigest(),
    )
    return BackupCapture(
        manifest=BackupManifest.model_validate(raw),
        payloads=payloads,
    )


def test_v1_preflight_rejects_component_contract_fields_even_when_empty(server):
    _app, client, _settings, _clock = server
    pair, manifest = _manifest(server)
    manifest["contractVersion"] = 1
    manifest["resources"] = [
        resource
        for resource in manifest["resources"]
        if resource["id"] != "family-board"
    ]

    response = client.post(
        "/api/v1/admin/backups/restore/validate",
        headers=auth(pair),
        json={"manifest": manifest},
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_request"


def test_v2_preflight_requires_explicit_components_and_consistency_boundary(server):
    _app, client, _settings, _clock = server
    pair, manifest = _manifest(server)
    manifest.pop("components")
    manifest.pop("consistencyBoundary")
    index = next(
        resource
        for resource in manifest["resources"]
        if resource["id"] == "component-index"
    )
    index["version"] = "1"

    response = client.post(
        "/api/v1/admin/backups/restore/validate",
        headers=auth(pair),
        json={"manifest": manifest},
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_request"


def test_bundle_open_rejects_mixed_v1_shape_and_keeps_true_legacy_readable(server):
    app, _client, _settings, _clock = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    contract = app.state.core.core_backups
    capture = contract.capture(actor)
    mixed = BackupCapture(
        manifest=capture.manifest.model_copy(
            update={
                "contractVersion": 1,
                "resources": [
                    resource
                    for resource in capture.manifest.resources
                    if resource.id != "family-board"
                ],
            }
        ),
        payloads={
            name: value
            for name, value in capture.payloads.items()
            if name != "family-board"
        },
    )

    with pytest.raises(ApiError) as raised:
        contract.open_bundle(_bundle(contract, mixed), PASSPHRASE)
    assert raised.value.code == "backup_decryption_failed"

    legacy = _true_legacy_capture(capture)
    opened = contract.open_bundle(_bundle(contract, legacy), PASSPHRASE)
    assert opened.manifest.contractVersion == 1
    assert opened.manifest.components == []
    assert opened.manifest.consistencyBoundary is None
    assert "family-board" not in opened.payloads
