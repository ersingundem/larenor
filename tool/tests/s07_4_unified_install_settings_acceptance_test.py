import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "deploy/larenor-server/deployment_bundle.py"
SPEC = importlib.util.spec_from_file_location("s074_deployment_bundle", TARGET)
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)
REVISION = "a" * 40
SETTINGS = {
    "LARENOR_DATA_ROOT": "/DATA/AppData/larenor-server",
    "LARENOR_TIMEZONE": "Europe/Istanbul",
    "LARENOR_LOCALE": "tr_TR.UTF-8",
    "LARENOR_CORE_PORT": "18098",
}
SERVICES = (
    "larenor-jellyfin",
    "larenor-seerr",
    "larenor-sonarr",
    "larenor-radarr",
    "larenor-qbittorrent",
    "larenor-music-assistant",
)


class HostFacts:
    def __init__(self, manifest):
        self.manifest = manifest
        self.calls = []

    def architecture(self):
        self.calls.append("architecture")
        return "amd64"

    def inspect(self, path):
        self.calls.append(path)
        row = next(item for item in self.manifest["ownedPaths"] if item["path"] == path)
        return {
            "kind": "directory",
            "ownerUid": row["ownerUid"],
            "mode": 0o700,
            "device": 4,
            "availableMiB": self.manifest["requiredDiskMiB"] * 4,
        }

    def installation(self):
        self.calls.append("installation")
        return {
            "schemaVersion": 1,
            "state": "installed",
            "sourceRevision": "b" * 40,
            "manifestDigest": "c" * 64,
            "bundleDigest": "d" * 64,
            "architecture": "amd64",
        }


class S074UnifiedInstallSettingsAcceptanceTest(unittest.TestCase):
    def setUp(self):
        self.planner = bundle.DeploymentBundlePlanner(
            compose_path=ROOT / "deploy/larenor-server/unified.compose.yaml",
            catalog_path=ROOT / "server/larenor_server/plugins/packagedcatalog.json",
            env_example_path=ROOT / "deploy/larenor-server/.env.example",
        )

    def test_only_operator_settings_produce_one_deterministic_docker_and_casaos_package(
        self,
    ):
        first = self.planner.plan(REVISION, SETTINGS)
        second = self.planner.plan(REVISION, SETTINGS)
        self.assertEqual(first, second)
        self.assertEqual(first["settings"], SETTINGS)
        self.assertEqual(
            set(first),
            {
                "schemaVersion",
                "settings",
                "dockerCompose",
                "casaOsCompose",
                "deploymentManifest",
                "bundleDigest",
            },
        )
        for key in ("dockerCompose", "casaOsCompose"):
            services = first[key]["services"]
            self.assertEqual(set(services), {"larenor-core", *SERVICES})
            for name in ("larenor-sonarr", "larenor-radarr", "larenor-qbittorrent"):
                self.assertEqual(
                    services[name]["tmpfs"],
                    [
                        "/run:rw,nosuid,nodev,exec,size=64m,uid=1000,gid=1000,mode=1777",
                        "/tmp:rw,nosuid,nodev,noexec,size=128m,uid=1000,gid=1000,mode=1777",
                    ],
                )
        self.assertEqual(first["casaOsCompose"]["x-casaos"]["main"], "larenor-core")

    def test_internal_wiring_is_secret_free_and_exact_without_manual_service_addresses(
        self,
    ):
        value = self.planner.plan(REVISION, SETTINGS)
        encoded = json.dumps(value, sort_keys=True).lower()
        for private in (
            "token",
            "password",
            "credential",
            "authorization",
            "api_key",
            "apikey",
            "secretvalue",
        ):
            self.assertNotIn(private, encoded)
        services = value["dockerCompose"]["services"]
        self.assertEqual(
            services["larenor-core"]["networks"]["control"]["aliases"], ["core"]
        )
        for name in SERVICES[:-1]:
            service_id = name.removeprefix("larenor-")
            self.assertEqual(
                services[name]["networks"]["control"]["aliases"], [service_id]
            )
            self.assertNotIn("ports", services[name])
            self.assertNotIn("dns", services[name])
        self.assertEqual(services["larenor-music-assistant"]["network_mode"], "host")
        self.assertNotIn("networks", services["larenor-music-assistant"])

    def test_upgrade_preview_is_bounded_and_rollback_cancel_or_stale_bundle_fail_closed(
        self,
    ):
        value = self.planner.plan(REVISION, SETTINGS)
        manifest = value["deploymentManifest"]
        host = HostFacts(manifest)
        preview = self.planner.preflight(value, "upgrade", host)
        self.assertTrue(preview["ready"])
        self.assertEqual(preview["backupTarget"], manifest["backupTarget"])
        self.assertEqual(preview["rollbackTarget"], manifest["rollbackTarget"])
        self.assertNotEqual(preview["backupTarget"], preview["rollbackTarget"])

        for operation in ("rollback", "cancel"):
            with (
                self.subTest(operation=operation),
                self.assertRaisesRegex(bundle.BundleError, "bundle_operation_invalid"),
            ):
                self.planner.preflight(value, operation, HostFacts(manifest))

        stale = copy.deepcopy(value)
        stale["deploymentManifest"]["sourceRevision"] = "b" * 40
        with self.assertRaisesRegex(bundle.BundleError, "bundle_invalid"):
            self.planner.preflight(stale, "upgrade", HostFacts(manifest))


if __name__ == "__main__":
    unittest.main()
