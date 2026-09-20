"""Closed contract tests for native Music Assistant acceptance."""

import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest

from tool import music_assistant_managed_ci as target

SERVER_DEPENDENCIES_AVAILABLE = (
    importlib.util.find_spec("pydantic") is not None
    and importlib.util.find_spec("larenor_server") is not None
)


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
            "playerReadbackVerified": True,
            "installAvailable": False,
        }

    @unittest.skipUnless(SERVER_DEPENDENCIES_AVAILABLE, "server dependencies unavailable")
    def test_fixture_selects_only_pinned_owned_appdata_on_both_architectures(self):
        for platform_name in ("linux/amd64", "linux/arm64"):
            source = target.fixture_source(platform_name)
            self.assertEqual(source.image.image.platform, platform_name)
            self.assertEqual(source.image.serviceId, "music_assistant")
            self.assertEqual(
                [(item.serviceId, item.kind, item.target, item.containerUser)
                 for item in source.targets],
                [("music_assistant", "managed_appdata", "/data", "0:0")],
            )

    @unittest.skipUnless(SERVER_DEPENDENCIES_AVAILABLE, "server dependencies unavailable")
    def test_receipt_is_exact_and_rejects_private_or_optimistic_claims(self):
        value = self.receipt()
        target.validate_receipt(value, "a" * 40, "linux/amd64")
        for changed in (
            value | {"privateToken": "never-public"},
            value | {"installAvailable": True},
            value | {"restartTokenPersistent": False},
            value | {"playerReadbackVerified": False},
            value | {"acceptanceSourceHashes": {}},
        ):
            with self.assertRaises(target.MusicAssistantManagedCIError):
                target.validate_receipt(changed, "a" * 40, "linux/amd64")

    @unittest.skipUnless(SERVER_DEPENDENCIES_AVAILABLE, "server dependencies unavailable")
    def test_restart_readback_proves_same_identity_with_retained_token(self):
        class Readback:
            token = "private-native-token"
            serverId = "mass-native"
            serverVersion = "2.10.2"
            schemaVersion = 65

            def __repr__(self):
                return "Readback(<private>)"

        readback = Readback()

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

    @unittest.skipUnless(SERVER_DEPENDENCIES_AVAILABLE, "server dependencies unavailable")
    def test_authenticated_player_readback_accepts_bounded_empty_native_state(self):
        class Runtime:
            def read(self, authority, *, deadline):
                self.authority = authority
                self.deadline = deadline
                from larenor_server.plugins.music_playback_models import MusicPlaybackReadback
                return MusicPlaybackReadback(players=[])

        runtime = Runtime()
        target._authenticated_player_readback(
            runtime, "a" * 32, "private-native-token",
            deadline=target.time.monotonic() + 1)
        self.assertEqual(runtime.authority.installationId, "a" * 32)
        self.assertEqual(runtime.authority.token, "private-native-token")

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

    def test_container_create_failure_preserves_only_closed_diagnostic(self):
        receipt = SimpleNamespace(
            state="uncertain",
            code="engine_operation_uncertain",
            container_id=None,
        )
        engine = SimpleNamespace(
            managed_create_diagnostic="managed_create_cgroup_rejected",
        )
        with self.assertRaises(target.MusicAssistantManagedCIError) as raised:
            target._require_container_created(receipt, engine)
        self.assertEqual(str(raised.exception), "managed_create_cgroup_rejected")

        engine.managed_create_diagnostic = "private /runner/path token=secret"
        with self.assertRaises(target.MusicAssistantManagedCIError) as raised:
            target._require_container_created(receipt, engine)
        self.assertEqual(str(raised.exception), "managed_create_uncertain")
        self.assertNotIn("private", repr(raised.exception))

    def test_container_liveness_reduces_exit_state_to_closed_diagnostic(self):
        class Engine:
            value = {"State": {"Running": False, "OOMKilled": False}}

            def inspect_container(self, _name):
                return self.value

        engine = Engine()
        with self.assertRaises(target.MusicAssistantManagedCIError) as raised:
            target._require_running(engine, "larenor-" + "a" * 32)
        self.assertEqual(str(raised.exception), "music_assistant_container_exited")

        engine.value = {"State": {"Running": False, "OOMKilled": True}}
        with self.assertRaises(target.MusicAssistantManagedCIError) as raised:
            target._require_running(engine, "larenor-" + "a" * 32)
        self.assertEqual(
            str(raised.exception), "music_assistant_container_oom_killed")

    def test_container_exit_logs_reduce_to_allowlisted_diagnostics(self):
        class Response:
            status = 200
            body = b"fatal: Read-only file system: /private/path"

        class Engine:
            value = b"fatal: Read-only file system: /private/path"

            def _exchange(self, _method, _target):
                Response.body = self.value
                return Response()

        engine = Engine()
        self.assertEqual(
            target._closed_exit_diagnostic(engine, "a" * 64),
            "music_assistant_container_readonly_root",
        )
        engine.value = b"PermissionError: [Errno 13] Permission denied: '/data/settings'"
        self.assertEqual(
            target._closed_exit_diagnostic(engine, "a" * 64),
            "music_assistant_container_data_permission_denied",
        )
        engine.value = b"unrecognized private upstream output"
        self.assertEqual(
            target._closed_exit_diagnostic(engine, "a" * 64),
            "music_assistant_container_exited",
        )
        self.assertNotIn("private", target._closed_exit_diagnostic(engine, "a" * 64))


if __name__ == "__main__":
    unittest.main()
