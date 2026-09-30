"""Real offline pip/venv regression for installed console-script path stability.

The wheels are tiny path fixtures, not production providers or feature evidence.
No root changes, service starts, network or household I/O are performed.
"""
import importlib.util
from pathlib import Path
import subprocess
import re
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    'release_path_install', ROOT / 'deploy/larenor-server/host_workers/install.py')
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


def wheel(directory, name, commands):
    path = directory / (name + '-1.0-py3-none-any.whl')
    info = name + '-1.0.dist-info/'
    files = {
        name + '.py': 'def main():\n    print("release-path-fixture")\n',
        info + 'METADATA': 'Metadata-Version: 2.1\nName: ' + name + '\nVersion: 1.0\n',
        info + 'WHEEL': 'Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n',
        info + 'entry_points.txt': '[console_scripts]\n' + ''.join(
            command + ' = ' + name + ':main\n' for command in commands),
    }
    files[info + 'RECORD'] = ''.join(item + ',,\n' for item in files) + info + 'RECORD,,\n'
    with zipfile.ZipFile(path, 'w') as archive:
        for filename, body in files.items(): archive.writestr(filename, body)
    return path


class HostWorkerReleasePathsTest(unittest.TestCase):
    def test_actual_offline_entrypoints_survive_activation_but_reject_relocation(self):
        with tempfile.TemporaryDirectory(prefix='larenor-release-path-') as directory:
            root = Path(directory)
            # Follow the package's public entrypoint inventory so independent
            # provider additions do not turn this path regression into a stub
            # test of one specific worker implementation.
            section = (ROOT / 'server/pyproject.toml').read_text().partition('[project.scripts]\n')[2].partition('\n[')[0]
            commands = re.findall(r'^([A-Za-z0-9_-]+) = "', section, re.MULTILINE)
            self.assertIn('larenor-ai-worker', commands)
            server = wheel(root, 'fixture_server', commands)
            unmanic = wheel(root, 'fixture_unmanic', ('unmanic',))
            release = root / 'releases' / ('a' * 40)
            release.mkdir(parents=True)
            package._install_environments(release, {'server': (server,), 'unmanic': (unmanic,)}, Path(sys.executable))
            current = root / 'current'
            current.symlink_to(release, target_is_directory=True)
            actual = subprocess.run([str(current / 'server/bin/larenor-ai-worker'), '--help'],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(actual.stdout.strip(), 'release-path-fixture')
            # Reproduce the old algorithm: moving an installed venv breaks its
            # script interpreter path even though its executable file exists.
            moved = root / 'releases' / ('b' * 40)
            release.rename(moved)
            with self.assertRaisesRegex(package.HostWorkerPackageError, 'release_invalid'):
                package._validate_entrypoints(moved)


if __name__ == '__main__': unittest.main()
