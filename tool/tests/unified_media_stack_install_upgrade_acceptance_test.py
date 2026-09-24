"""S09.3 RED contract for native clean-install and exact upgrade evidence."""

import copy
import hashlib
import json
import unittest

from tool import unified_media_stack_managed_ci as target
from tool.tests.unified_media_stack_managed_ci_test import FakeDriver


BASE_REVISION = "9" * 40
CURRENT_REVISION = "a" * 40
PLATFORMS = ("linux/amd64", "linux/arm64")


def _digest(value):
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("ascii")
    return hashlib.sha256(raw).hexdigest()


class PowerLoss(BaseException):
    pass


class DurableUpgradeState:
    def __init__(self):
        self.effect_revision = None
        self.stored = None
        self.persisted = []
        self.journal = None
        self.apply_counts = {"install": 0, "upgrade": 0}


class UpgradeDriver(FakeDriver):
    """Synthetic effect seam; it never touches Docker or a device filesystem."""

    def __init__(
        self,
        *,
        state=None,
        interrupt_at=None,
        tamper_read=None,
        private_drift=None,
    ):
        super().__init__()
        self.state = state or DurableUpgradeState()
        self.interrupt_at = interrupt_at
        self.tamper_read = tamper_read
        self.private_drift = private_drift
        self.reads = 0
        self.private_reads = 0
        self.selected_platform = "linux/amd64"
        self.base_source_hashes = {
            key: "9" * 64 for key in target.acceptance_source_hashes()
        }
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
        value = {
            "schemaVersion": 1,
            "state": "installed",
            "installationId": "1" * 32,
            "sourceRevision": revision,
            "platform": self.selected_platform,
        }
        value["receiptDigest"] = _digest(value)
        return value

    def materialize_base(self, revision):
        self._call("materialize_base:" + revision)
        if revision != BASE_REVISION:
            raise RuntimeError("foreign base source")
        return {
            "sourceRevision": revision,
            "acceptanceSourceHashes": copy.deepcopy(self.base_source_hashes),
        }

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
        self.state.journal = {"operation": "install", "targetRevision": revision}
        if self.interrupt_at == "install_before":
            raise RuntimeError("interrupted")
        self.state.effect_revision = revision
        if self.interrupt_at == "install_power_loss":
            raise PowerLoss()
        if self.interrupt_at == "install_after":
            raise RuntimeError("interrupted")
        return self._receipt(revision)

    def apply_upgrade(self, revision):
        self._call("apply_upgrade:" + revision)
        self.state.apply_counts["upgrade"] += 1
        self.state.journal = {"operation": "upgrade", "targetRevision": revision}
        if self.interrupt_at == "upgrade_before":
            raise RuntimeError("interrupted")
        self.state.effect_revision = revision
        if self.interrupt_at == "upgrade_power_loss":
            raise PowerLoss()
        if self.interrupt_at == "upgrade_after":
            raise RuntimeError("interrupted")
        return self._receipt(revision)

    def reconcile_upgrade(self, revision, operation):
        self._call("reconcile:" + operation + ":" + revision)
        if (self.state.journal == {
                "operation": operation, "targetRevision": revision}
                and self.state.effect_revision == revision):
            return self._receipt(revision)
        return copy.deepcopy(self.state.stored)

    def persist_installation_receipt(self, receipt):
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
        if self.private_drift == "digest" and self.private_reads > 1:
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
                positions = [driver.calls.index(item) for item in ordered]
                self.assertEqual(positions, sorted(positions))
                self.assertEqual(driver.reads, 2)
                self.assertEqual(
                    [item["sourceRevision"] for item in driver.state.persisted],
                    [BASE_REVISION, CURRENT_REVISION],
                )
                self.assertEqual(
                    [item["phase"] for item in result["installationPhases"]],
                    ["clean-install", "upgrade", "restart"],
                )
                self.assertTrue(all(set(item) == {
                    "phase", "sourceRevision", "receiptDigest"
                } for item in result["installationPhases"]))
                self.assertEqual(
                    [item["sourceRevision"] for item in result["installationPhases"]],
                    [BASE_REVISION, CURRENT_REVISION, CURRENT_REVISION],
                )
                self.assertEqual(result["upgradeSourceCommit"], BASE_REVISION)
                self.assertEqual(result["reviewedHeadCommit"], CURRENT_REVISION)
                self.assertEqual(
                    result["upgradeSourceHashes"],
                    driver.base_source_hashes,
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

    def test_private_state_is_preserved_and_never_serialized(self):
        driver = UpgradeDriver()
        result = self.run_upgrade(driver)

        self.assertEqual(driver.private_reads, 3)
        expected = {
            (item["serviceId"], item["containerTarget"], item["digest"])
            for item in driver.private_receipts
        }
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

        for drift in ("digest", "missing"):
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
        self.assertEqual(state.journal, {
            "operation": "upgrade",
            "targetRevision": CURRENT_REVISION,
        })

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
