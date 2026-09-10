import importlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'tool'
sys.path.insert(0, str(TOOL))
check_commit_progress = importlib.import_module('check_commit_progress')


class CheckCommitProgressTest(unittest.TestCase):
    def test_parses_exact_progress_and_rejects_forged_values(self):
        parsed = check_commit_progress.parse_message(
            'feat: example\n\n'
            'Larenor-Queue-Progress: 14/125 (11.2%)\n'
            'Larenor-Feature-Progress: 3/63 (4.8%)\n')
        self.assertEqual(parsed.queue, (14, 125))
        self.assertEqual(parsed.feature, (3, 63))

        invalid = (
            'Larenor-Queue-Progress: 14/125 (99.9%)\n'
            'Larenor-Feature-Progress: 3/63 (4.8%)\n')
        with self.assertRaisesRegex(
                check_commit_progress.ProgressCheckError,
                '^invalid_progress_percentage$'):
            check_commit_progress.parse_message(invalid)

    def test_requires_each_trailer_exactly_once(self):
        valid = (
            'Larenor-Queue-Progress: 14/125 (11.2%)\n'
            'Larenor-Feature-Progress: 0/63 (0.0%)\n')
        for message in ('subject', valid + valid,
                        valid.replace('Larenor-Feature-', 'Larenor-X-')):
            with self.subTest(message=message):
                with self.assertRaises(check_commit_progress.ProgressCheckError):
                    check_commit_progress.parse_message(message)

    def test_sequence_is_monotonic_and_head_matches_queue(self):
        history = [
            check_commit_progress.ProgressValues((14, 125), (0, 63)),
            check_commit_progress.ProgressValues((15, 125), (1, 63)),
        ]
        check_commit_progress.validate_sequence(
            history, expected=history[-1])

        with self.assertRaisesRegex(
                check_commit_progress.ProgressCheckError,
                '^progress_regressed$'):
            check_commit_progress.validate_sequence(
                list(reversed(history)), expected=history[0])
        with self.assertRaisesRegex(
                check_commit_progress.ProgressCheckError,
                '^head_progress_mismatch$'):
            check_commit_progress.validate_sequence(
                history, expected=history[0])

    def test_checks_only_first_parent_pr_commits(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self._git(repo, 'init', '-q')
            self._git(repo, 'config', 'user.name', 'Larenor Test')
            self._git(repo, 'config', 'user.email', 'test@larenor.invalid')
            base = self._commit(repo, 'base', 'base')
            self._git(repo, 'checkout', '-q', '-b', 'feature')
            self._commit(repo, 'feature', 'parallel commit without trailers')
            self._git(repo, 'checkout', '-q', '-')
            self._commit(repo, 'main', self._message('integration one', 14, 125, 0, 63))
            self._git(repo, 'merge', '--no-ff', '-q', 'feature', '-m',
                      self._message('merge feature', 14, 125, 0, 63))
            head = self._git(repo, 'rev-parse', 'HEAD').strip()

            values = check_commit_progress.read_first_parent_progress(
                repo, base, head)
            self.assertEqual(len(values), 2)
            self.assertEqual(values[-1].queue, (14, 125))

    @staticmethod
    def _message(subject, queue_done, queue_total, feature_done, feature_total):
        return (
            f'{subject}\n\n'
            f'Larenor-Queue-Progress: {queue_done}/{queue_total} '
            f'({queue_done * 100 / queue_total:.1f}%)\n'
            f'Larenor-Feature-Progress: {feature_done}/{feature_total} '
            f'({feature_done * 100 / feature_total:.1f}%)')

    @staticmethod
    def _git(repo, *args):
        return subprocess.run(
            ['git', *args], cwd=repo, check=True, text=True,
            capture_output=True).stdout

    def _commit(self, repo, name, message):
        (repo / name).write_text(name)
        self._git(repo, 'add', name)
        self._git(repo, 'commit', '-q', '--cleanup=verbatim', '-m', message)
        return self._git(repo, 'rev-parse', 'HEAD').strip()


if __name__ == '__main__':
    unittest.main()
