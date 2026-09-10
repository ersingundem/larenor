import importlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'tool'
sys.path.insert(0, str(TOOL))
commit_with_progress = importlib.import_module('commit_with_progress')


class FakeQueue:
    def __init__(self, counts):
        self._counts = counts

    def counts(self):
        return dict(self._counts)


class CommitWithProgressTest(unittest.TestCase):
    def test_progress_uses_only_done_and_selected_feature_done_counts(self):
        progress = commit_with_progress.progress_for(FakeQueue({
            'done': 14,
            'total': 125,
            'featuresDone': 3,
            'featuresTotal': 63,
            'in_progress': 99,
            'awaiting_ci': 9,
        }))
        self.assertEqual(progress.queue_trailer, '14/125 (11.2%)')
        self.assertEqual(progress.feature_trailer, '3/63 (4.8%)')

    def test_message_keeps_paragraphs_and_appends_one_stable_trailer_block(self):
        progress = commit_with_progress.Progress(14, 125, 0, 63)
        message = commit_with_progress.message_with_progress(
            'feat: add view\n\nExplain $(touch NEVER) and `whoami`.\n', progress)
        self.assertEqual(message, (
            'feat: add view\n\nExplain $(touch NEVER) and `whoami`.\n\n'
            'Larenor-Queue-Progress: 14/125 (11.2%)\n'
            'Larenor-Feature-Progress: 0/63 (0.0%)\n'))

    def test_reserved_trailers_and_empty_messages_are_rejected(self):
        progress = commit_with_progress.Progress(1, 2, 0, 63)
        for message in ['', ' \n ', 'x\nLarenor-Queue-Progress: forged',
                        'Larenor-Feature-Progress: forged']:
            with self.subTest(message=message):
                with self.assertRaises(commit_with_progress.CommitProgressError):
                    commit_with_progress.message_with_progress(message, progress)

    def test_dry_run_prints_message_without_invoking_git(self):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(commit_with_progress.subprocess, 'run') as run:
            result = commit_with_progress.main(
                ['--dry-run', '--queue', str(ROOT / 'docs/execution-queue.json'),
                 '-m', 'docs: show progress'], stdout=out, stderr=err)
        self.assertEqual(result, 0, err.getvalue())
        run.assert_not_called()
        progress = commit_with_progress.progress_for(
            commit_with_progress.execution_queue.load_queue(
                ROOT / 'docs/execution-queue.json'))
        self.assertIn('Larenor-Queue-Progress: ' + progress.queue_trailer, out.getvalue())
        self.assertIn('Larenor-Feature-Progress: ' + progress.feature_trailer, out.getvalue())

    def test_real_git_commit_treats_shell_metacharacters_as_literal_text(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / 'repo'
            sentinel = Path(directory) / 'SHOULD_NOT_EXIST'
            repo.mkdir()
            subprocess.run(['git', 'init', '-q'], cwd=repo, check=True)
            subprocess.run(['git', 'config', 'user.name', 'Larenor Test'], cwd=repo, check=True)
            subprocess.run(['git', 'config', 'user.email', 'test@larenor.invalid'], cwd=repo, check=True)
            (repo / 'file.txt').write_text('staged\n')
            subprocess.run(['git', 'add', 'file.txt'], cwd=repo, check=True)
            malicious = 'test: literal $(touch %s); `whoami`\n\nsecond paragraph' % sentinel
            run = subprocess.run([
                sys.executable, str(ROOT / 'tool/commit_with_progress.py'),
                '--queue', str(ROOT / 'docs/execution-queue.json'), '-m', malicious,
            ], cwd=repo, text=True, capture_output=True, check=False)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertFalse(sentinel.exists())
            committed = subprocess.run(
                ['git', 'log', '-1', '--format=%B'], cwd=repo,
                text=True, capture_output=True, check=True).stdout
            self.assertIn('$(touch %s)' % sentinel, committed)
            self.assertIn('`whoami`', committed)
            self.assertEqual(committed.count('Larenor-Queue-Progress:'), 1)
            self.assertEqual(committed.count('Larenor-Feature-Progress:'), 1)

    def test_invalid_queue_fails_before_git_and_does_not_echo_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            queue = Path(directory) / 'queue.json'
            queue.write_text('{"secret":"DO_NOT_ECHO"}')
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(commit_with_progress.subprocess, 'run') as run:
                result = commit_with_progress.main(
                    ['--queue', str(queue), '-m', 'test: no commit'],
                    stdout=out, stderr=err)
            self.assertEqual(result, 2)
            run.assert_not_called()
            self.assertEqual(out.getvalue(), '')
            self.assertNotIn('DO_NOT_ECHO', err.getvalue())


if __name__ == '__main__':
    unittest.main()
