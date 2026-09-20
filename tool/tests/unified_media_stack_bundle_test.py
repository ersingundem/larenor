import importlib.util
import copy
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "deploy/larenor-server/deployment_bundle.py"
SPEC = importlib.util.spec_from_file_location("deployment_bundle", TARGET)
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)
REVISION = "a" * 40
SETTINGS = {
    "LARENOR_DATA_ROOT": "/DATA/AppData/larenor-server",
    "LARENOR_TIMEZONE": "Europe/Istanbul",
    "LARENOR_LOCALE": "tr_TR.UTF-8",
    "LARENOR_CORE_PORT": "18098",
}
COMPONENTS = ("jellyfin", "seerr", "sonarr", "radarr", "qbittorrent", "music_assistant")


class HostFacts:
    def __init__(self, manifest, *, architecture="amd64", change=None):
        self.calls = []
        self.selected_architecture = architecture
        self.facts = {}
        for item in manifest["ownedPaths"]:
            self.facts[item["path"]] = {
                "kind": "directory", "ownerUid": item["ownerUid"], "mode": 0o700,
                "device": 9, "availableMiB": manifest["requiredDiskMiB"] * 4,
            }
        if change:
            path, values = change
            self.facts[path].update(values)

    def architecture(self):
        self.calls.append("architecture")
        return self.selected_architecture

    def inspect(self, path):
        self.calls.append(path)
        return dict(self.facts[path])


class UnifiedMediaStackBundleTest(unittest.TestCase):
    def setUp(self):
        self.planner = bundle.DeploymentBundlePlanner(
            compose_path=ROOT / "deploy/larenor-server/unified.compose.yaml",
            catalog_path=ROOT / "server/larenor_server/plugins/packagedcatalog.json",
            env_example_path=ROOT / "deploy/larenor-server/.env.example",
        )

    def plan(self):
        return self.planner.plan(REVISION, SETTINGS)

    def test_one_canonical_definition_generates_compose_and_casaos_without_public_internals(self):
        first, second = self.plan(), self.plan()
        self.assertEqual(first, second)
        self.assertEqual(first["schemaVersion"], 1)
        manifest = first["deploymentManifest"]
        self.assertEqual(manifest["entrypoint"], {
            "service": "larenor-core", "hostPort": 18098, "containerPort": 8098,
        })
        self.assertRegex(manifest["settingsSchemaDigest"], r"^[a-f0-9]{64}$")
        self.assertIn({"path": SETTINGS["LARENOR_DATA_ROOT"], "ownerUid": 10001,
                       "requiredMiB": 0, "private": True}, manifest["ownedPaths"])
        self.assertIn({"path": SETTINGS["LARENOR_DATA_ROOT"] + "/components",
                       "ownerUid": 10001, "requiredMiB": 0, "private": True},
                      manifest["ownedPaths"])
        self.assertFalse(manifest["backupTarget"].startswith(
            SETTINGS["LARENOR_DATA_ROOT"] + "/"))
        self.assertFalse(manifest["rollbackTarget"].startswith(
            SETTINGS["LARENOR_DATA_ROOT"] + "/"))
        self.assertEqual(tuple(item["serviceId"] for item in manifest["components"]), COMPONENTS)
        self.assertTrue(all("@sha256:" in item["image"] for item in manifest["components"]))
        for key in ("dockerCompose", "casaOsCompose"):
            compose = first[key]
            self.assertEqual(set(compose["services"]), {
                "larenor-core", *("larenor-" + item.replace("_", "-") for item in COMPONENTS),
            })
            self.assertEqual(compose["services"]["larenor-core"]["ports"], ["18098:8098"])
            self.assertNotIn("build", compose["services"]["larenor-core"])
            self.assertEqual(
                compose["services"]["larenor-core"]["image"],
                "ghcr.io/ersingundem/larenor-server:sha-" + REVISION,
            )
            for name, service in compose["services"].items():
                if name != "larenor-core":
                    self.assertNotIn("ports", service)
                if service.get("network_mode") == "host":
                    self.assertEqual(name, "larenor-music-assistant")
        casaos = first["casaOsCompose"]["x-casaos"]
        self.assertEqual(casaos["main"], "larenor-core")
        self.assertEqual(casaos["architectures"], ["amd64", "arm64"])
        self.assertEqual(casaos["port_map"], "18098")
        self.assertEqual(casaos["id"], "com.larenor.core")
        self.assertEqual(casaos["version"], "0.1.0")
        self.assertEqual(set(casaos["title"]), {"en_US", "tr_TR"})
        self.assertEqual(
            casaos["icon"],
            "https://raw.githubusercontent.com/ersingundem/larenor/" + REVISION
            + "/deploy/larenor-server/icon.png",
        )
        for mutate in (
            lambda item: item["casaOsCompose"]["x-casaos"].update({"main": "larenor-seerr"}),
            lambda item: item["dockerCompose"]["services"]["larenor-seerr"].update(
                {"ports": ["5055:5055"]}),
            lambda item: item["dockerCompose"]["services"]["larenor-jellyfin"].update(
                {"image": "ghcr.io/jellyfin/jellyfin:latest"}),
        ):
            changed = copy.deepcopy(first)
            mutate(changed)
            with self.assertRaisesRegex(bundle.BundleError, "bundle_invalid"):
                self.planner.preflight(changed, "install", HostFacts(manifest))

    def test_only_four_operator_settings_are_secret_free_and_bind_both_bundles(self):
        example = bundle.read_settings(ROOT / "deploy/larenor-server/.env.example")
        self.assertEqual(set(example), set(SETTINGS))
        value = self.plan()
        encoded = json.dumps(value, sort_keys=True).lower()
        for forbidden in ("token", "password", "credential", "authorization", "secretvalue"):
            self.assertNotIn(forbidden, encoded)
        self.assertEqual(value["settings"], SETTINGS)
        for compose in (value["dockerCompose"], value["casaOsCompose"]):
            for service in compose["services"].values():
                self.assertEqual(service["environment"]["LANG"], "tr_TR.UTF-8")
                self.assertEqual(service["environment"]["LC_ALL"], "tr_TR.UTF-8")
                self.assertEqual(service["environment"]["TZ"], "Europe/Istanbul")
                for mount in service["volumes"]:
                    self.assertTrue(mount["source"].startswith(SETTINGS["LARENOR_DATA_ROOT"] + "/"))
        invalid = dict(SETTINGS, LARENOR_API_TOKEN="private")
        with self.assertRaisesRegex(bundle.BundleError, "bundle_settings_invalid"):
            self.planner.plan(REVISION, invalid)
        for port in (" 18098", "+18098", "018098", "18098 "):
            with self.subTest(port=port):
                with self.assertRaisesRegex(bundle.BundleError, "bundle_settings_invalid"):
                    self.planner.plan(REVISION, dict(SETTINGS, LARENOR_CORE_PORT=port))

    def test_install_and_upgrade_preview_fail_closed_without_daemon_mutation(self):
        value = self.plan()
        manifest = value["deploymentManifest"]
        for operation in ("install", "upgrade"):
            host = HostFacts(manifest)
            preview = self.planner.preflight(value, operation, host)
            self.assertTrue(preview["ready"])
            self.assertEqual(preview["operation"], operation)
            self.assertEqual(preview["architecture"], "amd64")
            self.assertEqual(preview["backupTarget"], "/DATA/AppData/larenor-server-backups")
            self.assertEqual(preview["rollbackTarget"], "/DATA/AppData/larenor-server-rollback")
            self.assertEqual(host.calls[0], "architecture")
            self.assertEqual(set(host.calls[1:]), {item["path"] for item in manifest["ownedPaths"]})
            self.assertNotRegex(json.dumps(preview).lower(), r"docker|subprocess|daemon|token|password")

        first = next(item["path"] for item in manifest["ownedPaths"]
                     if item["requiredMiB"] > 0)
        root = SETTINGS["LARENOR_DATA_ROOT"]
        for architecture, change, code in (
            ("s390x", None, "architecture_unsupported"),
            (["amd64"], None, "architecture_unsupported"),
            ("amd64", (root, {"kind": "symlink"}), "owned_path_invalid"),
            ("amd64", (root + "/components", {"kind": "symlink"}),
             "owned_path_invalid"),
            ("amd64", (first, {"availableMiB": 0}), "storage_capacity_insufficient"),
        ):
            with self.subTest(code=code):
                host = HostFacts(manifest, architecture=architecture, change=change)
                preview = self.planner.preflight(value, "upgrade", host)
                self.assertFalse(preview["ready"])
                self.assertIn(code, {item["code"] for item in preview["checks"]})
        with self.assertRaisesRegex(bundle.BundleError, "bundle_operation_invalid"):
            self.planner.preflight(value, "apply", HostFacts(manifest))
        normalized = self.planner.preflight(
            value, "install", HostFacts(manifest, architecture="x86_64"))
        self.assertEqual(normalized["architecture"], "amd64")
        changed = copy.deepcopy(value)
        changed["deploymentManifest"]["manifestDigest"] = "f" * 64
        with self.assertRaisesRegex(bundle.BundleError, "bundle_invalid"):
            self.planner.preflight(changed, "upgrade", HostFacts(manifest))
        source = TARGET.read_text()
        for forbidden_import in ("import subprocess", "import socket", "import docker"):
            self.assertNotIn(forbidden_import, source)


if __name__ == "__main__":
    unittest.main()
