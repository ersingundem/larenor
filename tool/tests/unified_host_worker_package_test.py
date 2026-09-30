import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


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
        component = (root / "larenor-component-backup-worker.service").read_text()
        archive = (root / "larenor-media-archive-worker.service").read_text()
        ai = (root / "larenor-ai-worker.service").read_text()
        mesh = (root / "larenor-mesh-worker.service").read_text()
        proxmox = (root / "larenor-proxmox-power-worker.service").read_text()
        nut = (root / "larenor-nut-bridge.service").read_text()
        unmanic = (root / "larenor-unmanic.service").read_text()
        for unit in (preflight, installation, component, archive, ai, mesh,
                     proxmox, nut, unmanic):
            self.assertIn("NoNewPrivileges=yes", unit)
            self.assertIn("ProtectSystem=strict", unit)
            self.assertIn("Restart=on-failure", unit)
        self.assertIn("User=root", preflight)
        self.assertIn("User=root", installation)
        self.assertIn("ConditionPathIsSocket=/var/run/docker.sock", installation)
        self.assertIn(
            "/usr/libexec/larenor-installation-journals verify", installation
        )
        self.assertIn("User=root", component)
        self.assertIn("ConditionPathIsSocket=/var/run/docker.sock", component)
        self.assertIn("--container-journal /var/lib/larenor-server/host-workers/installation/containers", component)
        self.assertIn("--volume-journal /var/lib/larenor-server/host-workers/installation/volumes", component)
        self.assertIn("--capture-root /var/lib/larenor-server/host-workers/component-backup/captures", component)
        self.assertIn("--api-uid 10001 --socket-gid 10002", component)
        self.assertIn("--check-config", component)
        self.assertIn(
            "/usr/libexec/larenor-installation-journals verify", component
        )
        self.assertEqual(
            package.ASSETS["installation_journals.py"],
            (Path("/usr/libexec/larenor-installation-journals"), 0o755),
        )
        self.assertIn(
            '"/usr/libexec/larenor-installation-journals",\n        "initialize"',
            MODULE.read_text(),
        )
        tmpfiles = (root / "larenor-host-workers.tmpfiles").read_text()
        self.assertNotIn("host-workers/installation/resources", tmpfiles)
        self.assertNotIn("host-workers/installation/volumes", tmpfiles)
        self.assertNotIn("host-workers/installation/containers", tmpfiles)
        self.assertNotIn("/var/run/docker.sock", archive)
        self.assertIn("User=1000", archive)
        self.assertIn("SupplementaryGroups=10002", archive)
        self.assertIn("--check-config", archive)
        self.assertIn("--address 127.0.0.1", unmanic)
        self.assertIn("Requires=larenor-unmanic.service", archive)
        self.assertIn("User=10003", ai)
        self.assertIn("Group=10003", ai)
        self.assertIn("SupplementaryGroups=10002", ai)
        self.assertIn("XDG_RUNTIME_DIR=/run/user/10003", ai)
        self.assertIn("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/10003/bus", ai)
        self.assertNotIn("User=root", ai)
        self.assertIn("--check-config", ai)
        self.assertIn("User=10004", mesh)
        self.assertIn("Group=10004", mesh)
        self.assertIn("SupplementaryGroups=10002", mesh)
        self.assertIn("--core-uid 10001 --socket-gid 10002", mesh)
        self.assertIn("--check-config", mesh)
        self.assertNotIn("User=root", mesh)
        self.assertIn("User=10005", proxmox)
        self.assertIn("Group=10005", proxmox)
        self.assertIn("SupplementaryGroups=10002", proxmox)
        self.assertIn("--api-uid 10001 --socket-gid 10002", proxmox)
        self.assertIn("User=10006", nut)
        self.assertIn("Group=10006", nut)
        self.assertIn("RuntimeDirectory=larenor-power-recovery", nut)
        self.assertIn("upsmon.conf check-config", nut)
        provision = (root / "larenor-unmanic-provision.service").read_text()
        self.assertIn("User=1000", provision)
        self.assertIn("RestrictAddressFamilies=AF_UNIX", provision)
        self.assertIn("larenor-unmanic-provision", unmanic)
        helper = (root / "unmanic_provision.py").read_text()
        self.assertIn("install_plugin_from_path_on_disk", helper)
        self.assertIn('"larenor_archive_encoder"', helper)
        self.assertIn('"larenor_archive_terminal"', helper)

    def test_ai_worker_has_exact_private_identity_state_and_activation_contract(self):
        root = MODULE.parent
        sysusers = (root / "larenor-host-workers.sysusers").read_text()
        tmpfiles = (root / "larenor-host-workers.tmpfiles").read_text()
        self.assertIn("g larenor-ai 10003", sysusers)
        self.assertIn("u larenor-ai 10003:10003", sysusers)
        self.assertIn("m larenor-ai larenor-ipc", sysusers)
        self.assertIn(
            "d /var/lib/larenor-server/host-workers/ipc/ai 0770 10001 larenor-ipc",
            tmpfiles,
        )
        self.assertIn(
            "d /var/lib/larenor-server/host-workers/ai 0700 larenor-ai larenor-ai",
            tmpfiles,
        )
        self.assertIn((package.CONFIG / "ai/runtime.json", 10003), package.PRIVATE_CONFIGS)
        self.assertIn("larenor-ai-worker.service", package.UNITS)

    def test_mesh_worker_has_exact_private_identity_and_configuration(self):
        root = MODULE.parent
        sysusers = (root / "larenor-host-workers.sysusers").read_text()
        tmpfiles = (root / "larenor-host-workers.tmpfiles").read_text()
        self.assertIn("g larenor-mesh 10004", sysusers)
        self.assertIn("u larenor-mesh 10004:10004", sysusers)
        self.assertIn("m larenor-mesh larenor-ipc", sysusers)
        self.assertIn(
            "d /var/lib/larenor-server/host-workers/ipc/mesh 0770 larenor-mesh larenor-ipc",
            tmpfiles,
        )
        self.assertIn((package.CONFIG / "mesh/runtime.json", 10004), package.PRIVATE_CONFIGS)
        self.assertIn("larenor-mesh-worker.service", package.UNITS)

    def test_power_workers_have_exact_private_identities_and_configuration(self):
        root = MODULE.parent
        sysusers = (root / "larenor-host-workers.sysusers").read_text()
        tmpfiles = (root / "larenor-host-workers.tmpfiles").read_text()
        self.assertIn("u larenor-proxmox 10005:10005", sysusers)
        self.assertIn("m larenor-proxmox larenor-ipc", sysusers)
        self.assertIn("u larenor-power 10006:10006", sysusers)
        self.assertIn("m nut larenor-power", sysusers)
        self.assertIn("m larenor-power nut", sysusers)
        self.assertIn(
            "host-workers/ipc/proxmox 0770 larenor-proxmox larenor-ipc", tmpfiles,
        )
        self.assertIn((package.CONFIG / "proxmox/credential.bin", 10005),
                      package.PRIVATE_CONFIGS)
        self.assertIn((package.CONFIG / "proxmox/binding.key", 10005),
                      package.PRIVATE_CONFIGS)
        self.assertIn((package.CONFIG / "power-recovery/nut-bridge.json", 10006),
                      package.PRIVATE_CONFIGS)
        self.assertIn("larenor-proxmox-power-worker.service", package.UNITS)
        self.assertIn("larenor-nut-bridge.service", package.UNITS)
        self.assertEqual(
            package.ASSETS["nut_notify.py"],
            (Path("/usr/libexec/larenor-nut-notify"), 0o755),
        )

    def test_keenetic_key_pair_and_policy_reject_mismatch_before_activation(self):
        policy = {"version": 1, "adapter": "rci",
                  "secretFile": str(package.CONFIG / "keenetic/lease.key")}
        for key, change in ((b"b" * 32, {}), (b"a" * 31, {}),
                            (b"a" * 32, {"adapter": "unavailable"}),
                            (b"a" * 32, {"version": True}),
                            (b"a" * 32, {"secretFile": "/tmp/key"})):
            values = [b"a" * 32, key, json.dumps({**policy, **change}).encode()]
            with patch.object(package, "_read_regular", side_effect=values):
                with self.assertRaisesRegex(package.HostWorkerPackageError,
                                            "private_config_invalid"):
                    package._check_keenetic_lease_pair()
        with patch.object(package, "_read_regular", side_effect=[
                b"a" * 32, b"a" * 32, json.dumps(policy).encode()]) as read:
            package._check_keenetic_lease_pair()
        self.assertEqual(read.call_args_list[0].kwargs, {"owner": 10001, "mode": 0o600})
        self.assertEqual(read.call_args_list[1].kwargs, {"owner": 10008, "mode": 0o600})
        self.assertIn((package.CONFIG / "keenetic/policy.json", 10008),
                      package.PRIVATE_CONFIGS)
        self.assertIn("larenor-keenetic-worker.service", package.UNITS)
        tmpfiles = (MODULE.parent / "larenor-host-workers.tmpfiles").read_text()
        self.assertIn("ipc/keenetic 0750 larenor-keenetic larenor-ipc", tmpfiles)
        self.assertIn("/keenetic 0710 root larenor-keenetic", tmpfiles)

    def test_unified_core_separate_ipc_mount_preserves_private_data_and_host_boundary(self):
        compose = json.loads((ROOT / "deploy/larenor-server/unified.compose.yaml").read_text())
        core = compose["services"]["larenor-core"]
        self.assertEqual(core["group_add"], ["10002"])
        self.assertNotIn("/var/run/docker.sock", json.dumps(core))
        self.assertEqual({item["target"] for item in core["volumes"]},
                         {"/data", "/secrets", "/run/larenor-workers"})
        ipc_mount = next(m for m in core["volumes"] if m["target"] == "/run/larenor-workers")
        self.assertEqual(ipc_mount["source"], "/var/lib/larenor-server/host-workers/ipc")
        self.assertFalse(ipc_mount.get("read_only", False))
        self.assertFalse(ipc_mount["bind"]["create_host_path"])
        self.assertTrue(all(value.startswith("/run/larenor-workers/")
                            for key, value in core["environment"].items()
                            if key.endswith("_SOCKET")))
        self.assertEqual(core["environment"]["LARENOR_INSTALLATION_WORKER_UID"], "0")
        self.assertEqual(core["environment"]["LARENOR_COMPONENT_BACKUP_WORKER_UID"], "0")
        self.assertEqual(
            core["environment"]["LARENOR_COMPONENT_BACKUP_WORKER_SOCKET"],
            "/run/larenor-workers/root/component-backup.sock",
        )
        self.assertEqual(core["environment"]["LARENOR_MEDIA_ARCHIVE_WORKER_UID"], "1000")
        self.assertEqual(core["environment"]["LARENOR_MEDIA_ARCHIVE_SOCKET_GID"], "10002")
        self.assertEqual(core["environment"]["LARENOR_KEENETIC_WORKER_UID"], "10008")
        self.assertEqual(core["environment"]["LARENOR_KEENETIC_WORKER_LEASE_FILE"],
                         "/secrets/keenetic-worker.key")
        self.assertEqual(core["environment"]["LARENOR_AI_WORKER_UID"], "10003")
        self.assertEqual(core["environment"]["LARENOR_AI_WORKER_SOCKET_GID"], "10002")
        self.assertEqual(core["environment"]["LARENOR_AI_WORKER_SOCKET"],
                         "/run/larenor-workers/ai/runtime.sock")
        self.assertEqual(core["environment"]["LARENOR_MESH_WORKER_UID"], "10004")
        self.assertEqual(core["environment"]["LARENOR_MESH_WORKER_SOCKET_GID"], "10002")
        self.assertEqual(core["environment"]["LARENOR_MESH_WORKER_SOCKET"],
                         "/run/larenor-workers/mesh/runtime.sock")
        self.assertEqual(core["environment"]["LARENOR_PROXMOX_POWER_WORKER_UID"],
                         "10005")
        self.assertEqual(
            core["environment"]["LARENOR_PROXMOX_POWER_WORKER_SOCKET_GID"],
            "10002",
        )
        self.assertEqual(
            core["environment"]["LARENOR_PROXMOX_POWER_WORKER_SOCKET"],
            "/run/larenor-workers/proxmox/power.sock",
        )
        self.assertTrue(all(
            port.startswith("127.0.0.1:")
            for name in ("larenor-jellyfin", "larenor-sonarr",
                         "larenor-radarr", "larenor-qbittorrent")
            for port in compose["services"][name]["ports"]
        ))


if __name__ == "__main__":
    unittest.main()
