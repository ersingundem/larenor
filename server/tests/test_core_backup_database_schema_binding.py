import hashlib
import json
import secrets
import sqlite3

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


def _changed_database_capture(capture, database):
    resources = [
        resource.model_copy(
            update={
                "byteLength": len(database),
                "sha256": hashlib.sha256(database).hexdigest(),
            }
        )
        if resource.id == "core-database"
        else resource
        for resource in capture.manifest.resources
    ]
    return BackupCapture(
        manifest=capture.manifest.model_copy(update={"resources": resources}),
        payloads={**capture.payloads, "core-database": database},
    )


def _edit_database(payload, path, edit):
    database_image = bytearray(payload)
    database_image[18:20] = b"\x01\x01"
    path.write_bytes(database_image)
    with sqlite3.connect(path) as database:
        edit(database)
    return path.read_bytes()


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


def test_open_bundle_rejects_recursive_metadata_view(server, tmp_path):
    app, _client, _settings, _clock = server
    pair = ready(server)
    contract = app.state.core.core_backups
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    capture = contract.capture(actor)

    def replace_metadata_with_recursive_view(database):
        database.execute("ALTER TABLE metadata RENAME TO metadata_backing")
        database.execute(
            """
            CREATE VIEW metadata AS
            WITH RECURSIVE once(value) AS (
                VALUES(1)
                UNION ALL SELECT value + 1 FROM once WHERE value < 1
            )
            SELECT key, metadata_backing.value
            FROM metadata_backing JOIN once ON once.value = 1
            """
        )

    database = _edit_database(
        capture.payloads["core-database"],
        tmp_path / "recursive-view.sqlite3",
        replace_metadata_with_recursive_view,
    )
    changed = _changed_database_capture(capture, database)

    with pytest.raises(ApiError) as rejected:
        contract.open_bundle(_bundle(contract, changed), PASSPHRASE)
    assert rejected.value.code == "backup_decryption_failed"


def test_open_bundle_maps_database_vm_budget_interruption_to_static_error(
    server, tmp_path
):
    app, _client, _settings, _clock = server
    pair = ready(server)
    contract = app.state.core.core_backups
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    capture = contract.capture(actor)

    def add_scan_padding(database):
        database.executemany(
            "INSERT INTO metadata(key,value) VALUES(?,?)",
            ((f"padding_{index:05d}", "1") for index in range(50_000)),
        )

    database = _edit_database(
        capture.payloads["core-database"],
        tmp_path / "scan-padding.sqlite3",
        add_scan_padding,
    )
    changed = _changed_database_capture(capture, database)

    with pytest.raises(ApiError) as rejected:
        contract.open_bundle(_bundle(contract, changed), PASSPHRASE)
    assert rejected.value.code == "backup_decryption_failed"
