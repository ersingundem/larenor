"""Closed contract tests for native Music Assistant acceptance."""

import json
from pathlib import Path
import tempfile
import unittest

from larenor_server.plugins.music_assistant_core_models import (
    AuthenticatedMusicAssistantReadback,
)
from tool import music_assistant_managed_ci as target


class MusicAssistantManagedCITest(unittest.TestCase):
    def receipt(self, platform_name="linux/amd64"):
        source = target.fixture_source(platform_name)
        component = next(
            item.manifest
            for item in source.catalog.entries
            if item.manifest.serviceId == "music_assistant"
        )
        hashes = target.smoke.source_hashes()
        acceptance = target.acceptance_source_hashes()
        helper_digest = "sha256:" + "b" * 64
        return {
            "schemaVersion": 1,
            "result": "music_assistant_characterized",
            "serviceVersion": component.version,
            "platform": platform_name,
            "sourceCommit": "a" * 40,
            "catalogDigest": source.catalog.digest,
            "acceptanceSourceHashes": acceptance,
            "musicAssistantManifestDigest": source.image.image.digest,
            "musicAssistantConfigDigest": source.image.image.configDigest,
            "helper": {
                "configDigest": helper_digest,
                "platform": platform_name,
                "sourceCommit": "a" * 40,
                "publishedManifestDigest": None,
                "helperSourceSha256": hashes["tool/volume_bootstrap_helper.py"],
                "probeSourceSha256": hashes["tool/jellyfin_storage_probe.py"],
                "dockerfileSha256": hashes["server/Dockerfile.volume-bootstrap"],
                "sourceHashes": hashes,
            },
            "imageState": "ready",
            "networkState": "ready",
            "volumeStates": ["observed_requires_bootstrap"],
            "volumeCount": 1,
            "containerMode": "journaled_managed_v2",
            "containerJournalVersion": 2,
            "containerState": "music_assistant_container_started",
            "freshStateVerified": True,
            "bootstrapAuthenticated": True,
            "restartCount": 1,
            "restartTokenPersistent": True,
            "installAvailable": False,
        }

    def test_fixture_selects_only_pinned_owned_appdata_on_both_architectures(self):
        for platform_name in ("linux/amd64", "linux/arm64"):
            source = target.fixture_source(platform_name)
            self.assertEqual(source.image.image.platform, platform_name)
            self.assertEqual(source.image.serviceId, "music_assistant")
            self.assertEqual(
                [(item.serviceId, item.kind, item.target) for item in source.targets],
                [("music_assistant", "managed_appdata", "/data")],
            )

    def test_receipt_is_exact_and_rejects_private_or_optimistic_claims(self):
        value = self.receipt()
        target.validate_receipt(value, "a" * 40, "linux/amd64")
        for changed in (
            value | {"privateToken": "never-public"},
            value | {"installAvailable": True},
            value | {"restartTokenPersistent": False},
            value | {"acceptanceSourceHashes": {}},
        ):
            with self.assertRaises(target.MusicAssistantManagedCIError):
                target.validate_receipt(changed, "a" * 40, "linux/amd64")

    def test_restart_readback_proves_same_identity_with_retained_token(self):
        readback = AuthenticatedMusicAssistantReadback(
            token="private-native-token",
            serverId="mass-native",
            serverVersion="2.10.2",
            schemaVersion=65,
        )

        class Runtime:
            def __init__(self):
                self.calls = []

            def _rpc(self, installation, step, token, command, args, deadline,
                     cancelled, gate):
                self.calls.append((installation, step, token, command, args))
                self.assertions = (deadline, cancelled, gate())
                if command == "auth/me":
                    return {"username": "larenor-core", "role": "admin"}
                return {
                    "server_id": "mass-native",
                    "server_version": "2.10.2",
                    "schema_version": 65,
                    "onboard_done": True,
                }

        runtime = Runtime()
        target._authenticated_restart_readback(
            runtime, "a" * 32, readback, deadline=target.time.monotonic() + 1)
        self.assertEqual([call[3] for call in runtime.calls], ["auth/me", "info"])
        self.assertTrue(all(call[2] == "private-native-token" for call in runtime.calls))
        self.assertNotIn("private-native-token", repr(readback))

    def test_verify_rejects_duplicate_json_keys_without_echoing_values(self):
        with tempfile.TemporaryDirectory() as root:
            receipt = Path(root) / "receipt.json"
            receipt.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaises(target.MusicAssistantManagedCIError) as raised:
                target.verify(receipt)
        self.assertEqual(
            str(raised.exception),
            "music_assistant_characterization_evidence_invalid",
        )


if __name__ == "__main__":
    unittest.main()
