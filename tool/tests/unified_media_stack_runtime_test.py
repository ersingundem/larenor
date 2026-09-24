import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "deploy/larenor-server/unified_package.py"
SPEC = importlib.util.spec_from_file_location("unified_package", TARGET)
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)
REVISION = "a" * 40
COMPONENTS = (
    "jellyfin", "seerr", "sonarr", "radarr", "qbittorrent", "music_assistant",
)


class ConfigBackend:
    def __init__(self, mutate=None):
        self.calls = []
        self.mutate = mutate

    def config(self, compose_path, source_revision):
        self.calls.append(("config", Path(compose_path).name, source_revision))
        value = json.loads(Path(compose_path).read_text())
        encoded = json.dumps(value).replace(
            "${LARENOR_SOURCE_REVISION:?exact source revision required}", source_revision,
        ).replace("${LARENOR_SOURCE_REVISION}", source_revision)
        value = json.loads(encoded)
        if self.mutate:
            self.mutate(value)
        return value


class HostFacts:
    def __init__(self, requirements, *, failure=None):
        self.calls = []
        self.facts = {}
        for requirement in requirements:
            self.facts[requirement["path"]] = {
                "kind": "directory",
                "ownerUid": requirement["ownerUid"],
                "mode": 0o700,
                "device": 7,
                "availableMiB": 100_000,
            }
        if failure:
            path, changes = failure
            self.facts[path].update(changes)

    def inspect(self, path):
        self.calls.append(path)
        return dict(self.facts[path])


class RuntimeBackend:
    def __init__(self, manifest):
        self.calls = []
        self.manifest = manifest

    def pull(self, manifest):
        self.calls.append("pull")
        return [{"serviceId": item["serviceId"], "image": item["image"],
                 "state": "pulled"} for item in manifest["components"]]

    def up(self, manifest):
        self.calls.append("up")
        return [{"serviceId": item["serviceId"],
                 "containerName": item["containerName"],
                 "image": item["image"], "containerId": str(index + 1) * 64,
                 "state": "running"}
                for index, item in enumerate(manifest["components"])]


class AuthenticatedReadiness:
    def __init__(self, failed=None):
        self.calls = []
        self.failed = failed

    def read(self, service_id):
        self.calls.append(service_id)
        return {"serviceId": service_id,
                "authenticated": service_id != self.failed,
                "state": "ready" if service_id != self.failed else "unavailable",
                "code": "authenticated_readback_verified" if service_id != self.failed
                        else "authenticated_readback_unavailable"}


class UnifiedPackageRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.planner = package.UnifiedPackagePlanner(
            compose_path=ROOT / "deploy/larenor-server/unified.compose.yaml",
            catalog_path=ROOT / "server/larenor_server/plugins/packagedcatalog.json",
        )

    def preview(self):
        backend = ConfigBackend()
        first = self.planner.preview(REVISION, backend)
        second = self.planner.preview(REVISION, backend)
        self.assertEqual(first, second)
        return first, backend

    def test_config_preview_is_deterministic_exact_and_secret_free(self):
        preview, backend = self.preview()
        self.assertEqual(backend.calls, [
            ("config", "unified.compose.yaml", REVISION),
            ("config", "unified.compose.yaml", REVISION),
        ])
        self.assertEqual(preview["schemaVersion"], 1)
        self.assertEqual(preview["project"], "larenor-server")
        self.assertEqual(preview["sourceRevision"], REVISION)
        self.assertRegex(preview["manifestDigest"], r"^[a-f0-9]{64}$")
        self.assertEqual(tuple(x["serviceId"] for x in preview["components"]), COMPONENTS)
        self.assertEqual(
            {x["serviceId"]: x["health"] for x in preview["components"]},
            {
                "jellyfin": {"profile": "jellyfin_public", "path": "/health", "port": 8096},
                "seerr": {"profile": "seerr_public", "path": "/api/v1/settings/public", "port": 5055},
                "sonarr": {"profile": "sonarr_public", "path": "/ping", "port": 8989},
                "radarr": {"profile": "radarr_public", "path": "/ping", "port": 7878},
                "qbittorrent": {"profile": "qbittorrent_web", "path": "/", "port": 8080},
                "music_assistant": {"profile": "music_assistant_info", "path": "/info", "port": 8095},
            },
        )
        tmpfs = {item["serviceId"]: item["tmpfs"] for item in preview["components"]}
        self.assertEqual([item["target"] for item in tmpfs["sonarr"]], ["/run", "/tmp"])
        self.assertTrue(tmpfs["sonarr"][0]["executable"])
        self.assertFalse(tmpfs["sonarr"][1]["executable"])
        self.assertEqual(tmpfs["radarr"], tmpfs["sonarr"])
        self.assertEqual(tmpfs["qbittorrent"], tmpfs["sonarr"])
        self.assertEqual(preview["directoryRequirements"], sorted(
            preview["directoryRequirements"], key=lambda item: item["path"]))
        encoded = json.dumps(preview, sort_keys=True)
        for forbidden in ("token", "password", "credential", "secretValue", "environment"):
            self.assertNotIn(forbidden.lower(), encoded.lower())
        changed = ConfigBackend(lambda value: value["services"]["larenor-seerr"].update(
            {"container_name": "foreign-seerr"}))
        with self.assertRaisesRegex(package.PackageError, "config_identity_changed"):
            self.planner.preview(REVISION, changed)
        private = ConfigBackend(lambda value: value["services"]["larenor-seerr"].update(
            {"environment": {"API_TOKEN": "must-never-be-rendered"}}))
        with self.assertRaisesRegex(package.PackageError, "config_private_value"):
            self.planner.preview(REVISION, private)
        with self.assertRaisesRegex(package.PackageError, "invalid_source_revision"):
            self.planner.preview("main", ConfigBackend())
        changed_manifest = json.loads(json.dumps(preview))
        changed_manifest["components"][0]["containerName"] = "foreign-jellyfin"
        body = dict(changed_manifest)
        body.pop("manifestDigest")
        changed_manifest["manifestDigest"] = package._digest(body)
        with self.assertRaisesRegex(package.PackageError, "manifest_invalid"):
            self.planner.preflight(changed_manifest, HostFacts(
                changed_manifest["directoryRequirements"]))
        changed_manifest = json.loads(json.dumps(preview))
        changed_manifest["components"][2]["tmpfs"] = []
        body = dict(changed_manifest)
        body.pop("manifestDigest")
        changed_manifest["manifestDigest"] = package._digest(body)
        with self.assertRaisesRegex(package.PackageError, "manifest_invalid"):
            self.planner.preflight(changed_manifest, HostFacts(
                changed_manifest["directoryRequirements"]))
        changed_manifest = json.loads(json.dumps(preview))
        changed_manifest["components"][0]["health"]["path"] = "/redirect"
        body = dict(changed_manifest)
        body.pop("manifestDigest")
        changed_manifest["manifestDigest"] = package._digest(body)
        with self.assertRaisesRegex(package.PackageError, "manifest_invalid"):
            self.planner.preflight(changed_manifest, HostFacts(
                changed_manifest["directoryRequirements"]))

    def test_trusted_compose_rejects_noncanonical_paths_and_out_of_range_ids(self):
        original = json.loads(
            (ROOT / "deploy/larenor-server/unified.compose.yaml").read_text())
        mutations = (
            lambda value: value["services"]["larenor-seerr"]["volumes"][0].update(
                {"source": "/var/lib/larenor-server/../foreign"}),
            lambda value: value["services"]["larenor-seerr"]["volumes"][0].update(
                {"target": "/app/../foreign"}),
            lambda value: value["services"]["larenor-seerr"].update(
                {"user": "1000:2147483648"}),
            lambda value: value["services"]["larenor-sonarr"].update(
                {"tmpfs": ["/run:rw,nosuid,nodev,noexec,size=64m,uid=1000,gid=1000,mode=1777"]}),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as directory:
                changed = json.loads(json.dumps(original))
                mutate(changed)
                compose_path = Path(directory) / "unified.compose.yaml"
                compose_path.write_text(json.dumps(changed))
                planner = package.UnifiedPackagePlanner(
                    compose_path=compose_path,
                    catalog_path=ROOT / "server/larenor_server/plugins/packagedcatalog.json",
                )
                with self.assertRaisesRegex(package.PackageError, "config_identity_changed"):
                    planner.preview(REVISION, ConfigBackend())

    def test_owned_directory_preflight_fails_closed_before_runtime_mutation(self):
        preview, _ = self.preview()
        host = HostFacts(preview["directoryRequirements"])
        passed = self.planner.preflight(preview, host)
        self.assertEqual(passed["state"], "passed")
        self.assertTrue(passed["ready"])
        self.assertEqual(host.calls, [x["path"] for x in preview["directoryRequirements"]])

        first = preview["directoryRequirements"][0]["path"]
        failures = (
            {"kind": "symlink"},
            {"ownerUid": 65534},
            {"mode": 0o722},
            {"availableMiB": 1},
            {"availableMiB": None},
        )
        runtime = RuntimeBackend(preview)
        readiness = AuthenticatedReadiness()
        for changes in failures:
            result = self.planner.preflight(preview, HostFacts(
                preview["directoryRequirements"], failure=(first, changes)))
            self.assertEqual(result["state"], "failed")
            self.assertFalse(result["ready"])
            with self.assertRaisesRegex(package.PackageError, "preflight_not_passed"):
                self.planner.apply(preview, result, runtime, readiness)
        self.assertEqual(runtime.calls, [])
        self.assertEqual(readiness.calls, [])

    def test_container_receipts_and_authenticated_readiness_are_separate(self):
        preview, _ = self.preview()
        preflight = self.planner.preflight(
            preview, HostFacts(preview["directoryRequirements"]))
        runtime = RuntimeBackend(preview)
        readiness = AuthenticatedReadiness(failed="seerr")
        result = self.planner.apply(preview, preflight, runtime, readiness)
        self.assertEqual(runtime.calls, ["pull", "up"])
        self.assertEqual(readiness.calls, list(COMPONENTS))
        self.assertEqual(result["containerState"], "verified")
        self.assertEqual(result["serviceState"], "needs_attention")
        self.assertFalse(result["automaticRetry"])
        self.assertEqual(tuple(result["services"]), COMPONENTS)
        for service_id, value in result["services"].items():
            self.assertEqual(value["imageReceipt"]["state"], "pulled")
            self.assertEqual(value["containerReceipt"]["state"], "running")
            self.assertEqual(value["authenticatedReadiness"]["state"],
                             "unavailable" if service_id == "seerr" else "ready")
        encoded = json.dumps(result, sort_keys=True)
        self.assertNotRegex(encoded.lower(), r"token|password|credential|secret|authorization")

        broken_runtime = RuntimeBackend(preview)
        original = broken_runtime.up

        def wrong(manifest):
            values = original(manifest)
            values[0]["image"] = "foreign/image@sha256:" + "0" * 64
            return values
        broken_runtime.up = wrong
        with self.assertRaisesRegex(package.PackageError, "container_receipt_invalid"):
            self.planner.apply(preview, preflight, broken_runtime, AuthenticatedReadiness())


if __name__ == "__main__":
    unittest.main()
