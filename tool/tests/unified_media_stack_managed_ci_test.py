import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import call, patch


ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "tool/unified_media_stack_managed_ci.py"
SPEC = importlib.util.spec_from_file_location("unified_media_stack_managed_ci", TARGET)
target = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(target)
REVISION = "a" * 40
COMPONENTS = (
    "jellyfin", "seerr", "sonarr", "radarr", "qbittorrent", "music_assistant",
)


class FakeDriver:
    def __init__(self, *, missing=None, fail_at=None):
        self.calls = []
        self.missing = missing
        self.fail_at = fail_at
        self.config_digest = "b" * 64
        self.ownership_digest = "c" * 64
        self.requirements = None

    def _call(self, name):
        self.calls.append(name)
        if self.fail_at == name:
            raise RuntimeError("private adapter details")

    def config(self, path, revision):
        self._call("config")
        raw = Path(path).read_text().replace(
            "${LARENOR_SOURCE_REVISION:?exact source revision required}", revision,
        ).replace("${LARENOR_SOURCE_REVISION}", revision)
        return json.loads(raw)

    def prepare_owned(self, manifest):
        self._call("prepare_owned")
        self.requirements = manifest["directoryRequirements"]

    def inspect(self, path):
        self._call("inspect")
        item = next(value for value in self.requirements if value["path"] == path)
        return {"kind": "directory", "ownerUid": item["ownerUid"], "mode": 0o700,
                "device": 7, "availableMiB": 100_000}

    def pull(self, manifest):
        self._call("pull")
        return [{"serviceId": item["serviceId"], "image": item["image"], "state": "pulled"}
                for item in manifest["components"]]

    def create(self, manifest):
        self._call("create")

    def start(self, manifest):
        self._call("start")

    def receipts(self, manifest, phase):
        self._call("receipts:" + phase)
        values = []
        for index, item in enumerate(manifest["components"]):
            if item["serviceId"] == self.missing:
                continue
            values.append({
                "serviceId": item["serviceId"], "containerName": item["containerName"],
                "image": item["image"], "containerId": format(index + 1, "064x"),
                "state": "running", "dns": "host_network" if item["serviceId"] == "music_assistant" else "verified",
                "network": "host" if item["serviceId"] == "music_assistant" else "larenor-server-control-v1",
                "mounts": [{"target": mount["target"], "readOnly": mount["readOnly"]}
                           for mount in item["mounts"]],
            })
        return values

    def restart(self, manifest):
        self._call("restart")

    def authenticated_readiness(self, service_id):
        self._call("readiness:" + service_id)
        return {"serviceId": service_id, "state": "not_verified",
                "code": "bootstrap_authority_not_available"}

    def cleanup(self):
        self.calls.append("cleanup")


class UnifiedMediaStackManagedCITest(unittest.TestCase):
    def launch_environment(self, **changed):
        value = {
            "EXPECTED_PLATFORM": "linux/amd64", "RUNNER_ARCH": "X64",
            "RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": "refs/heads/main", "GITHUB_BASE_REF": "",
            "PR_HEAD_REPOSITORY": "", "GITHUB_REPOSITORY": "ersingundem/larenor",
            "GITHUB_SHA": REVISION, "GITHUB_WORKFLOW_SHA": REVISION,
            "CI": "true", "GITHUB_ACTIONS": "true",
        }
        value.update(changed)
        return value

    def test_launch_accepts_hosted_main_or_same_repository_pull_request_only(self):
        with patch.object(target.platform, "machine", return_value="x86_64"), patch.object(
                target.platform, "system", return_value="Linux"), patch.object(
                target.os, "geteuid", return_value=0):
            self.assertEqual(target.validate_launch(self.launch_environment()), "linux/amd64")
            pull_request = self.launch_environment(
                GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/181/merge",
                GITHUB_BASE_REF="main", PR_HEAD_REPOSITORY="ersingundem/larenor",
            )
            self.assertEqual(target.validate_launch(pull_request), "linux/amd64")
            for changed in (
                {"RUNNER_ENVIRONMENT": "self-hosted"},
                {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_REF": "refs/pull/181/merge",
                 "GITHUB_BASE_REF": "main", "PR_HEAD_REPOSITORY": "foreign/fork"},
                {"GITHUB_WORKFLOW_SHA": "b" * 40},
            ):
                with self.subTest(changed=changed):
                    with self.assertRaisesRegex(target.ManagedStackCIError,
                                                "unified_launch_invalid"):
                        target.validate_launch(self.launch_environment(**changed))

    def test_native_chain_is_exact_on_both_architectures_and_secret_free(self):
        for platform_name in ("linux/amd64", "linux/arm64"):
            driver = FakeDriver()
            value = target.run_native(REVISION, platform_name, driver)
            target.validate_receipt(value, REVISION, platform_name)
            self.assertEqual(driver.calls[:4], ["config", "prepare_owned", "inspect", "inspect"])
            self.assertEqual(driver.calls.count("inspect"), 10)
            self.assertEqual(driver.calls[12:18], [
                "pull", "create", "start", "receipts:initial", "restart", "receipts:restart",
            ])
            self.assertEqual(driver.calls[-7:-1], ["readiness:" + item for item in COMPONENTS])
            self.assertEqual(driver.calls[-1], "cleanup")
            self.assertEqual(value["lifecycle"], ["config", "pull", "create", "start", "restart"])
            self.assertEqual(value["containerState"], "verified")
            self.assertEqual(value["serviceState"], "not_verified")
            self.assertFalse(value["automaticRetry"])
            encoded = json.dumps(value, sort_keys=True).lower()
            self.assertNotRegex(encoded, r"token|password|credential|authorization|/var/lib")

    def test_missing_or_ambiguous_service_fails_closed_and_always_cleans_owned_state(self):
        for driver in (FakeDriver(missing="seerr"), FakeDriver(fail_at="restart")):
            with self.assertRaises(target.ManagedStackCIError) as raised:
                target.run_native(REVISION, "linux/amd64", driver)
            self.assertIn(str(raised.exception), {
                "unified_container_receipt_invalid", "unified_native_runtime_failed",
            })
            self.assertEqual(driver.calls[-1], "cleanup")
            self.assertNotIn("private", str(raised.exception))

    def test_rendered_compose_security_drift_is_rejected_before_prepare(self):
        expected = json.loads((ROOT / "deploy/larenor-server/unified.compose.yaml").read_text())
        encoded = json.dumps(expected).replace(
            "${LARENOR_SOURCE_REVISION:?exact source revision required}", REVISION,
        ).replace("${LARENOR_SOURCE_REVISION}", REVISION)
        expected = json.loads(encoded)
        resolved = json.loads(json.dumps(expected))
        project = "larenor-native-" + "f" * 32
        resolved["name"] = project
        resolved["services"]["larenor-core"]["build"]["context"] = str(ROOT)
        resolved["services"]["larenor-core"]["build"]["dockerfile"] = str(
            ROOT / "server/Dockerfile")
        for service in resolved["services"].values():
            service["command"] = None
            service["entrypoint"] = None
        target.validate_rendered_config(resolved, expected, project)
        drifts = []
        changed = json.loads(json.dumps(resolved))
        changed["services"]["larenor-seerr"]["user"] = "0:0"
        drifts.append(changed)
        changed = json.loads(json.dumps(resolved))
        changed["services"]["larenor-seerr"]["cap_add"] = ["SYS_ADMIN"]
        drifts.append(changed)
        changed = json.loads(json.dumps(resolved))
        changed["services"]["larenor-seerr"]["environment"]["API_TOKEN"] = "private"
        drifts.append(changed)
        changed = json.loads(json.dumps(resolved))
        changed["services"]["larenor-seerr"]["volumes"][0]["source"] = "/foreign"
        drifts.append(changed)
        changed = json.loads(json.dumps(resolved))
        changed["services"]["larenor-seerr"]["command"] = ["unsafe-override"]
        drifts.append(changed)
        for changed in drifts:
            with self.subTest(changed=changed["services"]["larenor-seerr"]):
                with self.assertRaisesRegex(target.ManagedStackCIError,
                                            "unified_manifest_invalid"):
                    target.validate_rendered_config(changed, expected, project)
        with tempfile.TemporaryDirectory() as temporary:
            driver = target.DockerDriver(
                REVISION, "linux/amd64", Path(temporary) / "ownership.json",
                operation_id="f" * 32,
            )
            with patch.object(driver, "_compose", side_effect=[
                    (0, b""), (0, json.dumps(drifts[0]).encode("utf-8"))]):
                with self.assertRaisesRegex(target.ManagedStackCIError,
                                            "unified_manifest_invalid"):
                    driver.config(target.COMPOSE, REVISION)

    def test_native_driver_pulls_services_sequentially_and_reports_exact_stage(self):
        manifest = target.expected_manifest(REVISION)
        with tempfile.TemporaryDirectory() as temporary:
            driver = target.DockerDriver(
                REVISION, "linux/amd64", Path(temporary) / "ownership.json",
                operation_id="f" * 32,
            )
            compose_calls = []

            def compose(*arguments, **kwargs):
                compose_calls.append((arguments, kwargs))
                return 0, b""

            def command(arguments, **_kwargs):
                image = arguments[-1]
                return 0, json.dumps([{
                    "RepoDigests": [image], "Os": "linux", "Architecture": "amd64",
                }]).encode("utf-8")

            with patch.object(driver, "_compose", side_effect=compose), patch.object(
                    target, "_command", side_effect=command):
                receipts = driver.pull(manifest)
            self.assertEqual(
                [call[0] for call in compose_calls],
                [("pull", "--quiet", target.SERVICE_NAMES[item])
                 for item in COMPONENTS]
                + [("build", "--pull", "larenor-core")],
            )
            self.assertEqual(len(receipts), len(COMPONENTS))

            for method, code in (
                (lambda: driver.create(manifest), "unified_create_runtime_failed"),
                (lambda: driver.start(manifest), "unified_start_runtime_failed"),
                (lambda: driver.restart(manifest), "unified_restart_runtime_failed"),
            ):
                with self.subTest(code=code), patch.object(
                        driver, "_compose",
                        side_effect=target.ManagedStackCIError("unified_native_runtime_failed")):
                    with self.assertRaisesRegex(target.ManagedStackCIError, code):
                        method()

    def test_rendered_network_aliases_are_explicit_and_exact(self):
        revision = REVISION
        expected = target.SourceConfig().config(target.COMPOSE, revision)
        rendered = json.loads(json.dumps(expected))
        rendered["name"] = "larenor-native-" + "f" * 32
        rendered["services"]["larenor-core"]["build"]["context"] = str(target.REPOSITORY)
        rendered["services"]["larenor-core"]["build"]["dockerfile"] = str(
            target.REPOSITORY / "server/Dockerfile"
        )
        target.validate_rendered_config(rendered, expected, rendered["name"])
        rendered["services"]["larenor-jellyfin"]["networks"]["control"][
            "aliases"
        ] = ["foreign-jellyfin"]
        with self.assertRaisesRegex(target.ManagedStackCIError,
                                    "unified_manifest_invalid"):
            target.validate_rendered_config(rendered, expected, rendered["name"])
        rendered = json.loads(json.dumps(expected))
        rendered["name"] = "larenor-native-" + "f" * 32
        rendered["services"]["larenor-core"]["build"]["context"] = str(
            target.REPOSITORY)
        rendered["services"]["larenor-core"]["build"]["dockerfile"] = str(
            target.REPOSITORY / "server/Dockerfile")
        rendered["services"]["larenor-core"]["dns"] = ["8.8.8.8"]
        with self.assertRaisesRegex(target.ManagedStackCIError,
                                    "unified_manifest_invalid"):
            target.validate_rendered_config(rendered, expected, rendered["name"])

    def test_core_starts_and_restarts_after_every_packaged_peer(self):
        with tempfile.TemporaryDirectory() as temporary:
            driver = target.DockerDriver(
                REVISION, "linux/amd64", Path(temporary) / "ownership.json",
                operation_id="f" * 32,
            )
            with patch.object(driver, "_compose", return_value=(0, b"")) as compose:
                driver.start({})
            self.assertEqual(compose.call_args_list, [
                call("up", "--detach", "--no-build", "--no-recreate",
                     *target.SERVICE_NAMES.values(), timeout=180),
                call("up", "--detach", "--no-build", "--no-recreate",
                     target.package.CORE_NAME, timeout=180),
            ])

            with patch.object(driver, "_compose", return_value=(0, b"")) as compose:
                driver.restart({})
            self.assertEqual(compose.call_args_list, [
                call("restart", "--timeout", "30", *target.SERVICE_NAMES.values(),
                     timeout=240),
                call("restart", "--timeout", "30", target.package.CORE_NAME,
                     timeout=240),
            ])

    def test_core_runtime_wait_is_bounded_and_dns_failure_is_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            driver = target.DockerDriver(
                REVISION, "linux/amd64", Path(temporary) / "ownership.json",
                operation_id="f" * 32,
            )
            starting = json.dumps({
                "Running": True, "Health": {"Status": "starting"},
            }).encode("utf-8")
            healthy = json.dumps({
                "Running": True, "Health": {"Status": "healthy"},
            }).encode("utf-8")
            with patch.object(target, "_command", side_effect=[
                    (0, starting), (0, healthy)]), patch.object(
                    target.time, "monotonic", side_effect=[0, 0, 1]), patch.object(
                    target.time, "sleep") as sleep:
                driver._await_core_runtime(timeout=5, interval=1)
            sleep.assert_called_once_with(1)

            stopped = json.dumps({
                "Running": False, "Health": {"Status": "unhealthy"},
            }).encode("utf-8")
            with patch.object(target, "_command", return_value=(0, stopped)):
                with self.assertRaisesRegex(target.ManagedStackCIError,
                                            "unified_core_runtime_unready"):
                    driver._await_core_runtime()

            # Embedded resolver config, self alias, then peer alias. The peer
            # may appear one bounded poll later during container startup.
            with patch.object(target, "_command", side_effect=[
                    (0, b""), (0, b""), (1, b""), (0, b"")]), patch.object(
                    target.time, "monotonic", side_effect=[0, 0, 0, 0, 1]), patch.object(
                    target.time, "sleep") as sleep:
                driver._verify_dns("jellyfin", timeout=5, interval=1)
            sleep.assert_called_once_with(1)

            for responses, code in (
                ([(1, b"")], "unified_dns_resolver_unavailable"),
                ([(0, b""), (1, b"")], "unified_dns_core_alias_failed"),
                ([(0, b""), (0, b""), (1, b"")], "unified_dns_peer_alias_failed"),
            ):
                monotonic = {
                    "unified_dns_resolver_unavailable": [],
                    "unified_dns_core_alias_failed": [0, 0, 1],
                    "unified_dns_peer_alias_failed": [0, 0, 0, 0, 1],
                }[code]
                with self.subTest(code=code), patch.object(
                        target, "_command", side_effect=responses), patch.object(
                        target.time, "monotonic", side_effect=monotonic), patch.object(
                        target.time, "sleep"):
                    with self.assertRaisesRegex(target.ManagedStackCIError, code):
                        driver._verify_dns("jellyfin", timeout=1, interval=1)

    def test_cleanup_removes_only_the_exact_receipt_owned_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "owned-root"
            receipt = Path(temporary) / "ownership.json"
            operation_id = "d" * 32
            receipt.write_text(json.dumps({
                "schemaVersion": 1, "operationId": operation_id,
                "sourceCommit": REVISION, "root": str(root),
                "projectName": "larenor-native-" + operation_id,
            }))
            root.mkdir()
            (root / target.MARKER).write_text(operation_id + "\n")
            (root / "data").mkdir()
            with patch.object(target, "ROOT", root), patch.object(
                    target, "_command", return_value=(0, b"")) as command:
                target.cleanup_owned(receipt, REVISION)
            self.assertFalse(root.exists())
            self.assertEqual(command.call_count, 1)
            arguments = command.call_args.args[0]
            self.assertEqual(arguments[arguments.index("--project-name") + 1],
                             "larenor-native-" + operation_id)
            with patch.object(target, "ROOT", root), patch.object(
                    target, "_command", return_value=(0, b"")) as command:
                target.cleanup_owned(receipt, REVISION)
            command.assert_not_called()

            root.mkdir()
            (root / target.MARKER).write_text("e" * 32 + "\n")
            with patch.object(target, "ROOT", root), patch.object(
                    target, "_command", return_value=(0, b"")) as command:
                with self.assertRaisesRegex(target.ManagedStackCIError,
                                            "unified_cleanup_not_owned"):
                    target.cleanup_owned(receipt, REVISION)
            self.assertTrue(root.exists())
            command.assert_not_called()

    def test_receipt_verifier_rejects_private_extra_or_optimistic_readiness(self):
        value = target.run_native(REVISION, "linux/amd64", FakeDriver())
        for changed in (
            value | {"privateToken": "never"},
            value | {"serviceState": "verified"},
            value | {"cleanupState": "planned"},
            value | {"acceptanceSourceHashes": {}},
        ):
            with self.assertRaises(target.ManagedStackCIError):
                target.validate_receipt(changed, REVISION, "linux/amd64")
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "receipt.json"
            path.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaisesRegex(target.ManagedStackCIError,
                                        "unified_characterization_evidence_invalid"):
                target.verify(path, REVISION, "linux/amd64")


if __name__ == "__main__":
    unittest.main()
