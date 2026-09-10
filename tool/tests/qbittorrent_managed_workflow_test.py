"""Security policy for native managed qBittorrent acceptance."""

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class QbittorrentManagedWorkflowPolicyTest(unittest.TestCase):
    def workflow(self):
        path = ROOT / '.github/workflows/qbittorrent-managed-characterization.yml'
        self.assertTrue(path.is_file())
        return json.loads(path.read_text())

    def test_two_real_architectures_and_closed_event_scope(self):
        value = self.workflow()
        self.assertEqual(value['on'], {
            'workflow_dispatch': {}, 'pull_request': {'branches': ['main']}})
        job = value['jobs']['qbittorrent-characterize']
        self.assertEqual(job['strategy']['matrix']['include'], [
            {'runner': 'ubuntu-24.04', 'platform': 'linux/amd64'},
            {'runner': 'ubuntu-24.04-arm', 'platform': 'linux/arm64'},
        ])
        self.assertIs(job['strategy']['fail-fast'], False)
        self.assertEqual(job['timeout-minutes'], 25)

    def test_pinned_actions_minimal_permissions_and_no_secrets(self):
        value = self.workflow()
        self.assertEqual(value['permissions'], {'contents': 'read'})
        text = json.dumps(value)
        self.assertNotIn('secrets.', text)
        self.assertNotIn('continue-on-error', text)
        for step in value['jobs']['qbittorrent-characterize']['steps']:
            if 'uses' in step:
                self.assertRegex(step['uses'], r'^actions/[a-z-]+@[0-9a-f]{40}$')
                if step['uses'].startswith('actions/checkout@'):
                    self.assertEqual(step['with']['ref'], '${{ github.sha }}')
                    self.assertIs(step['with']['persist-credentials'], False)

    def test_event_guard_requires_exact_reviewed_source(self):
        script = self.workflow()['jobs']['qbittorrent-characterize']['steps'][0]['run']
        for required in (
            'workflow_dispatch)', 'pull_request)', 'refs/heads/main',
            'refs/pull/*/merge', '$GITHUB_BASE_REF" = main',
            '$PR_HEAD_REPOSITORY" = "$GITHUB_REPOSITORY',
            '$GITHUB_WORKFLOW_SHA" = "$GITHUB_SHA',
            'ersingundem/larenor', 'github-hosted',
        ):
            self.assertIn(required, script)

    def test_root_launcher_has_no_socket_or_ambient_network_configuration(self):
        steps = self.workflow()['jobs']['qbittorrent-characterize']['steps']
        script = next(step for step in steps if step.get('id') == 'native')['run']
        self.assertIn('sudo --non-interactive env -i', script)
        self.assertIn('-m tool.qbittorrent_managed_ci --run-ephemeral-ci', script)
        self.assertNotRegex(script, r'\b(?:docker|dockerd|unshare)\s')
        for forbidden in ('DOCKER_HOST', 'HTTP_PROXY', 'HTTPS_PROXY', 'sudo -E'):
            self.assertNotIn(forbidden, script)

    def test_receipt_is_verified_before_exact_source_artifact(self):
        steps = self.workflow()['jobs']['qbittorrent-characterize']['steps']
        verify = next(i for i, step in enumerate(steps)
                      if '--verify-receipt' in step.get('run', ''))
        upload = next(i for i, step in enumerate(steps)
                      if step.get('uses', '').startswith('actions/upload-artifact@'))
        self.assertLess(verify, upload)
        spec = steps[upload]['with']
        self.assertEqual(spec['if-no-files-found'], 'error')
        self.assertIn('${{ github.sha }}', spec['name'])
        self.assertIn('${{ runner.arch }}', spec['name'])

    def test_pinned_native_toolchain_has_no_emulation(self):
        text = json.dumps(self.workflow())
        self.assertIn('uv==0.12.10', text)
        self.assertIn('uv sync --locked --python 3.12.14', text)
        self.assertNotIn('setup-qemu', text)
        self.assertNotIn('setup-buildx', text)


if __name__ == '__main__':
    unittest.main()
