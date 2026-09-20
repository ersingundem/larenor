import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "deploy/larenor-server/unified.compose.yaml"
CATALOG = ROOT / "server/larenor_server/plugins/packagedcatalog.json"
SERVICE_NAMES = {
    "jellyfin": "larenor-jellyfin",
    "seerr": "larenor-seerr",
    "sonarr": "larenor-sonarr",
    "radarr": "larenor-radarr",
    "qbittorrent": "larenor-qbittorrent",
    "music_assistant": "larenor-music-assistant",
}
OWNED_ROOT = "/var/lib/larenor-server"


class UnifiedMediaStackDeploymentTest(unittest.TestCase):
    def load(self):
        return json.loads(PACKAGE.read_text())

    def test_one_distribution_contains_core_and_six_exact_catalog_pins(self):
        document = self.load()
        catalog = json.loads(CATALOG.read_text())
        services = document["services"]
        self.assertEqual(document["name"], "larenor-server")
        self.assertEqual(set(services), {"larenor-core", *SERVICE_NAMES.values()})
        self.assertEqual(services["larenor-core"]["container_name"], "larenor-core")
        self.assertEqual(services["larenor-core"]["build"], {
            "context": "../..", "dockerfile": "server/Dockerfile",
            "args": {
                "LARENOR_SOURCE_REVISION":
                    "${LARENOR_SOURCE_REVISION:?exact source revision required}",
            },
        })
        self.assertEqual(
            services["larenor-core"]["image"],
            "ghcr.io/ersingundem/larenor-server:sha-${LARENOR_SOURCE_REVISION}"
        )
        self.assertEqual(services["larenor-core"]["labels"], {
            "io.larenor.component": "core",
            "io.larenor.version": "${LARENOR_SOURCE_REVISION}",
            "io.larenor.license": "AGPL-3.0-only",
        })
        entries = {entry["serviceId"]: entry for entry in catalog["entries"]}
        self.assertEqual(set(entries), set(SERVICE_NAMES))
        for service_id, compose_name in SERVICE_NAMES.items():
            entry = entries[service_id]
            self.assertEqual(
                services[compose_name]["image"],
                entry["repository"] + "@" + entry["indexDigest"],
            )
            self.assertNotIn(":latest", services[compose_name]["image"])
            self.assertEqual(
                {item["platform"] for item in entry["images"]},
                {"linux/amd64", "linux/arm64"},
            )
            self.assertEqual(services[compose_name]["labels"], {
                "io.larenor.component": service_id,
                "io.larenor.version": entry["version"],
                "io.larenor.license": entry["distributionLicense"],
                "io.larenor.source-revision": entry["sourceRevision"],
            })
            self.assertEqual(services[compose_name]["user"], entry["security"]["user"])
            self.assertEqual(services[compose_name]["cap_drop"], ["ALL"])
            self.assertEqual(
                services[compose_name].get("cap_add", []),
                entry["security"]["capAdd"],
            )
            self.assertEqual(
                services[compose_name]["security_opt"],
                ["no-new-privileges:true"],
            )
            self.assertEqual(
                services[compose_name].get("init", False),
                entry["security"]["init"],
            )

    def test_names_network_and_owned_bindings_are_deterministic(self):
        document = self.load()
        services = document["services"]
        self.assertEqual(document["networks"], {
            "control": {"name": "larenor-server-control-v1", "driver": "bridge"}
        })
        expected_targets = {
            "larenor-core": {"/data", "/secrets"},
            "larenor-jellyfin": {"/config", "/cache", "/media"},
            "larenor-seerr": {"/app/config"},
            "larenor-sonarr": {"/config", "/data"},
            "larenor-radarr": {"/config", "/data"},
            "larenor-qbittorrent": {"/config", "/data"},
            "larenor-music-assistant": {"/data", "/media"},
        }
        for name, service in services.items():
            self.assertEqual(service["container_name"], name)
            targets = {mount["target"] for mount in service["volumes"]}
            self.assertEqual(targets, expected_targets[name])
            for mount in service["volumes"]:
                self.assertEqual(mount["type"], "bind")
                self.assertTrue(mount["source"].startswith(OWNED_ROOT + "/"))
                self.assertEqual(mount["bind"], {"create_host_path": False})
        for name in ({"larenor-core", *SERVICE_NAMES.values()}
                     - {"larenor-music-assistant"}):
            alias = "core" if name == "larenor-core" else name.removeprefix("larenor-")
            self.assertNotIn("dns", services[name])
            self.assertEqual(services[name]["networks"], {
                "control": {"aliases": [alias]},
            })
        music = services["larenor-music-assistant"]
        self.assertEqual(music["network_mode"], "host")
        self.assertNotIn("networks", music)
        self.assertEqual(services["larenor-core"]["extra_hosts"], [
            "host.docker.internal:host-gateway"])
        self.assertEqual(services["larenor-core"]["links"], [
            "larenor-jellyfin:jellyfin",
            "larenor-seerr:seerr",
            "larenor-sonarr:sonarr",
            "larenor-radarr:radarr",
            "larenor-qbittorrent:qbittorrent",
        ])

    def test_package_never_requests_or_serializes_interservice_secrets(self):
        document = self.load()
        encoded = json.dumps(document, sort_keys=True)
        self.assertNotRegex(
            encoded,
            re.compile(r"\$\{[^}]*(?:TOKEN|API_KEY|PASSWORD|CREDENTIAL|URL)[^}]*\}", re.I),
        )
        for service in document["services"].values():
            self.assertNotIn("env_file", service)
            self.assertNotIn("secrets", service)
            environment = service.get("environment", {})
            self.assertTrue(all(
                not re.search(r"token|api.?key|password|credential|base.?url", key, re.I)
                for key in environment
            ))
        self.assertNotIn("depends_on", document["services"]["larenor-core"])
        self.assertNotIn("http://", encoded)
        self.assertNotIn("https://", encoded)


if __name__ == "__main__":
    unittest.main()
