import hashlib
import json
import secrets

import pytest
from conftest import ready
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from larenor_server.core_backups.service import MAGIC, BackupCapture
from larenor_server.errors import ApiError

PASSPHRASE = "Correct horse battery staple 2026"


def _bundle(contract, capture):
    salt, nonce = secrets.token_bytes(16), secrets.token_bytes(12)
    aad = MAGIC + salt + nonce
    return aad + AESGCM(contract._derive_key(PASSPHRASE, salt)).encrypt(
        nonce, contract._archive(capture), aad
    )


def test_open_bundle_rejects_schema_inventory_not_backed_by_database_cut(server):
    app, _client, _settings, _clock = server
    pair = ready(server)
    contract = app.state.core.core_backups
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    capture = contract.capture(actor)

    key = min(capture.manifest.componentSchemaVersions)
    changed_schemas = {
        **capture.manifest.componentSchemaVersions,
        key: capture.manifest.componentSchemaVersions[key] + 1,
    }
    component_index = json.dumps(
        {
            "contractVersion": 2,
            "schemas": changed_schemas,
            "components": [
                component.model_dump(mode="json")
                for component in capture.manifest.components
            ],
        },
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("ascii")
    resources = [
        resource.model_copy(
            update={
                "byteLength": len(component_index),
                "sha256": hashlib.sha256(component_index).hexdigest(),
            }
        )
        if resource.id == "component-index"
        else resource
        for resource in capture.manifest.resources
    ]
    changed = BackupCapture(
        manifest=capture.manifest.model_copy(
            update={
                "componentSchemaVersions": changed_schemas,
                "resources": resources,
            }
        ),
        payloads={**capture.payloads, "component-index": component_index},
    )

    assert contract.open_bundle(_bundle(contract, capture), PASSPHRASE) == capture
    with pytest.raises(ApiError) as rejected:
        contract.open_bundle(_bundle(contract, changed), PASSPHRASE)
    assert rejected.value.code == "backup_decryption_failed"


def test_open_bundle_rejects_database_version_not_backed_by_database_cut(server):
    app, _client, _settings, _clock = server
    pair = ready(server)
    contract = app.state.core.core_backups
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    capture = contract.capture(actor)
    changed_version = capture.manifest.databaseSchemaVersion + 1
    resources = [
        resource.model_copy(update={"version": str(changed_version)})
        if resource.id == "core-database"
        else resource
        for resource in capture.manifest.resources
    ]
    changed = BackupCapture(
        manifest=capture.manifest.model_copy(
            update={
                "databaseSchemaVersion": changed_version,
                "resources": resources,
            }
        ),
        payloads=capture.payloads,
    )

    with pytest.raises(ApiError) as rejected:
        contract.open_bundle(_bundle(contract, changed), PASSPHRASE)
    assert rejected.value.code == "backup_decryption_failed"
