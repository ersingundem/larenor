"""Keep S09.1 native capture acceptance narrow and two-architecture."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/component-capture-native.yml"


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


if __name__ == "__main__":
    unittest.main()
