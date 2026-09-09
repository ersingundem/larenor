"""Standard-library workflow policy regression, collected by Security CI."""
import json
from pathlib import Path
import re
import os
import subprocess
import sys
import tempfile
import signal
import time
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

    def test_native_host_requires_supported_systemd_and_unified_cgroup(self):
        steps = self.workflow()['jobs']['characterize']['steps']
        step = next(s for s in steps if s.get('name') == 'Require owned cgroup runtime')
        script = step['run']
        self.assertIn('/usr/bin/systemd-run --version', script)
        self.assertIn('-ge 254', script)
        self.assertIn('cgroup2fs', script)
        self.assertIn('/sys/fs/cgroup/cgroup.controllers', script)
        self.assertLess(steps.index(step), next(i for i,s in enumerate(steps) if s.get('id') == 'native'))


    def test_actual_root_shell_drops_secrets_and_preserves_failure_status(self):
        step = next(s for s in self.workflow()['jobs']['characterize']['steps'] if s.get('id') == 'native')
        for exit_code in (0, 19):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fake_bin = root/'bin'
                fake_bin.mkdir()
                sudo = fake_bin/'sudo'
                sudo.write_text('#!'+sys.executable+'\nimport os,sys\nassert sys.argv[1]=="--non-interactive"\nos.execv("/usr/bin/env",sys.argv[2:])\n')
                sudo.chmod(0o700)
                venv = root/'venv with spaces'
                (venv/'bin').mkdir(parents=True)
                python = venv/'bin/python'
                python.write_text('#!'+sys.executable+'\nimport json,os,sys\nprint(json.dumps({"env":dict(os.environ),"args":sys.argv[1:]}))\nsys.exit('+str(exit_code)+')\n')
                python.chmod(0o700)
                values = {'PATH':str(fake_bin)+':/usr/bin:/bin', 'RUNNER_TEMP':str(root),
                    'GITHUB_WORKSPACE':str(root/'workspace with spaces'),'UV_PROJECT_ENVIRONMENT':str(venv),
                    'CI':'true','GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted',
                    'RUNNER_ARCH':'X64','GITHUB_SHA':'a'*40,'GITHUB_WORKFLOW_SHA':'a'*40,
                    'GITHUB_EVENT_NAME':'workflow_dispatch','GITHUB_REF':'refs/heads/main',
                    'GITHUB_REPOSITORY':'ersingundem/larenor','EXPECTED_PLATFORM':'linux/amd64',
                    'GITHUB_TOKEN':'synthetic-private','DOCKER_HOST':'unix:///synthetic-foreign.sock',
                    'HTTP_PROXY':'http://synthetic-private','HOME':'/synthetic-home'}
                completed = subprocess.run(['/bin/bash','-e','-c',step['run']], env=values,
                    capture_output=True, timeout=5)
                self.assertEqual(completed.returncode, exit_code, completed.stderr)
                captured = json.loads((root/'jellyfin-storage-receipt.json').read_text())
                actual = captured['env']
                expected_keys = {'PATH','PYTHONPATH','CI','GITHUB_ACTIONS','RUNNER_ENVIRONMENT',
                    'RUNNER_ARCH','GITHUB_SHA','GITHUB_WORKFLOW_SHA','GITHUB_EVENT_NAME','GITHUB_REF',
                    'GITHUB_REPOSITORY','EXPECTED_PLATFORM'}
                runtime_locale = {'LC_CTYPE', '__CF_USER_TEXT_ENCODING'} if sys.platform == 'darwin' else {'LC_CTYPE'}
                self.assertEqual(set(actual)-runtime_locale, expected_keys)
                self.assertNotIn('synthetic-private', json.dumps(actual))
                self.assertEqual(actual['PYTHONPATH'], values['GITHUB_WORKSPACE']+'/server:'+values['GITHUB_WORKSPACE'])
                self.assertEqual(captured['args'], ['-B','-m','tool.jellyfin_storage_ci','--run-ephemeral-ci'])

    def test_actual_manual_preflight_rejects_foreign_or_automatic_dispatch(self):
        script = self.workflow()['jobs']['characterize']['steps'][0]['run']
        valid = {'PATH':'/usr/bin:/bin','GITHUB_EVENT_NAME':'workflow_dispatch',
            'GITHUB_REF':'refs/heads/main','GITHUB_REPOSITORY':'ersingundem/larenor',
            'GITHUB_SHA':'a'*40,'GITHUB_WORKFLOW_SHA':'a'*40,'RUNNER_ENVIRONMENT':'github-hosted'}
        self.assertEqual(subprocess.run(['/bin/bash','-e','-c',script],env=valid,timeout=5).returncode, 0)
        for key in valid.keys()-{'PATH'}:
            with self.subTest(key=key):
                completed = subprocess.run(['/bin/bash','-e','-c',script],env=valid|{key:'wrong'},timeout=5)
                self.assertNotEqual(completed.returncode, 0)


    def test_actual_shell_entry_delivers_cancel_to_launcher(self):
        script = next(s['run'] for s in self.workflow()['jobs']['characterize']['steps'] if s.get('id') == 'native')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'bin').mkdir()
            sudo = root/'bin/sudo'
            sudo.write_text('#!'+sys.executable+'\nimport os,sys\nos.execv("/usr/bin/env",sys.argv[2:])\n')
            sudo.chmod(0o700)
            (root/'venv/bin').mkdir(parents=True)
            ready, closed = root/'ready', root/'closed'
            python = root/'venv/bin/python'
            python.write_text('#!'+sys.executable+'\nimport signal,time,sys\nfrom pathlib import Path\n'
                +'def cancel(*args):\n    Path('+repr(str(closed))+').write_text("cancelled")\n    sys.exit(19)\n'
                +'signal.signal(signal.SIGTERM,cancel)\nPath('+repr(str(ready))+').write_text("ready")\ntime.sleep(30)\n')
            python.chmod(0o700)
            env = {'PATH':str(root/'bin')+':/usr/bin:/bin','RUNNER_TEMP':str(root),
                'GITHUB_WORKSPACE':str(root),'UV_PROJECT_ENVIRONMENT':str(root/'venv'),
                'CI':'true','GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted',
                'RUNNER_ARCH':'X64','GITHUB_SHA':'a'*40,'GITHUB_WORKFLOW_SHA':'a'*40,
                'GITHUB_EVENT_NAME':'workflow_dispatch','GITHUB_REF':'refs/heads/main',
                'GITHUB_REPOSITORY':'ersingundem/larenor','EXPECTED_PLATFORM':'linux/amd64'}
            child = subprocess.Popen(['/bin/bash','-e','-c',script],env=env,start_new_session=True,
                stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                deadline=time.monotonic()+5
                while not ready.exists() and time.monotonic()<deadline and child.poll() is None:
                    time.sleep(.01)
                self.assertTrue(ready.exists())
                child.send_signal(signal.SIGTERM)
                child.wait(timeout=5)
                self.assertTrue(closed.exists(), 'step shell swallowed launcher cleanup signal')
                self.assertEqual(child.returncode, 19)
            finally:
                try: os.killpg(child.pid,signal.SIGKILL)
                except ProcessLookupError: pass
                child.communicate(timeout=5)


if __name__ == '__main__':
    unittest.main()
