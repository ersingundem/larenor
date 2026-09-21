#!/usr/bin/env python3
"""Exercise an encrypted Core backup and empty-target restore in one image."""

import argparse
from pathlib import Path

from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.core_backups.restore import restore_empty

_PASSWORD = "Container acceptance password 2026"
_PASSPHRASE = "Container backup passphrase 2026"
_TOKEN = "container-acceptance-token"
_DOCUMENT = {
    "version": 1,
    "snapshot": {
        "version": 2,
        "createdAt": "2026-09-21T00:00:00Z",
        "groups": {
            "privacy": {
                "version": 1,
                "entityIds": ["sensor.container_acceptance"],
                "reviewRequired": True,
            },
            "connections": {
                "ha": {
                    "baseUrl": "http://container.invalid:8123",
                    "token": _TOKEN,
                }
            },
        },
    },
}


def _settings(root: Path, name: str) -> Settings:
    return Settings(
        root / f"{name}-data",
        root / f"{name}-secrets/vault.key",
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )


def run(root: Path) -> None:
    root = root.resolve()
    source_settings = _settings(root, "source")
    source = create_app(source_settings).state.core
    bootstrap = source_settings.effective_bootstrap_file.read_text().split(
        "password: ", 1
    )[1].strip()
    initial = source.auth.login("admin", bootstrap, "CI source", "127.0.0.1")
    principal = source.auth.authenticate(initial["accessToken"])
    changed = source.auth.change_password(principal, bootstrap, _PASSWORD)
    principal = source.auth.authenticate(changed["accessToken"])
    source.vault.put(principal, 0, _DOCUMENT)
    source_context = source.context
    source_key = source_settings.key_file.read_bytes()
    bundle = source.core_backups.export(principal, _PASSPHRASE)
    assert _TOKEN.encode() not in bundle
    assert source_key not in bundle

    target_settings = _settings(root, "target")
    restore_empty(target_settings, bundle, _PASSPHRASE)
    restored = create_app(target_settings).state.core
    pair = restored.auth.login("admin", _PASSWORD, "CI restored", "127.0.0.1")
    restored_principal = restored.auth.authenticate(pair["accessToken"])
    assert restored.context == source_context
    assert restored.vault.get(restored_principal) == {
        "revision": 1,
        "document": _DOCUMENT,
    }
    assert target_settings.key_file.read_bytes() == source_key

    restarted = create_app(target_settings).state.core
    pair = restarted.auth.login("admin", _PASSWORD, "CI restart", "127.0.0.1")
    restarted_principal = restarted.auth.authenticate(pair["accessToken"])
    assert restarted.context == source_context
    assert restarted.vault.get(restarted_principal)["document"] == _DOCUMENT
    assert not (target_settings.data_dir / ".restore-state.json").exists()
    assert not list(target_settings.data_dir.glob(".restore-*"))

    print("Encrypted empty-target restore and restart passed.")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args(argv)
    run(args.root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
