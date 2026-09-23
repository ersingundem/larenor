"""Exact final-bundle limits for the encrypted Core backup transport."""

import hashlib

import pytest
from conftest import ready
from larenor_server.core_backups import service as backup_service
from larenor_server.core_backups.service import BackupCapture
from larenor_server.errors import ApiError

PASSPHRASE = "Correct horse battery staple 2026"


def test_final_bundle_ceiling_includes_header_nonce_and_authentication_tag(
    server, monkeypatch
):
    app, _client, _settings, _clock = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    contract = app.state.core.core_backups
    production_cap = backup_service.MAX_BUNDLE_BYTES
    capture = contract.capture(actor)
    payloads = {
        **capture.payloads,
        "core-database": b"synthetic sqlite fixture",
        "family-board": b"synthetic family board fixture",
        "vault-key": b"k" * 32,
    }
    resources = [
        resource.model_copy(
            update={
                "byteLength": len(payloads[resource.id]),
                "sha256": hashlib.sha256(payloads[resource.id]).hexdigest(),
            }
        )
        for resource in capture.manifest.resources
    ]
    capture = BackupCapture(
        manifest=capture.manifest.model_copy(update={"resources": resources}),
        payloads=payloads,
    )
    archive = contract._archive(capture)
    envelope_bytes = len(backup_service.MAGIC) + 16 + 12 + 16
    monkeypatch.setattr(contract, "capture", lambda _actor: capture)

    monkeypatch.setattr(
        backup_service,
        "MAX_BUNDLE_BYTES",
        len(archive) + envelope_bytes - 1,
    )
    with pytest.raises(ApiError, match="^backup_too_large$"):
        contract.export(actor, PASSPHRASE)

    exact_cap = len(archive) + envelope_bytes
    monkeypatch.setattr(backup_service, "MAX_BUNDLE_BYTES", exact_cap)
    bundle = contract.export(actor, PASSPHRASE)

    assert backup_service.BUNDLE_ENVELOPE_BYTES == envelope_bytes
    assert len(bundle) == exact_cap
    monkeypatch.setattr(backup_service, "MAX_BUNDLE_BYTES", production_cap)
    opened = contract.open_bundle(bundle, PASSPHRASE)
    assert opened.manifest == capture.manifest
    assert opened.payloads == capture.payloads
