"""Security policy for the separate managed-container native workflow."""

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class JellyfinManagedWorkflowPolicyTest(unittest.TestCase):
    def workflow(self):
        path = ROOT / '.github/workflows/jellyfin-managed-characterization.yml'
        self.assertTrue(path.is_file(), 'managed characterization workflow absent')
        return json.loads(path.read_text())

    def test_only_manual_native_two_architecture_execution(self):
        value = self.workflow()
        self.assertEqual(value['on'], {'workflow_dispatch': {}})
        job = value['jobs']['characterize']
        self.assertEqual(job['strategy']['matrix']['include'], [
            {'runner': 'ubuntu-24.04', 'platform': 'linux/amd64'},
            {'runner': 'ubuntu-24.04-arm', 'platform': 'linux/arm64'},
        ])
        self.assertIs(job['strategy']['fail-fast'], False)
        self.assertEqual(job['timeout-minutes'], 25)

    def test_actions_permissions_and_source_checkout_are_closed(self):
        value = self.workflow()
        self.assertEqual(value['permissions'], {'contents': 'read'})
        self.assertIs(value['concurrency']['cancel-in-progress'], True)
        text = json.dumps(value)
        self.assertNotIn('secrets.', text)
        self.assertNotIn('continue-on-error', text)
        for step in value['jobs']['characterize']['steps']:
            if 'uses' not in step:
                continue
            self.assertRegex(step['uses'], r'^actions/[a-z-]+@[0-9a-f]{40}$')
            if step['uses'].startswith('actions/checkout@'):
                self.assertEqual(step['with']['ref'], '${{ github.sha }}')
                self.assertIs(step['with']['persist-credentials'], False)

    def test_root_launcher_is_environment_closed_and_has_no_socket_input(self):
        steps = self.workflow()['jobs']['characterize']['steps']
        native = next(step for step in steps if step.get('id') == 'native')
        script = native['run']
        self.assertIn('sudo --non-interactive env -i', script)
        self.assertIn('-m tool.jellyfin_managed_ci --run-ephemeral-ci', script)
        self.assertNotRegex(script, r'\b(?:docker|dockerd|unshare)\s')
        self.assertNotIn('DOCKER_HOST', script)
        self.assertNotIn('HTTP_PROXY', script)
        self.assertNotIn('sudo -E', script)
        self.assertIn('GITHUB_WORKFLOW_SHA="$GITHUB_WORKFLOW_SHA"', script)

    def test_receipt_is_verified_before_exact_source_artifact(self):
        steps = self.workflow()['jobs']['characterize']['steps']
        verify = next(index for index, step in enumerate(steps)
                      if '--verify-receipt' in step.get('run', ''))
        upload = next(index for index, step in enumerate(steps)
                      if step.get('uses', '').startswith('actions/upload-artifact@'))
        self.assertLess(verify, upload)
        spec = steps[upload]['with']
        self.assertEqual(spec['if-no-files-found'], 'error')
        self.assertEqual(spec['path'], '${{ runner.temp }}/jellyfin-managed-receipt.json')
        self.assertIn('${{ github.sha }}', spec['name'])
        self.assertIn('${{ runner.arch }}', spec['name'])

    def test_manual_guard_requires_main_exact_workflow_source(self):
        script = self.workflow()['jobs']['characterize']['steps'][0]['run']
        self.assertIn('refs/heads/main', script)
        self.assertIn('$GITHUB_WORKFLOW_SHA" = "$GITHUB_SHA', script)
        self.assertIn('ersingundem/larenor', script)
        self.assertIn('github-hosted', script)

    def test_toolchain_is_pinned_without_emulation(self):
        text = json.dumps(self.workflow())
        self.assertIn('uv==0.12.10', text)
        self.assertIn('uv sync --locked --python 3.12.14', text)
        self.assertNotIn('setup-qemu', text)
        self.assertNotIn('setup-buildx', text)


if __name__ == '__main__':
    unittest.main()
