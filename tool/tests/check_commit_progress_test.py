import importlib
import json
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
    def test_reopening_fixture_is_a_self_contained_accepted_history(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, queue, _ = self._queue_repository(Path(directory))
            model = check_commit_progress.execution_queue.load_queue(queue)

            for identifier in ('K07', 'K08'):
                node = model.nodes[identifier]
                self.assertEqual(node['status'], 'done')
                self.assertEqual(node['completionCommit'], 'a' * 40)
                self.assertEqual(
                    {proof['kind'] for proof in node['evidence']},
                    set(node['requiredEvidence']),
                )
                self.assertFalse(model.blockers(identifier, finishing=True))
            self.assertTrue(
                (repo / 'docs/testing/synthetic-accepted.md').is_file())

    def test_allows_exact_evidence_bound_reopening_from_the_base_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, queue, base = self._queue_repository(Path(directory))
            evidence = repo / 'docs/testing/reopened-ci.md'
            evidence.parent.mkdir(parents=True, exist_ok=True)
            evidence.write_text('Changed-source CI is required.\n')
            self._reopen(queue, ('K07', 'K08'),
                         reason='Regression evidence: docs/testing/reopened-ci.md')
            progress = check_commit_progress.expected_progress(queue)
            head = self._queue_commit(repo, 'truthful reopen', progress)

            status = check_commit_progress.main([
                '--base', base, '--head', head, '--repo', str(repo),
                '--queue', str(queue),
            ])

            self.assertEqual(status, 0)

    def test_rejects_a_forged_first_commit_progress_decrease_without_reopening(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, queue, base = self._queue_repository(Path(directory))
            original = check_commit_progress.expected_progress(queue)
            forged = check_commit_progress.ProgressValues(
                (original.queue[0] - 2, original.queue[1]),
                original.feature,
            )
            head = self._queue_commit(repo, 'forged regression', forged)

            status = check_commit_progress.main([
                '--base', base, '--head', head, '--repo', str(repo),
                '--queue', str(queue),
            ])

            self.assertEqual(status, 2)

    def test_rejects_reopening_without_new_named_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, queue, base = self._queue_repository(Path(directory))
            self._reopen(queue, ('K07', 'K08'), reason='A regression was found.')
            progress = check_commit_progress.expected_progress(queue)
            head = self._queue_commit(repo, 'unnamed regression', progress)

            status = check_commit_progress.main([
                '--base', base, '--head', head, '--repo', str(repo),
                '--queue', str(queue),
            ])

            self.assertEqual(status, 2)

    def test_rejects_directory_traversal_and_spoofed_ci_evidence_tokens(self):
        reasons = (
            'Regression evidence: docs/testing',
            'Regression evidence: docs/testing/../execution-queue.json',
            'Regression evidence: '
            'https://github.com/ersingundem/larenor/actions/runs/'
            '123456789012345678901suffix',
        )
        for reason in reasons:
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as directory:
                repo, queue, base = self._queue_repository(Path(directory))
                (repo / 'docs/testing').mkdir(parents=True, exist_ok=True)
                self._reopen(queue, ('K07', 'K08'), reason=reason)
                progress = check_commit_progress.expected_progress(queue)
                head = self._queue_commit(repo, 'invalid evidence token', progress)

                status = check_commit_progress.main([
                    '--base', base, '--head', head, '--repo', str(repo),
                    '--queue', str(queue),
                ])

                self.assertEqual(status, 2)

    def test_rejects_empty_and_symlink_named_evidence(self):
        for case in ('empty', 'symlink'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                repo, queue, base = self._queue_repository(Path(directory))
                evidence = repo / 'docs/testing/reopened-ci.md'
                evidence.parent.mkdir(parents=True, exist_ok=True)
                if case == 'empty':
                    evidence.write_bytes(b'')
                else:
                    target = repo / 'evidence-target'
                    target.write_text('Changed-source CI is required.\n')
                    evidence.symlink_to(Path('../..') / target.name)
                self._reopen(
                    queue, ('K07', 'K08'),
                    reason='Regression evidence: docs/testing/reopened-ci.md',
                )
                progress = check_commit_progress.expected_progress(queue)
                head = self._queue_commit(repo, case, progress)

                status = check_commit_progress.main([
                    '--base', base, '--head', head, '--repo', str(repo),
                    '--queue', str(queue),
                ])

                self.assertEqual(status, 2)

    def test_rejects_reopening_that_drops_historical_acceptance_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, queue, base = self._queue_repository(Path(directory))
            evidence = repo / 'docs/testing/reopened-ci.md'
            evidence.parent.mkdir(parents=True, exist_ok=True)
            evidence.write_text('Changed-source CI is required.\n')
            self._reopen(queue, ('K07', 'K08'),
                         reason='Regression evidence: docs/testing/reopened-ci.md')
            value = json.loads(queue.read_text())
            next(node for node in value['nodes'] if node['id'] == 'K07')['evidence'].pop()
            queue.write_text(json.dumps(value))
            progress = check_commit_progress.expected_progress(queue)
            head = self._queue_commit(repo, 'evidence deletion', progress)

            status = check_commit_progress.main([
                '--base', base, '--head', head, '--repo', str(repo),
                '--queue', str(queue),
            ])

            self.assertEqual(status, 2)

    def test_rejects_invalid_status_completion_and_deleted_nodes_during_reopening(self):
        cases = ('implemented', 'completion_retained', 'deleted')
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                repo, queue, base = self._queue_repository(Path(directory))
                evidence = repo / 'docs/testing/reopened-ci.md'
                evidence.parent.mkdir(parents=True, exist_ok=True)
                evidence.write_text('Changed-source CI is required.\n')
                self._reopen(queue, ('K07',),
                             reason='Regression evidence: docs/testing/reopened-ci.md')
                value = json.loads(queue.read_text())
                if case == 'implemented':
                    next(node for node in value['nodes']
                         if node['id'] == 'K07')['status'] = 'implemented'
                elif case == 'completion_retained':
                    next(node for node in value['nodes']
                         if node['id'] == 'K07')['completionCommit'] = 'a' * 40
                else:
                    value['nodes'] = [node for node in value['nodes']
                                      if node['id'] != 'K08']
                queue.write_text(json.dumps(value))
                try:
                    progress = check_commit_progress.expected_progress(queue)
                except check_commit_progress.execution_queue.QueueError:
                    # A deleted referenced node may fail even before the
                    # transition validator; either path is fail closed.
                    progress = check_commit_progress.ProgressValues((36, 126), (3, 63))
                head = self._queue_commit(repo, case, progress)

                status = check_commit_progress.main([
                    '--base', base, '--head', head, '--repo', str(repo),
                    '--queue', str(queue),
                ])

                self.assertEqual(status, 2)

    def test_selected_feature_reopening_exactly_accounts_for_both_counters(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, queue, base = self._queue_repository(Path(directory))
            evidence = repo / 'docs/testing/reopened-ci.md'
            evidence.parent.mkdir(parents=True, exist_ok=True)
            evidence.write_text('Changed-source CI is required.\n')
            self._reopen(queue, ('F06',),
                         reason='Regression evidence: docs/testing/reopened-ci.md',
                         status='reworking')
            progress = check_commit_progress.expected_progress(queue)
            head = self._queue_commit(repo, 'feature reopen', progress)

            status = check_commit_progress.main([
                '--base', base, '--head', head, '--repo', str(repo),
                '--queue', str(queue),
            ])

            self.assertEqual(status, 0)

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

    def test_parallel_histories_are_checked_by_parent_not_topological_order(self):
        values = check_commit_progress.ProgressValues
        entry = check_commit_progress.ProgressEntry
        history = [
            entry('left-start', values((14, 125), (0, 63))),
            entry('left-end', values((15, 125), (0, 63)), ('left-start',)),
            entry('right-start', values((14, 125), (0, 63))),
            entry('right-end', values((14, 125), (1, 63)), ('right-start',)),
            entry('merge', values((15, 125), (1, 63)),
                  ('left-end', 'right-end')),
        ]

        check_commit_progress.validate_graph(history, history[-1].values)

        regressed_merge = entry('merge', values((14, 125), (1, 63)),
                                ('left-end', 'right-end'))
        with self.assertRaisesRegex(
                check_commit_progress.ProgressCheckError,
                '^progress_regressed$'):
            check_commit_progress.validate_graph(
                [*history[:-1], regressed_merge], regressed_merge.values)

        with self.assertRaisesRegex(
                check_commit_progress.ProgressCheckError,
                '^head_progress_mismatch$'):
            check_commit_progress.validate_graph(
                history, history[0].values)

    def test_checks_every_commit_added_by_the_pr(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self._git(repo, 'init', '-q')
            self._git(repo, 'config', 'user.name', 'Larenor Test')
            self._git(repo, 'config', 'user.email', 'test@larenor.invalid')
            base = self._commit(repo, 'base', 'base')
            self._git(repo, 'checkout', '-q', '-b', 'feature')
            self._commit(repo, 'feature', self._message(
                'parallel commit', 14, 125, 0, 63))
            self._git(repo, 'checkout', '-q', '-')
            self._commit(repo, 'main', self._message('integration one', 14, 125, 0, 63))
            self._git(repo, 'merge', '--no-ff', '-q', 'feature', '-m',
                      self._message('merge feature', 14, 125, 0, 63))
            head = self._git(repo, 'rev-parse', 'HEAD').strip()

            values = check_commit_progress.read_progress(
                repo, base, head)
            self.assertEqual(len(values), 3)
            self.assertEqual(values[-1].queue, (14, 125))
            entries = check_commit_progress.read_progress_entries(
                repo, base, head)
            self.assertEqual(set(entries[-1].parents),
                             {entries[0].commit, entries[1].commit})
            check_commit_progress.validate_graph(entries, values[-1])

    def test_checks_pr_commits_when_the_base_branch_advances(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self._git(repo, 'init', '-q')
            self._git(repo, 'config', 'user.name', 'Larenor Test')
            self._git(repo, 'config', 'user.email', 'test@larenor.invalid')
            self._commit(repo, 'root', 'base')
            self._git(repo, 'checkout', '-q', '-b', 'feature')
            head = self._commit(repo, 'feature', self._message(
                'feature commit', 14, 125, 0, 63))
            self._git(repo, 'checkout', '-q', '-')
            base = self._commit(repo, 'main', self._message(
                'concurrent main commit', 14, 125, 0, 63))

            entries = check_commit_progress.read_progress_entries(
                repo, base, head)

            self.assertEqual([entry.commit for entry in entries], [head])

    def test_expected_progress_is_owned_by_the_pr_head_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self._git(repo, 'init', '-q')
            self._git(repo, 'config', 'user.name', 'Larenor Test')
            self._git(repo, 'config', 'user.email', 'test@larenor.invalid')
            queue = repo / 'docs/execution-queue.json'
            queue.parent.mkdir()
            queue.write_text(
                (ROOT / 'docs/execution-queue.json').read_text())
            original = check_commit_progress.expected_progress(queue)
            self._git(repo, 'add', 'docs/execution-queue.json')
            self._git(repo, 'commit', '-q', '-m', 'queue base')
            head = self._commit(repo, 'feature', self._message(
                'feature commit', *original.queue, *original.feature))
            queue.write_text('{}')

            expected = check_commit_progress.expected_progress_at(
                repo, head, queue)

            self.assertEqual(expected, original)

    def test_rejects_disconnected_histories(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self._git(repo, 'init', '-q')
            self._git(repo, 'config', 'user.name', 'Larenor Test')
            self._git(repo, 'config', 'user.email', 'test@larenor.invalid')
            base = self._commit(repo, 'base', 'base')
            self._git(repo, 'checkout', '-q', '--orphan', 'disconnected')
            head = self._commit(repo, 'head', self._message(
                'disconnected commit', 14, 125, 0, 63))

            with self.assertRaisesRegex(
                    check_commit_progress.ProgressCheckError,
                    '^invalid_commit_range$'):
                check_commit_progress.read_progress(repo, base, head)

    def test_reports_each_commit_progress_without_commit_message(self):
        entries = [
            check_commit_progress.ProgressEntry(
                '0123456789abcdef',
                check_commit_progress.ProgressValues((14, 125), (0, 63))),
            check_commit_progress.ProgressEntry(
                'fedcba9876543210',
                check_commit_progress.ProgressValues((15, 125), (1, 63))),
        ]

        report = check_commit_progress.format_report(entries)

        self.assertIn('| `0123456` | 14/125 (11.2%) | 0/63 (0.0%) |', report)
        self.assertIn('| `fedcba9` | 15/125 (12.0%) | 1/63 (1.6%) |', report)
        self.assertNotIn('private commit subject', report)

    def test_main_writes_the_same_commit_report_to_ci_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / 'repo'
            repo.mkdir()
            self._git(repo, 'init', '-q')
            self._git(repo, 'config', 'user.name', 'Larenor Test')
            self._git(repo, 'config', 'user.email', 'test@larenor.invalid')
            queue = Path(directory) / 'queue.json'
            queue.write_text((ROOT / 'docs/execution-queue.json').read_text())
            expected = check_commit_progress.expected_progress(queue)
            base = self._commit(repo, 'base', 'base')
            head = self._commit(
                repo, 'feature', self._message(
                    'private commit subject', *expected.queue,
                    *expected.feature))
            summary = Path(directory) / 'summary.md'

            status = check_commit_progress.main([
                '--base', base, '--head', head, '--repo', str(repo),
                '--queue', str(queue), '--summary', str(summary),
            ])

            self.assertEqual(status, 0)
            written = summary.read_text()
            self.assertIn(
                f'| `{head[:7]}` | '
                f'{expected.queue[0]}/{expected.queue[1]} '
                f'({expected.queue[0] * 100 / expected.queue[1]:.1f}%) | '
                f'{expected.feature[0]}/{expected.feature[1]} '
                f'({expected.feature[0] * 100 / expected.feature[1]:.1f}%) |',
                written)
            self.assertNotIn('private commit subject', written)

    @staticmethod
    def _message(subject, queue_done, queue_total, feature_done, feature_total):
        return (
            f'{subject}\n\n'
            f'Larenor-Queue-Progress: {queue_done}/{queue_total} '
            f'({queue_done * 100 / queue_total:.1f}%)\n'
            f'Larenor-Feature-Progress: {feature_done}/{feature_total} '
            f'({feature_done * 100 / feature_total:.1f}%)')

    def _queue_repository(self, directory):
        repo = directory / 'repo'
        repo.mkdir()
        self._git(repo, 'init', '-q')
        self._git(repo, 'config', 'user.name', 'Larenor Test')
        self._git(repo, 'config', 'user.email', 'test@larenor.invalid')
        queue = repo / 'docs/execution-queue.json'
        queue.parent.mkdir()
        queue.write_text(json.dumps(self._accepted_queue_fixture()))
        evidence = repo / 'docs/testing/synthetic-accepted.md'
        evidence.parent.mkdir(parents=True)
        evidence.write_text('Synthetic accepted history for validator tests.\n')
        self._git(repo, 'add', 'docs/execution-queue.json',
                  'docs/testing/synthetic-accepted.md')
        self._git(repo, 'commit', '-q', '-m', 'queue base')
        return repo, queue, self._git(repo, 'rev-parse', 'HEAD').strip()

    @staticmethod
    def _accepted_queue_fixture():
        value = json.loads((ROOT / 'docs/execution-queue.json').read_text())
        nodes = {node['id']: node for node in value['nodes']}
        children = {identifier: [] for identifier in nodes}
        for node in value['nodes']:
            if node['parent'] is not None:
                children[node['parent']].append(node['id'])
        accepted = set()

        def accept(identifier):
            node = nodes[identifier]
            if node['kind'] == 'group':
                for child in children[identifier]:
                    accept(child)
                return
            if identifier in accepted:
                return
            accepted.add(identifier)
            for dependency in node['dependsOn'] + node['finishDependsOn']:
                accept(dependency)

        for identifier in ('K07', 'K08', 'F06'):
            accept(identifier)
        for node in value['nodes']:
            if node['kind'] == 'checkpoint':
                accept(node['id'])

        completion = 'a' * 40
        for node in value['nodes']:
            if node['kind'] == 'group':
                continue
            is_accepted = node['id'] in accepted
            node['status'] = 'done' if is_accepted else 'pending'
            node['completionCommit'] = completion if is_accepted else None
            node['reason'] = None
            node['evidence'] = [
                {
                    'kind': kind,
                    'ref': (
                        'https://github.com/ersingundem/larenor/actions/runs/1'
                        if kind == 'ci'
                        else 'docs/testing/synthetic-accepted.md'
                    ),
                    'commit': completion,
                    'state': 'completed',
                    'result': 'passed',
                    'label': f'Synthetic accepted {kind} evidence.',
                }
                for kind in node['requiredEvidence']
            ] if is_accepted else []
        return value

    @staticmethod
    def _reopen(queue, identifiers, *, reason, status='awaiting_ci'):
        value = json.loads(queue.read_text())
        selected = set(identifiers)
        found = set()
        for node in value['nodes']:
            if node['id'] in selected:
                if node['status'] != 'done':
                    raise AssertionError(node['id'])
                node['status'] = status
                node['completionCommit'] = None
                node['reason'] = reason
                found.add(node['id'])
        if found != selected:
            raise AssertionError(selected - found)
        queue.write_text(json.dumps(value))

    def _queue_commit(self, repo, subject, progress):
        marker = repo / 'commit-marker'
        if not marker.exists():
            marker.write_text(subject)
        self._git(repo, 'add', '.')
        self._git(repo, 'commit', '-q', '--cleanup=verbatim', '-m', self._message(
            subject, *progress.queue, *progress.feature,
        ))
        return self._git(repo, 'rev-parse', 'HEAD').strip()

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
