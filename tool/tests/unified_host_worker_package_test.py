import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "deploy/larenor-server/host_workers/install.py"
SPEC = importlib.util.spec_from_file_location("host_worker_install", MODULE)
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)
BUILDER_SPEC = importlib.util.spec_from_file_location(
    "host_worker_bundle", MODULE.with_name("build_bundle.py"))
builder = importlib.util.module_from_spec(BUILDER_SPEC)
BUILDER_SPEC.loader.exec_module(builder)


class UnifiedHostWorkerPackageTest(unittest.TestCase):
    def test_builder_produces_the_exact_installable_offline_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            server, unmanic = root / "inputs/server", root / "inputs/unmanic"
            server.mkdir(parents=True)
            unmanic.mkdir(parents=True)
            (server / "larenor_server-0.1.0-py3-none-any.whl").write_bytes(b"server")
            (server / "dependency-1.0-py3-none-any.whl").write_bytes(b"dependency")
            (unmanic / "unmanic-0.4.1-py3-none-any.whl").write_bytes(b"unmanic")
            manifest = builder.build(root / "bundle", server, unmanic,
                                     "a" * 40, "linux/amd64")
            loaded = package.load_bundle(manifest, expected_platform="linux/amd64")
            self.assertEqual(package.preview(loaded)["sourceRevision"], "a" * 40)
            self.assertEqual({item.name for item in (root / "bundle/server").iterdir()},
                             {"larenor_server-0.1.0-py3-none-any.whl",
                              "dependency-1.0-py3-none-any.whl"})

    def bundle(self, root):
        root = Path(root)
        (root / "server").mkdir()
        (root / "unmanic").mkdir()
        server_name = "larenor_server-0.1.0-py3-none-any.whl"
        unmanic_name = "unmanic-0.4.1-py3-none-any.whl"
        (root / "server" / server_name).write_bytes(b"server-wheel")
        (root / "unmanic" / unmanic_name).write_bytes(b"unmanic-wheel")
        value = {
            "schemaVersion": 1,
            "sourceRevision": "a" * 40,
            "platform": "linux/amd64",
            "serverWheels": [{
                "file": server_name,
                "sha256": hashlib.sha256(b"server-wheel").hexdigest(),
            }],
            "unmanic": {
                "version": "0.4.1",
                "upstreamRevision": package.UNMANIC_REVISION,
                "wheels": [{
                    "file": unmanic_name,
                    "sha256": hashlib.sha256(b"unmanic-wheel").hexdigest(),
                }],
            },
        }
        manifest = root / "bundle.json"
        manifest.write_text(json.dumps(value))
        return manifest

    def test_offline_bundle_is_hash_complete_and_preview_never_enables_services(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.bundle(directory)
            loaded = package.load_bundle(manifest, expected_platform="linux/amd64")
            first = package.preview(loaded)
            second = package.preview(loaded)
            self.assertEqual(first, second)
            self.assertFalse(first["startsServices"])
            self.assertFalse(first["createsPrivateConfiguration"])
            self.assertEqual(first["unmanicRevision"], package.UNMANIC_REVISION)
            self.assertRegex(first["packageDigest"], r"^[0-9a-f]{64}$")

            (Path(directory) / "server/foreign.whl").write_bytes(b"foreign")
            with self.assertRaisesRegex(package.HostWorkerPackageError, "bundle_invalid"):
                package.load_bundle(manifest, expected_platform="linux/amd64")

    def test_bundle_rejects_drift_symlink_duplicate_and_wrong_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.bundle(directory)
            value = json.loads(manifest.read_text())
            changes = (
                lambda row: row["serverWheels"][0].update(sha256="f" * 64),
                lambda row: row.update(platform="linux/arm64"),
                lambda row: row["unmanic"].update(upstreamRevision="f" * 40),
            )
            for change in changes:
                changed = json.loads(json.dumps(value))
                change(changed)
                manifest.write_text(json.dumps(changed))
                with self.assertRaisesRegex(package.HostWorkerPackageError, "bundle_invalid"):
                    package.load_bundle(manifest, expected_platform="linux/amd64")
            manifest.write_text(json.dumps(value))
            wheel = Path(directory) / "server" / value["serverWheels"][0]["file"]
            wheel.unlink()
            wheel.symlink_to(Path(directory) / "unmanic" / value["unmanic"]["wheels"][0]["file"])
            with self.assertRaisesRegex(package.HostWorkerPackageError, "bundle_invalid"):
                package.load_bundle(manifest, expected_platform="linux/amd64")

    def test_units_keep_docker_authority_on_host_and_archive_on_real_media_uid(self):
        root = MODULE.parent
        preflight = (root / "larenor-preflight-worker.service").read_text()
        installation = (root / "larenor-installation-worker.service").read_text()
        archive = (root / "larenor-media-archive-worker.service").read_text()
        unmanic = (root / "larenor-unmanic.service").read_text()
        for unit in (preflight, installation, archive, unmanic):
            self.assertIn("NoNewPrivileges=yes", unit)
            self.assertIn("ProtectSystem=strict", unit)
            self.assertIn("Restart=on-failure", unit)
        self.assertIn("User=root", preflight)
        self.assertIn("User=root", installation)
        self.assertIn("ConditionPathIsSocket=/var/run/docker.sock", installation)
        self.assertNotIn("/var/run/docker.sock", archive)
        self.assertIn("User=1000", archive)
        self.assertIn("SupplementaryGroups=10002", archive)
        self.assertIn("--check-config", archive)
        self.assertIn("--address 127.0.0.1", unmanic)
        self.assertIn("Requires=larenor-unmanic.service", archive)
        provision = (root / "larenor-unmanic-provision.service").read_text()
        self.assertIn("User=1000", provision)
        self.assertIn("RestrictAddressFamilies=AF_UNIX", provision)
        self.assertIn("larenor-unmanic-provision", unmanic)
        helper = (root / "unmanic_provision.py").read_text()
        self.assertIn("install_plugin_from_path_on_disk", helper)
        self.assertIn('"larenor_archive_encoder"', helper)
        self.assertIn('"larenor_archive_terminal"', helper)

    def test_unified_core_reuses_data_mount_for_ipc_and_preserves_host_docker_boundary(self):
        compose = json.loads((ROOT / "deploy/larenor-server/unified.compose.yaml").read_text())
        core = compose["services"]["larenor-core"]
        self.assertEqual(core["group_add"], ["10002"])
        self.assertNotIn("/var/run/docker.sock", json.dumps(core))
        self.assertEqual({item["target"] for item in core["volumes"]},
                         {"/data", "/secrets"})
        self.assertTrue(all(value.startswith("/data/host-workers/ipc/")
                            for key, value in core["environment"].items()
                            if key.endswith("_SOCKET")))
        self.assertEqual(core["environment"]["LARENOR_INSTALLATION_WORKER_UID"], "0")
        self.assertEqual(core["environment"]["LARENOR_MEDIA_ARCHIVE_WORKER_UID"], "1000")
        self.assertEqual(core["environment"]["LARENOR_MEDIA_ARCHIVE_SOCKET_GID"], "10002")
        self.assertTrue(all(
            port.startswith("127.0.0.1:")
            for name in ("larenor-jellyfin", "larenor-sonarr",
                         "larenor-radarr", "larenor-qbittorrent")
            for port in compose["services"][name]["ports"]
        ))


if __name__ == "__main__":
    unittest.main()
