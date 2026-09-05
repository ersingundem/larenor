from pathlib import Path
import json
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_security_policy import check_repository, validate_backup, validate_workflow, validate_signed_android_workflow

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
        self.assertTrue(validate_workflow(workflow.replace("workflow_call:", "pull_request_target:")))

    def json_workflow(self):
        return {
            "on": {"push": None},
            "permissions": {"contents": "read"},
            "concurrency": {"group": "fixture", "cancel-in-progress": True},
            "jobs": {"check": {"steps": [{"uses": "actions/checkout@" + "a" * 40}]}},
        }

    def test_json_workflow_applies_same_policies(self):
        self.assertEqual(validate_workflow(json.dumps(self.json_workflow())), [])

    def test_json_unpinned_action_and_reusable_workflow_are_rejected(self):
        for job in ({"steps": [{"uses": "actions/checkout@v4"}]},
                    {"uses": "owner/repo/.github/workflows/test.yml@main"}):
            with self.subTest(job=job):
                workflow = self.json_workflow()
                workflow["jobs"]["check"] = job
                self.assertTrue(any("SHA" in error for error in validate_workflow(json.dumps(workflow))))

    def test_json_privileged_trigger_forms_are_rejected(self):
        for triggers in ("pull_request_target", ["pull_request_target"], {"pull_request_target": {}}):
            with self.subTest(triggers=triggers):
                workflow = self.json_workflow()
                workflow["on"] = triggers
                self.assertTrue(validate_workflow(json.dumps(workflow)))

    def test_json_broad_permissions_at_either_scope_are_rejected(self):
        for scope in ("workflow", "job"):
            with self.subTest(scope=scope):
                workflow = self.json_workflow()
                target = workflow if scope == "workflow" else workflow["jobs"]["check"]
                target["permissions"] = "write-all"
                self.assertTrue(validate_workflow(json.dumps(workflow)))

    def test_json_concurrency_requires_boolean_true(self):
        for value in (False, "true", 1, None):
            with self.subTest(value=value):
                workflow = self.json_workflow()
                workflow["concurrency"]["cancel-in-progress"] = value
                self.assertTrue(validate_workflow(json.dumps(workflow)))

    def test_json_invalid_or_duplicate_fields_are_rejected(self):
        for text in ('{"permissions":', '{"permissions":{},"permissions":{"contents":"read"}}'):
            with self.subTest(text=text):
                self.assertTrue(validate_workflow(text))

    def test_release_cannot_skip_a_test_gate(self):
        workflow = (ROOT / ".github/workflows/android-build.yml").read_text()
        for gate in ("build-debug-apk", "analyze-test", "end-to-end", "server-test"):
            with self.subTest(gate=gate):
                changed = workflow.replace(
                    "needs: [build-debug-apk, analyze-test, end-to-end, server-test]",
                    "needs: [" + ", ".join(v for v in (
                        "build-debug-apk", "analyze-test", "end-to-end", "server-test") if v != gate) + "]",
                )
                self.assertTrue(validate_signed_android_workflow(changed))

    def test_test_gate_cannot_use_another_revision_or_replacement_job(self):
        workflow = (ROOT / ".github/workflows/android-build.yml").read_text()
        for path in ("analyze-test.yml", "android-e2e.yml", "server-test.yml"):
            with self.subTest(path=path):
                changed = workflow.replace(f"./.github/workflows/{path}",
                                           f"./.github/workflows/unchecked-{path}")
                self.assertTrue(validate_signed_android_workflow(changed))

    def test_server_publication_requires_its_own_fresh_main_and_https_guards(self):
        workflow = (ROOT / ".github/workflows/android-build.yml").read_text()
        prefix, marker, publish = workflow.partition("      - name: Publish verified Client to the configured Larenor Server\n")
        for guard in ('if [ "$current_main" != "$GITHUB_SHA" ]',
                      "endpoint.scheme != 'https'", "unset GH_TOKEN",
                      "steps.signing.outputs.available == 'true'"):
            with self.subTest(guard=guard):
                changed = prefix + marker + publish.replace(guard, "removed_guard", 1)
                self.assertTrue(validate_signed_android_workflow(changed))

    def test_publisher_secret_cannot_be_reused_by_a_second_job(self):
        workflow = (ROOT / ".github/workflows/android-build.yml").read_text()
        workflow += "\n  untrusted:\n    env:\n      TOKEN: ${{ secrets.LARENOR_RELEASE_PUBLISH_TOKEN }}\n"
        self.assertTrue(validate_signed_android_workflow(workflow))


if __name__ == "__main__":
    unittest.main()
