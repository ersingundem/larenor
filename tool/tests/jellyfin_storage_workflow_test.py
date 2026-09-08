"""Standard-library workflow policy regression, collected by Security CI."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class JellyfinWorkflowPolicyTest(unittest.TestCase):
    def workflow(self):
        path = ROOT/'.github/workflows/jellyfin-storage-characterization.yml'
        self.assertTrue(path.is_file(), 'manual characterization workflow absent')
        return json.loads(path.read_text())

    def test_only_explicit_manual_native_matrix(self):
        value = self.workflow()
        self.assertEqual(value['on'], {'workflow_dispatch':{}})
        job = value['jobs']['characterize']
        self.assertNotIn('if', job, 'unsupported dispatch must fail, not skip green')
        self.assertEqual(job['strategy']['matrix']['include'], [
            {'runner':'ubuntu-24.04','platform':'linux/amd64'},
            {'runner':'ubuntu-24.04-arm','platform':'linux/arm64'}])
        self.assertIs(job['strategy']['fail-fast'], False)
        self.assertEqual(job['timeout-minutes'], 25)

    def test_actions_and_repo_access_are_closed(self):
        value = self.workflow()
        self.assertEqual(value['permissions'], {'contents':'read'})
        self.assertIs(value['concurrency']['cancel-in-progress'], True)
        text = json.dumps(value)
        self.assertNotIn('secrets.', text)
        self.assertNotIn('continue-on-error', text)
        for step in value['jobs']['characterize']['steps']:
            if 'uses' in step:
                self.assertRegex(step['uses'], r'^actions/[a-z-]+@[0-9a-f]{40}$')
                if step['uses'].startswith('actions/checkout@'):
                    self.assertIs(step['with']['persist-credentials'], False)
                    self.assertEqual(step['with']['ref'], '${{ github.sha }}')

    def test_root_launcher_has_no_ambient_environment_or_direct_docker(self):
        value = self.workflow()
        step = next(s for s in value['jobs']['characterize']['steps'] if s.get('id') == 'native')
        script = step['run']
        self.assertIn('sudo --non-interactive env -i', script)
        self.assertIn('-m tool.jellyfin_storage_ci --run-ephemeral-ci', script)
        self.assertNotRegex(script, r'\b(?:docker|dockerd|unshare)\s')
        self.assertNotIn('sudo -E', script)
        self.assertNotIn('DOCKER_HOST', script)
        self.assertNotIn('HTTP_PROXY', script)
        self.assertIn('GITHUB_WORKFLOW_SHA="$GITHUB_WORKFLOW_SHA"', script)

    def test_receipt_is_verified_before_required_exact_source_artifact(self):
        value = self.workflow()
        steps = value['jobs']['characterize']['steps']
        verify = next(i for i,s in enumerate(steps) if '--verify-receipt' in s.get('run',''))
        upload = next(i for i,s in enumerate(steps) if s.get('uses','').startswith('actions/upload-artifact@'))
        self.assertLess(verify, upload)
        spec = steps[upload]['with']
        self.assertEqual(spec['if-no-files-found'], 'error')
        self.assertEqual(spec['path'], '${{ runner.temp }}/jellyfin-storage-receipt.json')
        self.assertIn('${{ github.sha }}', spec['name'])
        self.assertIn('${{ runner.arch }}', spec['name'])
        self.assertNotIn('if', steps[upload])

    def test_dependency_versions_are_locked_and_full_core_not_repeated(self):
        text = json.dumps(self.workflow())
        self.assertIn('uv==0.12.10', text)
        self.assertIn('uv sync --locked --python 3.12.14', text)
        self.assertNotIn('pytest tests ', text)
        self.assertNotIn('setup-qemu', text)
        self.assertNotIn('setup-buildx', text)


if __name__ == '__main__':
    unittest.main()
