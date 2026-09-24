"""Keep S09.1 native capture acceptance narrow and two-architecture."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/component-capture-native.yml"
NATIVE_TEST = ROOT / "server/tests/test_core_backup_linux_cow_capture_native.py"


class ComponentCaptureNativeWorkflowTest(unittest.TestCase):
    def test_exact_native_matrix_and_fixture_are_required(self):
        value = WORKFLOW.read_text()
        self.assertEqual(value.count("platform: linux/amd64"), 1)
        self.assertEqual(value.count("platform: linux/arm64"), 1)
        self.assertIn('"btrfs-progs=6.6.3-1.1build2"', value)
        self.assertIn("mkfs.btrfs --force", value)
        self.assertIn("/var/lib/larenor-component-capture-", value)
        self.assertIn("test_core_backup_linux_cow_capture_native.py", value)
        self.assertIn("component_linux_capture_preflight.py", value)
        self.assertIn("test_core_backup_linux_capture_preflight.py", value)
        self.assertIn("--check-platform", value)

    def test_workflow_scope_excludes_restore_domains(self):
        value = WORKFLOW.read_text()
        paths = value.split("  workflow_dispatch:", 1)[0]
        self.assertNotIn("restore", paths.lower())
        self.assertNotIn("client", paths.lower())
        self.assertNotIn("android", paths.lower())

    def test_native_restart_uses_installed_production_composition(self):
        value = NATIVE_TEST.read_text()
        self.assertIn("larenor-component-backup-worker", value)
        self.assertIn('"--check-config"', value)
        self.assertIn("ManagedWorkerJournal", value)
        self.assertIn("VolumeCreateJournal", value)
        self.assertIn("assert not journal.exists()", value)

    def test_both_architectures_own_generation_and_drift_acceptance(self):
        workflow = WORKFLOW.read_text()
        scope = workflow.split("  workflow_dispatch:", 1)[0]
        for path in (
            "component_snapshot_provider.py",
            "component_worker.py",
            "component_worker_server.py",
            "core_backups/service.py",
        ):
            self.assertIn(path, scope)
        for test in (
            "test_core_backup_components.py",
            "test_core_backup_component_isolated_capture.py",
            "test_core_backup_component_worker_server.py",
        ):
            self.assertIn(test, workflow)
        native = NATIVE_TEST.read_text()
        self.assertIn("capture_generation", native)
        self.assertIn("publication interrupted after complete generation", native)


if __name__ == "__main__":
    unittest.main()
