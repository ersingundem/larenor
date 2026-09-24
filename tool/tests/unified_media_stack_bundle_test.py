import importlib.util
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


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
    def __init__(self, planner, target, *, architecture="amd64", change=None,
                 installation="default", clean=True):
        manifest = target["deploymentManifest"]
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
        prior = planner.plan("b" * 40, target["settings"])
        normalized_architecture = ({
            "x86_64": "amd64", "aarch64": "arm64",
        }.get(architecture, architecture) if isinstance(architecture, str)
            else "unknown")
        receipt_architecture = (
            normalized_architecture
            if normalized_architecture in {"amd64", "arm64"}
            else "amd64"
        )
        self.installed = (planner.installed_state_receipt(
            prior,
            installation_id="e" * 32,
            architecture=receipt_architecture,
        ) if installation == "default" else installation)
        self.clean_state = clean

    def architecture(self):
        self.calls.append("architecture")
        return self.selected_architecture

    def inspect(self, path):
        self.calls.append(path)
        return dict(self.facts[path])

    def installation(self):
        self.calls.append("installation")
        return copy.deepcopy(self.installed)

    def clean(self, paths):
        self.calls.append("clean")
        self.clean_paths = tuple(paths)
        return self.clean_state


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
            for name in ("larenor-sonarr", "larenor-radarr", "larenor-qbittorrent"):
                self.assertEqual(compose["services"][name]["tmpfs"], [
                    "/run:rw,nosuid,nodev,exec,size=64m,uid=1000,gid=1000,mode=1777",
                    "/tmp:rw,nosuid,nodev,noexec,size=128m,uid=1000,gid=1000,mode=1777",
                ])
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
            lambda item: item["casaOsCompose"]["services"]["larenor-sonarr"].update(
                {"tmpfs": []}),
        ):
            changed = copy.deepcopy(first)
            mutate(changed)
            with self.assertRaisesRegex(bundle.BundleError, "bundle_invalid"):
                self.planner.preflight(
                    changed,
                    "install",
                    HostFacts(self.planner, first, installation=None),
                )

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
            host = HostFacts(
                self.planner,
                value,
                installation=None if operation == "install" else "default",
            )
            preview = self.planner.preflight(value, operation, host)
            self.assertTrue(preview["ready"])
            self.assertEqual(preview["operation"], operation)
            self.assertEqual(preview["architecture"], "amd64")
            self.assertEqual(preview["backupTarget"], "/DATA/AppData/larenor-server-backups")
            self.assertEqual(preview["rollbackTarget"], "/DATA/AppData/larenor-server-rollback")
            self.assertEqual(host.calls[:2], ["architecture", "installation"])
            offset = 2
            if operation == "install":
                self.assertEqual(host.calls[2], "clean")
                self.assertEqual(
                    set(host.clean_paths),
                    {item["path"] for item in manifest["ownedPaths"]},
                )
                offset = 3
            self.assertEqual(set(host.calls[offset:]), {
                item["path"] for item in manifest["ownedPaths"]})
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
                host = HostFacts(
                    self.planner, value, architecture=architecture, change=change)
                preview = self.planner.preflight(value, "upgrade", host)
                self.assertFalse(preview["ready"])
                self.assertIn(code, {item["code"] for item in preview["checks"]})
        with self.assertRaisesRegex(bundle.BundleError, "bundle_operation_invalid"):
            self.planner.preflight(
                value, "apply", HostFacts(self.planner, value))
        normalized = self.planner.preflight(
            value, "install", HostFacts(
                self.planner, value, architecture="x86_64", installation=None))
        self.assertEqual(normalized["architecture"], "amd64")
        changed = copy.deepcopy(value)
        changed["deploymentManifest"]["manifestDigest"] = "f" * 64
        with self.assertRaisesRegex(bundle.BundleError, "bundle_invalid"):
            self.planner.preflight(
                changed, "upgrade", HostFacts(self.planner, value))
        source = TARGET.read_text()
        for forbidden_import in ("import subprocess", "import socket", "import docker"):
            self.assertNotIn(forbidden_import, source)

    def test_install_and_upgrade_require_exact_opposite_installation_states(self):
        value = self.plan()
        manifest = value["deploymentManifest"]

        installed = HostFacts(self.planner, value).installed
        assert installed is not None
        install = self.planner.preflight(
            value, "install", HostFacts(
                self.planner, value, installation=installed))
        self.assertFalse(install["ready"])
        self.assertIn("installation_already_exists", {
            item["code"] for item in install["checks"]})

        missing = self.planner.preflight(
            value, "upgrade", HostFacts(
                self.planner, value, installation=None))
        self.assertFalse(missing["ready"])
        self.assertIn("installation_missing", {
            item["code"] for item in missing["checks"]})

        dirty = self.planner.preflight(
            value,
            "install",
            HostFacts(
                self.planner,
                value,
                installation=None,
                clean=False,
            ),
        )
        self.assertFalse(dirty["ready"])
        self.assertIn("installation_not_clean", {
            item["code"] for item in dirty["checks"]})

        already_current = self.planner.installed_state_receipt(
            value, installation_id="e" * 32, architecture="amd64")
        current = self.planner.preflight(
            value, "upgrade", HostFacts(
                self.planner, value, installation=already_current))
        self.assertFalse(current["ready"])
        self.assertIn("installation_already_current", {
            item["code"] for item in current["checks"]})

        for changed, code in (
            ({"schemaVersion": 1}, "installation_receipt_invalid"),
            (self.planner.installed_state_receipt(
                self.planner.plan("b" * 40, SETTINGS),
                installation_id="e" * 32,
                architecture="arm64",
            ), "installation_architecture_mismatch"),
            (dict(installed, sourceRevision=1.0), "installation_receipt_invalid"),
            (dict(installed, schemaVersion=True), "installation_receipt_invalid"),
            (dict(installed, schemaVersion=1.0), "installation_receipt_invalid"),
            (self.planner.installed_state_receipt(
                self.planner.plan("b" * 40, dict(
                    SETTINGS, LARENOR_DATA_ROOT="/DATA/AppData/foreign")),
                installation_id="e" * 32,
                architecture="amd64",
            ), "installation_foreign"),
        ):
            with self.subTest(code=code):
                preview = self.planner.preflight(
                    value, "upgrade", HostFacts(
                        self.planner, value, installation=changed))
                self.assertFalse(preview["ready"])
                self.assertIn(code, {item["code"] for item in preview["checks"]})

        newer = dict(installed, releaseVersion="1.0.0")
        newer["receiptDigest"] = bundle._digest({
            key: item for key, item in newer.items() if key != "receiptDigest"
        })
        downgrade = self.planner.preflight(
            value,
            "upgrade",
            HostFacts(self.planner, value, installation=newer),
        )
        self.assertFalse(downgrade["ready"])
        self.assertIn("installation_not_upgradeable", {
            item["code"] for item in downgrade["checks"]})

        for host_architecture, receipt_architecture in (
            ("amd64", "amd64"),
            ("x86_64", "amd64"),
            ("arm64", "arm64"),
            ("aarch64", "arm64"),
        ):
            with self.subTest(architecture=host_architecture):
                prior = self.planner.plan("b" * 40, SETTINGS)
                receipt = self.planner.installed_state_receipt(
                    prior,
                    installation_id="e" * 32,
                    architecture=receipt_architecture,
                )
                preview = self.planner.preflight(
                    value,
                    "upgrade",
                    HostFacts(
                        self.planner,
                        value,
                        architecture=host_architecture,
                        installation=receipt,
                    ),
                )
                self.assertTrue(preview["ready"])
                self.assertEqual(preview["architecture"], receipt_architecture)

    def test_local_receipt_reader_is_bounded_descriptor_owned_and_duplicate_safe(self):
        value = self.plan()
        receipt = self.planner.installed_state_receipt(
            self.planner.plan("b" * 40, SETTINGS),
            installation_id="e" * 32,
            architecture="amd64",
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "installation"
            root.mkdir(mode=0o700)
            path = root / ".larenor-installation.json"
            path.write_text(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")
            path.chmod(0o600)
            reader = bundle.LocalHostFacts(
                root,
                expected_uid=os.geteuid(),
                architecture="amd64",
            )
            self.assertEqual(reader.installation(), receipt)
            self.assertEqual(reader.architecture(), "amd64")
            self.assertEqual(reader.inspect(str(root))["kind"], "directory")

            path.unlink()
            path.write_text('{"schemaVersion":1,"schemaVersion":1}')
            path.chmod(0o600)
            with self.assertRaisesRegex(
                bundle.BundleError, "bundle_host_inspection_invalid"):
                reader.installation()

            path.unlink()
            path.write_bytes(b"x" * (bundle.MAX_INSTALLATION_RECEIPT_BYTES + 1))
            path.chmod(0o600)
            with self.assertRaisesRegex(
                bundle.BundleError, "bundle_host_inspection_invalid"):
                reader.installation()

            path.unlink()
            path.write_text(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")
            path.chmod(0o644)
            with self.assertRaisesRegex(
                bundle.BundleError, "bundle_host_inspection_invalid"):
                reader.installation()

            path.unlink()
            foreign = root / "foreign"
            foreign.write_text("{}")
            path.symlink_to(foreign)
            with self.assertRaisesRegex(
                bundle.BundleError, "bundle_host_inspection_invalid"):
                reader.installation()

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "clean"
            child = root / "child"
            child.mkdir(parents=True)
            root.chmod(0o700)
            child.chmod(0o700)
            reader = bundle.LocalHostFacts(
                root,
                expected_uid=os.geteuid(),
                architecture="amd64",
            )
            self.assertTrue(reader.clean((str(root), str(child))))
            (child / "foreign-payload").write_text("foreign")
            self.assertFalse(reader.clean((str(root), str(child))))

        class WiredHost:
            def __init__(self, *_args, **_kwargs):
                pass

            def architecture(self):
                return "amd64"

            def installation(self):
                return None

            def clean(self, _paths):
                return True

            def inspect(self, path):
                requirement = next(
                    item for item in value["deploymentManifest"]["ownedPaths"]
                    if item["path"] == path)
                return {
                    "kind": "directory", "ownerUid": requirement["ownerUid"],
                    "mode": 0o700, "device": 1,
                    "availableMiB": value["deploymentManifest"]["requiredDiskMiB"] * 2,
                }

        with patch.object(bundle, "LocalHostFacts", WiredHost), patch.object(
            bundle.DeploymentBundlePlanner,
            "plan",
            return_value=value,
        ), patch("sys.stdout") as stdout:
            self.assertEqual(bundle.main([
                "--source-revision", REVISION,
                "--operation", "install",
            ]), 0)
            self.assertTrue(stdout.write.called)

    def test_local_host_facts_rejects_ancestor_symlinks_and_path_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            real = base / "real"
            root = real / "root"
            child = root / "mid" / "leaf"
            child.mkdir(parents=True)
            for path in (real, root, root / "mid", child):
                path.chmod(0o700)
            alias = base / "alias"
            alias.symlink_to(real, target_is_directory=True)
            selected = alias / "root"
            reader = bundle.LocalHostFacts(
                selected,
                expected_uid=os.geteuid(),
                architecture="amd64",
            )
            for operation in (
                lambda: reader.inspect(str(selected)),
                reader.installation,
                lambda: reader.clean((
                    str(selected),
                    str(selected / "mid"),
                    str(selected / "mid" / "leaf"),
                )),
            ):
                with self.subTest(operation=operation):
                    with self.assertRaisesRegex(
                        bundle.BundleError, "bundle_host_inspection_invalid"
                    ):
                        operation()

        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / "root"
            middle = root / "mid"
            leaf = middle / "leaf"
            leaf.mkdir(parents=True)
            outside = base / "outside"
            (outside / "leaf").mkdir(parents=True)
            for path in (root, middle, leaf, outside, outside / "leaf"):
                path.chmod(0o700)
            reader = bundle.LocalHostFacts(
                root,
                expected_uid=os.geteuid(),
                architecture="amd64",
            )
            real_open = os.open
            switched = False

            def racing_open(path, flags, *args, **kwargs):
                nonlocal switched
                descriptor = real_open(path, flags, *args, **kwargs)
                if not switched and (str(path) == str(middle) or path == "mid"):
                    switched = True
                    middle.rename(base / "parked")
                    middle.symlink_to(outside, target_is_directory=True)
                return descriptor

            with patch.object(bundle.os, "open", racing_open):
                with self.assertRaisesRegex(
                    bundle.BundleError, "bundle_host_inspection_invalid"
                ):
                    reader.clean((str(root), str(middle), str(leaf)))

    def test_local_receipt_reader_rejects_rewrite_and_fifo_without_blocking(self):
        first = self.planner.installed_state_receipt(
            self.planner.plan("b" * 40, SETTINGS),
            installation_id="e" * 32,
            architecture="amd64",
        )
        second = self.planner.installed_state_receipt(
            self.planner.plan("b" * 40, SETTINGS),
            installation_id="f" * 32,
            architecture="amd64",
        )
        first_raw = (json.dumps(
            first, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
        second_raw = (json.dumps(
            second, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")
        self.assertEqual(len(first_raw), len(second_raw))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "installation"
            root.mkdir(mode=0o700)
            receipt = root / bundle.INSTALLATION_RECEIPT_NAME
            receipt.write_bytes(first_raw)
            receipt.chmod(0o600)
            reader = bundle.LocalHostFacts(
                root,
                expected_uid=os.geteuid(),
                architecture="amd64",
            )
            real_read = os.read
            changed = False

            def racing_read(descriptor, size):
                nonlocal changed
                chunk = real_read(descriptor, size)
                if chunk and not changed:
                    changed = True
                    receipt.write_bytes(second_raw)
                    receipt.chmod(0o600)
                return chunk

            with patch.object(bundle.os, "read", racing_read):
                with self.assertRaisesRegex(
                    bundle.BundleError, "bundle_host_inspection_invalid"
                ):
                    reader.installation()

            receipt.unlink()
            os.mkfifo(receipt, mode=0o600)
            real_open = os.open

            def require_nonblocking(path, flags, *args, **kwargs):
                if path == bundle.INSTALLATION_RECEIPT_NAME:
                    self.assertTrue(flags & os.O_NONBLOCK)
                return real_open(path, flags, *args, **kwargs)

            with patch.object(bundle.os, "open", require_nonblocking):
                with self.assertRaisesRegex(
                    bundle.BundleError, "bundle_host_inspection_invalid"
                ):
                    reader.installation()

    def test_local_clean_inventory_stops_at_the_bounded_limit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "installation"
            root.mkdir(mode=0o700)
            for index in range(257):
                (root / f"foreign-{index:03d}").touch()
            reader = bundle.LocalHostFacts(
                root,
                expected_uid=os.geteuid(),
                architecture="amd64",
            )
            with patch.object(
                bundle.os,
                "listdir",
                side_effect=AssertionError("unbounded listdir is forbidden"),
            ):
                self.assertFalse(reader.clean((str(root),)))


if __name__ == "__main__":
    unittest.main()
