import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/github-storage-retention.yml'


class GitHubStorageWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.workflow = json.loads(WORKFLOW.read_text())
        self.job = self.workflow['jobs']['cleanup']

    def test_daily_and_manual_triggers_are_bounded_to_the_upstream_repo(self):
        self.assertEqual(self.workflow['on']['schedule'], [{'cron': '15 0 * * *'}])
        self.assertEqual(self.workflow['on']['workflow_dispatch'], {})
        self.assertEqual(self.job['if'], "github.repository == 'ersingundem/larenor'")
        self.assertEqual(self.job['timeout-minutes'], 10)
        self.assertEqual(self.workflow['concurrency']['group'],
                         'github-storage-retention')
        self.assertTrue(self.workflow['concurrency']['cancel-in-progress'])

    def test_token_can_only_read_contents_and_manage_actions_artifacts(self):
        self.assertEqual(self.workflow['permissions'], {'contents': 'read'})
        self.assertEqual(self.job['permissions'], {
            'actions': 'write',
            'contents': 'read',
        })
        checkout = self.job['steps'][0]
        self.assertRegex(checkout['uses'], r'^actions/checkout@[0-9a-f]{40}$')
        self.assertFalse(checkout['with']['persist-credentials'])

    def test_policy_tests_run_before_one_no_retry_apply(self):
        steps = self.job['steps']
        test_index = next(i for i, step in enumerate(steps)
                          if 'github_storage_cleanup_test.py' in step.get('run', ''))
        apply_steps = [
            (i, step) for i, step in enumerate(steps)
            if 'github_storage_cleanup.py --apply' in step.get('run', '')]
        self.assertEqual(len(apply_steps), 1)
        apply_index, apply = apply_steps[0]
        self.assertLess(test_index, apply_index)
        self.assertEqual(
            apply['run'],
            'python3 tool/github_storage_cleanup.py --apply --max-deletions 5')
        self.assertEqual(apply['env'], {'GH_TOKEN': '${{ github.token }}'})
        rendered = WORKFLOW.read_text()
        self.assertNotIn('packages: write', rendered)
        self.assertNotIn('delete-package-versions', rendered)
        self.assertNotIn('continue-on-error', rendered)


if __name__ == '__main__':
    unittest.main()
