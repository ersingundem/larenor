from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_security_policy import check_repository, validate_backup, validate_workflow

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "android/app/src/main"


class SecurityPolicyTest(unittest.TestCase):
    def setUp(self):
        self.manifest = (RES / "AndroidManifest.xml").read_text()
        self.legacy = (RES / "res/xml/backup_rules.xml").read_text()
        self.rules = (RES / "res/xml/data_extraction_rules.xml").read_text()

    def test_repository_meets_policy(self):
        self.assertEqual(check_repository(ROOT), [])

    def test_cloud_disabled_alone_does_not_protect_device_transfer(self):
        import xml.etree.ElementTree as ET
        root = ET.fromstring(self.rules)
        root.remove(root.find("device-transfer"))
        errors = validate_backup(self.manifest, self.legacy, ET.tostring(root))
        self.assertTrue(any("device-transfer" in error for error in errors))

    def test_narrow_key_exclusion_cannot_replace_whole_preference_exclusion(self):
        rules = self.rules.replace('domain="sharedpref" path="."',
                                   'domain="sharedpref" path="one_key.xml"')
        self.assertTrue(validate_backup(self.manifest, self.legacy, rules))

    def test_legacy_backup_opt_in_is_rejected(self):
        manifest = self.manifest.replace('android:allowBackup="false"',
                                         'android:allowBackup="true"')
        self.assertTrue(validate_backup(manifest, self.legacy, self.rules))

    def test_mutable_action_tag_is_rejected(self):
        workflow = (ROOT / ".github/workflows/analyze-test.yml").read_text()
        import re
        workflow = re.sub(r"actions/checkout@[a-f0-9]{40}", "actions/checkout@v4", workflow)
        self.assertTrue(any("SHA" in error for error in validate_workflow(workflow)))

    def test_privileged_pr_trigger_is_rejected(self):
        workflow = (ROOT / ".github/workflows/analyze-test.yml").read_text()
        self.assertTrue(validate_workflow(workflow.replace("pull_request:", "pull_request_target:")))


if __name__ == "__main__":
    unittest.main()
