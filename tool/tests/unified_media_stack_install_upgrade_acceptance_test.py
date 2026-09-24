"""S09.3 RED contract for native clean-install and exact upgrade evidence."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

from tool import unified_media_stack_managed_ci as target
from tool.tests.unified_media_stack_managed_ci_test import FakeDriver


ROOT = Path(__file__).resolve().parents[2]
BASE_REVISION = "2f43b6cd606dab17640bb6f0a832b353b62c2313"
CURRENT_REVISION = "aecb951418f2d22d11fc6ee24ed706f6ee83645f"
PLATFORMS = ("linux/amd64", "linux/arm64")
DEPLOYMENT_SPEC = importlib.util.spec_from_file_location(
    "s093_deployment_bundle",
    ROOT / "deploy/larenor-server/deployment_bundle.py",
)
deployment = importlib.util.module_from_spec(DEPLOYMENT_SPEC)
DEPLOYMENT_SPEC.loader.exec_module(deployment)
PLANNER = deployment.DeploymentBundlePlanner(
    compose_path=ROOT / "deploy/larenor-server/unified.compose.yaml",
    catalog_path=ROOT / "server/larenor_server/plugins/packagedcatalog.json",
    env_example_path=ROOT / "deploy/larenor-server/.env.example",
)
SETTINGS = {
    "LARENOR_DATA_ROOT": "/var/lib/larenor-server",
    "LARENOR_TIMEZONE": "Europe/Istanbul",
    "LARENOR_LOCALE": "tr_TR.UTF-8",
    "LARENOR_CORE_PORT": "18098",
}


def _digest(value):
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("ascii")
    return hashlib.sha256(raw).hexdigest()


def _git_output(*arguments):
    return subprocess.check_output(
        ["git", *arguments], cwd=ROOT, stderr=subprocess.DEVNULL
    )


def _source_materialization(revision):
    return {
        "sourceRevision": revision,
        "treeObject": _git_output("rev-parse", revision + "^{tree}")
        .decode("ascii")
        .strip(),
        "sourceHashes": {
            path: hashlib.sha256(
                _git_output("show", revision + ":" + path)
            ).hexdigest()
            for path in target.SOURCE_FILES
        },
    }


class PowerLoss(BaseException):
    pass


class DurableUpgradeState:
    def __init__(self):
        self.effect = None
        self.stored = None
        self.persisted = []
        self.journal = None
        self.apply_counts = {"install": 0, "upgrade": 0}
        self.runtime_receipts = []
        self.root_identity = "root-" + "7" * 59


class UpgradeDriver(FakeDriver):
    """Synthetic effect seam; it never touches Docker or a device filesystem."""

    def __init__(
        self,
        *,
        state=None,
        interrupt_at=None,
        tamper_read=None,
        private_drift=None,
        journal_drift=None,
        root_identity=None,
        runtime_drift=None,
    ):
        super().__init__()
        self.state = state or DurableUpgradeState()
        self.interrupt_at = interrupt_at
        self.tamper_read = tamper_read
        self.private_drift = private_drift
        self.journal_drift = journal_drift
        self.runtime_drift = runtime_drift
        if root_identity is not None:
            self.state.root_identity = root_identity
        self.reads = 0
        self.private_reads = 0
        self.selected_platform = "linux/amd64"
        self.base_materialization = _source_materialization(BASE_REVISION)
        manifest = target.expected_manifest(CURRENT_REVISION)
        self.private_receipts = [
            {
                "serviceId": component["serviceId"],
                "containerTarget": mount["target"],
                "digest": hashlib.sha256(
                    (component["serviceId"] + ":" + mount["target"]).encode("ascii")
                ).hexdigest(),
            }
            for component in manifest["components"]
            for mount in component["mounts"]
            if mount["readOnly"] is False
        ]

    def _receipt(self, revision):
        bundle = PLANNER.plan(revision, SETTINGS)
        return PLANNER.installed_state_receipt(
            bundle,
            installation_id="1" * 32,
            architecture=self.selected_platform.split("/", 1)[1],
        )

    def _runtime_receipt(self, revision):
        manifest = target.expected_manifest(revision)
        return {
            "schemaVersion": 1,
            "sourceRevision": revision,
            "manifestDigest": manifest["manifestDigest"],
            "services": [
                {
                    "serviceId": component["serviceId"],
                    "image": component["image"],
                    "containerIdentityDigest": hashlib.sha256(
                        (revision + ":" + component["serviceId"]).encode("ascii")
                    ).hexdigest(),
                    "state": "running",
                }
                for component in manifest["components"]
            ],
        }

    def _effect(self, revision):
        value = {
            "installationReceipt": self._receipt(revision),
            "runtimeReceipt": self._runtime_receipt(revision),
        }
        if revision == CURRENT_REVISION and self.runtime_drift == "image":
            value["runtimeReceipt"]["services"][0]["image"] = "foreign/image:latest"
        elif revision == CURRENT_REVISION and self.runtime_drift == "container":
            value["runtimeReceipt"]["services"][0]["containerIdentityDigest"] = (
                "f" * 64
            )
        return value

    def materialize_base(self, revision):
        self._call("materialize_base:" + revision)
        if revision != BASE_REVISION:
            raise RuntimeError("foreign base source")
        return copy.deepcopy(self.base_materialization)

    def deployment_preflight(self, revision, operation):
        self._call("preflight:" + operation + ":" + revision)
        installed_revision = (
            self.state.stored["sourceRevision"]
            if isinstance(self.state.stored, dict)
            else None
        )
        return {
            "schemaVersion": 1,
            "operation": operation,
            "ready": (
                installed_revision is None
                if operation == "install"
                else installed_revision == BASE_REVISION
            ),
            "installedRevision": installed_revision,
            "targetRevision": revision,
        }

    def apply_install(self, revision):
        self._call("apply_install:" + revision)
        self.state.apply_counts["install"] += 1
        self.state.journal = self._journal("install", revision)
        if self.interrupt_at == "install_before":
            raise RuntimeError("interrupted")
        self.state.effect = self._effect(revision)
        self.state.runtime_receipts.append(
            copy.deepcopy(self.state.effect["runtimeReceipt"])
        )
        if self.interrupt_at == "install_power_loss":
            raise PowerLoss()
        if self.interrupt_at == "install_after":
            raise RuntimeError("interrupted")
        return copy.deepcopy(self.state.effect)

    def apply_upgrade(self, revision):
        self._call("apply_upgrade:" + revision)
        self.state.apply_counts["upgrade"] += 1
        self.state.journal = self._journal("upgrade", revision)
        if self.interrupt_at == "upgrade_before":
            raise RuntimeError("interrupted")
        self.state.effect = self._effect(revision)
        self.state.runtime_receipts.append(
            copy.deepcopy(self.state.effect["runtimeReceipt"])
        )
        if self.interrupt_at == "upgrade_power_loss":
            raise PowerLoss()
        if self.interrupt_at == "upgrade_after":
            raise RuntimeError("interrupted")
        return copy.deepcopy(self.state.effect)

    def _journal(self, operation, revision):
        return {
            "schemaVersion": 1,
            "operation": operation,
            "upgradeSourceCommit": BASE_REVISION,
            "targetRevision": revision,
            "rootIdentity": self.state.root_identity,
        }

    def reconcile_upgrade(self, revision, operation):
        self._call("reconcile:" + operation + ":" + revision)
        journal = copy.deepcopy(self.state.journal)
        if self.journal_drift == "bool_schema":
            journal["schemaVersion"] = True
        elif self.journal_drift == "foreign_target":
            journal["targetRevision"] = "f" * 40
        elif self.journal_drift == "foreign_root":
            journal["rootIdentity"] = "root-" + "8" * 59
        if (
            journal == self._journal(operation, revision)
            and isinstance(self.state.effect, dict)
            and self.state.effect["installationReceipt"]["sourceRevision"] == revision
        ):
            return copy.deepcopy(self.state.effect)
        return None

    def persist_installation_receipt(self, receipt):
        if set(receipt) == {"installationReceipt", "runtimeReceipt"}:
            receipt = receipt["installationReceipt"]
        self._call("persist:" + receipt["sourceRevision"])
        self.state.stored = copy.deepcopy(receipt)
        self.state.persisted.append(copy.deepcopy(receipt))
        self.state.journal = None

    def installation_receipt(self):
        self._call("installation_receipt")
        self.reads += 1
        value = copy.deepcopy(self.state.stored)
        if self.tamper_read == "foreign" and self.reads == 1:
            value["installationId"] = "2" * 32
            value["receiptDigest"] = _digest({
                key: item for key, item in value.items() if key != "receiptDigest"
            })
        elif self.tamper_read == "stale" and self.reads == 2:
            value = copy.deepcopy(self.state.persisted[0])
        elif self.tamper_read == "bool_schema" and self.reads == 1:
            value["schemaVersion"] = True
        return value

    def private_state(self):
        self._call("private_state")
        self.private_reads += 1
        value = copy.deepcopy(self.private_receipts)
        if self.private_drift == "omit_always":
            value.pop()
        elif self.private_drift == "digest" and self.private_reads > 1:
            value[0]["digest"] = "8" * 64
        elif self.private_drift == "missing" and self.private_reads > 1:
            value.pop()
        return value


class UnifiedMediaStackInstallUpgradeAcceptanceTest(unittest.TestCase):
    def run_upgrade(self, driver, platform="linux/amd64"):
        driver.selected_platform = platform
        return target.run_native(
            CURRENT_REVISION,
            platform,
            driver,
            base_commit=BASE_REVISION,
        )

    def test_prior_exact_receipt_is_reread_before_current_upgrade(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                driver = UpgradeDriver()
                result = self.run_upgrade(driver, platform)

                ordered = [
                    "materialize_base:" + BASE_REVISION,
                    "preflight:install:" + BASE_REVISION,
                    "apply_install:" + BASE_REVISION,
                    "persist:" + BASE_REVISION,
                    "installation_receipt",
                    "private_state",
                    "preflight:upgrade:" + CURRENT_REVISION,
                    "apply_upgrade:" + CURRENT_REVISION,
                    "persist:" + CURRENT_REVISION,
                    "installation_receipt",
                    "private_state",
                ]
                cursor = -1
                for expected_call in ordered:
                    cursor = driver.calls.index(expected_call, cursor + 1)
                self.assertEqual(driver.reads, 2)
                self.assertEqual(
                    [item["sourceRevision"] for item in driver.state.persisted],
                    [BASE_REVISION, CURRENT_REVISION],
                )
                expected_receipt_keys = {
                    "schemaVersion",
                    "state",
                    "installationId",
                    "sourceRevision",
                    "releaseVersion",
                    "manifestDigest",
                    "bundleDigest",
                    "architecture",
                    "dataRoot",
                    "entrypoint",
                    "settingsSchemaDigest",
                    "receiptDigest",
                }
                self.assertTrue(
                    all(
                        set(receipt) == expected_receipt_keys
                        for receipt in driver.state.persisted
                    )
                )
                self.assertTrue(
                    all(
                        receipt["architecture"] == platform.split("/", 1)[1]
                        for receipt in driver.state.persisted
                    )
                )
                self.assertEqual(
                    [item["sourceRevision"] for item in driver.state.runtime_receipts],
                    [BASE_REVISION, CURRENT_REVISION],
                )
                for revision, runtime in zip(
                    (BASE_REVISION, CURRENT_REVISION),
                    driver.state.runtime_receipts,
                    strict=True,
                ):
                    expected_manifest = target.expected_manifest(revision)
                    expected_images = {
                        item["serviceId"]: item["image"]
                        for item in expected_manifest["components"]
                    }
                    self.assertEqual(runtime["sourceRevision"], revision)
                    self.assertEqual(
                        runtime["manifestDigest"],
                        expected_manifest["manifestDigest"],
                    )
                    self.assertEqual(
                        {
                            item["serviceId"]: item["image"]
                            for item in runtime["services"]
                        },
                        expected_images,
                    )
                self.assertEqual(
                    [item["phase"] for item in result["installationPhases"]],
                    ["clean-install", "upgrade", "restart"],
                )
                self.assertTrue(all(set(item) == {
                    "phase", "sourceRevision", "installationReceiptDigest",
                    "runtimeReceiptDigest",
                } for item in result["installationPhases"]))
                self.assertEqual(
                    [item["sourceRevision"] for item in result["installationPhases"]],
                    [BASE_REVISION, CURRENT_REVISION, CURRENT_REVISION],
                )
                self.assertNotEqual(
                    result["installationPhases"][0]["installationReceiptDigest"],
                    result["installationPhases"][1]["installationReceiptDigest"],
                )
                self.assertNotEqual(
                    result["installationPhases"][0]["runtimeReceiptDigest"],
                    result["installationPhases"][1]["runtimeReceiptDigest"],
                )
                self.assertEqual(result["upgradeSourceCommit"], BASE_REVISION)
                self.assertEqual(result["reviewedHeadCommit"], CURRENT_REVISION)
                self.assertEqual(
                    result["upgradeSourceHashes"],
                    driver.base_materialization["sourceHashes"],
                )
                self.assertEqual(
                    result["upgradeSourceTree"],
                    driver.base_materialization["treeObject"],
                )
                self.assertEqual(
                    result["reviewedHeadTree"],
                    _source_materialization(CURRENT_REVISION)["treeObject"],
                )
                self.assertEqual(
                    set(result["upgradeSourceHashes"]),
                    set(result["acceptanceSourceHashes"]),
                )
                self.assertNotEqual(
                    result["upgradeSourceHashes"],
                    result["acceptanceSourceHashes"],
                )
                target.validate_receipt(result, CURRENT_REVISION, platform)
                for field in ("upgradeSourceCommit", "reviewedHeadCommit"):
                    changed = copy.deepcopy(result)
                    changed[field] = "f" * 40
                    with self.assertRaisesRegex(
                        target.ManagedStackCIError,
                        "unified_characterization_evidence_invalid",
                    ):
                        target.validate_receipt(changed, CURRENT_REVISION, platform)

    def test_install_and_upgrade_require_exact_running_service_receipts(self):
        for drift in ("image", "container"):
            with self.subTest(drift=drift), self.assertRaisesRegex(
                target.ManagedStackCIError,
                "unified_(?:container_receipt|upgrade_reconcile)_invalid",
            ):
                self.run_upgrade(UpgradeDriver(runtime_drift=drift))

    def test_private_state_is_preserved_and_never_serialized(self):
        driver = UpgradeDriver()
        result = self.run_upgrade(driver)

        self.assertEqual(driver.private_reads, 3)
        expected = {
            (item["serviceId"], item["containerTarget"], item["digest"])
            for item in driver.private_receipts
        }
        manifest = target.expected_manifest(CURRENT_REVISION)
        expected_mounts = {
            (component["serviceId"], mount["target"])
            for component in manifest["components"]
            for mount in component["mounts"]
            if mount["readOnly"] is False
        }
        self.assertEqual(
            {(service, target_path) for service, target_path, _ in expected},
            expected_mounts,
        )
        proofs = result["privateStateProofs"]
        self.assertEqual(
            {
                (item["serviceId"], item["containerTarget"], item["digest"])
                for item in proofs
            },
            expected,
        )
        self.assertTrue(all(item["preserved"] is True for item in proofs))
        self.assertTrue(all(set(item) == {
            "serviceId", "containerTarget", "digest", "preserved"
        } for item in proofs))
        encoded = json.dumps(result, sort_keys=True).lower()
        self.assertNotIn("/var/lib", encoded)
        self.assertNotRegex(encoded, r"token|password|credential|authorization")

        for drift in ("digest", "missing", "omit_always"):
            with self.subTest(drift=drift), self.assertRaisesRegex(
                target.ManagedStackCIError,
                "unified_private_state_changed",
            ):
                self.run_upgrade(UpgradeDriver(private_drift=drift))

    def test_foreign_stale_and_non_integer_receipts_fail_closed(self):
        for tamper in ("foreign", "stale", "bool_schema"):
            with self.subTest(tamper=tamper):
                driver = UpgradeDriver(tamper_read=tamper)
                with self.assertRaisesRegex(
                    target.ManagedStackCIError,
                    "unified_installation_receipt_invalid",
                ):
                    self.run_upgrade(driver)
                self.assertEqual(driver.calls[-1], "cleanup")

    def test_interrupted_pre_effect_apply_fails_without_replay(self):
        for phase in ("install_before", "upgrade_before"):
            with self.subTest(phase=phase):
                driver = UpgradeDriver(interrupt_at=phase)
                with self.assertRaisesRegex(
                    target.ManagedStackCIError,
                    "unified_(?:install|upgrade)_reconcile_failed",
                ):
                    self.run_upgrade(driver)
                effect = "apply_" + phase.removesuffix("_before")
                self.assertEqual(
                    len([item for item in driver.calls if item.startswith(effect)]),
                    1,
                )
                self.assertIn("reconcile:" + phase.removesuffix("_before"), " ".join(
                    driver.calls,
                ))
                self.assertEqual(driver.calls[-1], "cleanup")

    def test_interrupted_post_effect_apply_reconciles_without_replay(self):
        for phase in ("install_after", "upgrade_after"):
            with self.subTest(phase=phase):
                driver = UpgradeDriver(interrupt_at=phase)
                result = self.run_upgrade(driver)
                operation = phase.removesuffix("_after")
                effect = "apply_" + operation
                self.assertEqual(
                    len([item for item in driver.calls if item.startswith(effect)]),
                    1,
                )
                self.assertIn(
                    "reconcile:" + operation + ":",
                    " ".join(driver.calls),
                )
                self.assertEqual(result["sourceCommit"], CURRENT_REVISION)

    def test_power_loss_restarts_from_durable_journal_without_replaying_effect(self):
        state = DurableUpgradeState()
        crashed = UpgradeDriver(state=state, interrupt_at="upgrade_power_loss")
        with self.assertRaises(PowerLoss):
            self.run_upgrade(crashed)
        self.assertEqual(state.apply_counts, {"install": 1, "upgrade": 1})
        self.assertEqual(state.stored["sourceRevision"], BASE_REVISION)
        self.assertEqual(
            state.journal,
            crashed._journal("upgrade", CURRENT_REVISION),
        )

        restarted = UpgradeDriver(state=state)
        result = self.run_upgrade(restarted)

        self.assertEqual(state.apply_counts, {"install": 1, "upgrade": 1})
        self.assertEqual(state.stored["sourceRevision"], CURRENT_REVISION)
        self.assertIsNone(state.journal)
        self.assertIn(
            "reconcile:upgrade:" + CURRENT_REVISION,
            restarted.calls,
        )
        self.assertEqual(result["reviewedHeadCommit"], CURRENT_REVISION)
        self.assertEqual(
            [item["sourceRevision"] for item in result["installationPhases"]],
            [BASE_REVISION, CURRENT_REVISION, CURRENT_REVISION],
        )
        self.assertNotEqual(
            result["installationPhases"][0]["runtimeReceiptDigest"],
            result["installationPhases"][1]["runtimeReceiptDigest"],
        )
        self.assertEqual(
            result["installationPhases"][0]["installationReceiptDigest"],
            state.persisted[0]["receiptDigest"],
        )
        self.assertEqual(
            len(
                [
                    item
                    for item in crashed.calls + restarted.calls
                    if item.startswith("apply_upgrade:")
                ]
            ),
            1,
        )
        self.assertIsNone(state.journal)
        self.assertEqual(restarted.calls[-1], "cleanup")

    def test_malformed_foreign_or_root_drifted_journal_never_replays_effect(self):
        crashed_state = DurableUpgradeState()
        crashed = UpgradeDriver(
            state=crashed_state,
            interrupt_at="upgrade_power_loss",
        )
        with self.assertRaises(PowerLoss):
            self.run_upgrade(crashed)

        for drift in ("bool_schema", "foreign_target", "foreign_root"):
            with self.subTest(drift=drift):
                state = copy.deepcopy(crashed_state)
                before_journal = copy.deepcopy(state.journal)
                before_private = copy.deepcopy(crashed.private_receipts)
                restarted = UpgradeDriver(state=state, journal_drift=drift)
                restarted.private_receipts = before_private
                with self.assertRaisesRegex(
                    target.ManagedStackCIError,
                    "unified_upgrade_reconcile_failed",
                ):
                    self.run_upgrade(restarted)
                self.assertEqual(state.apply_counts, {"install": 1, "upgrade": 1})
                self.assertEqual(state.stored["sourceRevision"], BASE_REVISION)
                self.assertEqual(state.journal, before_journal)
                self.assertEqual(restarted.private_receipts, before_private)
                self.assertNotIn("cleanup", restarted.calls)

    def test_base_must_be_distinct_exact_lowercase_revision(self):
        for base in (
            CURRENT_REVISION,
            "A" * 40,
            "9" * 39,
            "../" + "9" * 40,
        ):
            with self.subTest(base=base):
                with self.assertRaisesRegex(
                    target.ManagedStackCIError,
                    "unified_launch_invalid",
                ):
                    target.run_native(
                        CURRENT_REVISION,
                        "linux/amd64",
                        UpgradeDriver(),
                        base_commit=base,
                    )


if __name__ == "__main__":
    unittest.main()
