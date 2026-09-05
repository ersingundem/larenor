"""Offline queue contract and real CLI journeys; no jobs or host actions run."""

import copy
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))
import execution_queue as queue

SHA = 'a' * 40
FEATURES = ['F%02d' % n for n in range(1, 64)]


def evidence(kind='test', **changes):
    value = {'kind': kind, 'ref': 'docs/PROGRESS.md', 'commit': SHA,
             'state': 'completed', 'result': 'passed', 'label': 'Sentetik kabul'}
    if kind == 'ci':
        value['ref'] = 'https://github.com/ersingundem/larenor/actions/runs/1234'
    value.update(changes)
    return value


def task(identifier, parent='G', **changes):
    value = {'id': identifier, 'kind': 'task', 'parent': parent,
             'title': identifier + ' kabul işi', 'status': 'pending',
             'dependsOn': ['B0'], 'finishDependsOn': [],
             'sources': ['docs/PROGRESS.md'], 'scope': 'Yalnız test kapsamı.',
             'acceptance': ['Kullanıcı sonucu ve sınırları doğrulanır.'],
             'requiredEvidence': ['test', 'review', 'ci'], 'evidence': [],
             'completionCommit': None, 'reason': None}
    value.update(changes)
    return value


def fixture():
    baseline = task('B0', None, kind='checkpoint', status='done', dependsOn=[],
                    evidence=[evidence(k) for k in ['test', 'review', 'ci']],
                    completionCommit=SHA)
    return {'schemaVersion': 1, 'title': 'Çevrimdışı yürütme kuyruğu',
            'updatedAt': '2026-09-05', 'selectedFeatures': FEATURES[:],
            'sources': ['docs/PROGRESS.md'], 'nodes': [baseline,
                {'id': 'G', 'kind': 'group', 'parent': None, 'title': 'İşler'},
                *[task(i) for i in FEATURES]]}


def complete(node):
    node.update(status='done', completionCommit=SHA,
                evidence=[evidence(k) for k in node['requiredEvidence']])


class ValidationTest(unittest.TestCase):
    def invalid(self, data, code):
        with self.assertRaisesRegex(queue.QueueError, '^' + code + '$'):
            queue.validate_queue(data)

    def test_baseline_and_parent_groups_do_not_inflate_completion(self):
        data = fixture()
        complete(data['nodes'][2])
        model = queue.validate_queue(data)
        self.assertEqual(model.counts()['total'], 63)
        self.assertEqual(model.counts()['done'], 1)
        self.assertEqual(model.counts()['featuresDone'], 1)
        self.assertFalse(model.is_done('G'))
        self.assertTrue(model.is_done('B0'))

    def test_derived_group_dependency_waits_for_every_child(self):
        data = fixture()
        data['nodes'].extend([
            {'id': 'P', 'kind': 'group', 'parent': None, 'title': 'Paket'},
            task('A', 'P'), task('B', None, dependsOn=['P'])])
        model = queue.validate_queue(data)
        self.assertEqual(model.blockers('B'), ['P'])
        complete(data['nodes'][-2])
        self.assertEqual(queue.validate_queue(data).blockers('B'), [])

    def test_unknown_dependency_and_parent_rejected(self):
        for field in ['dependsOn', 'finishDependsOn', 'parent']:
            data = fixture()
            data['nodes'][2][field] = 'UNKNOWN' if field == 'parent' else ['UNKNOWN']
            self.invalid(data, 'unknown_reference')

    def test_duplicate_id_dependency_feature_and_json_key_rejected(self):
        data = fixture(); data['nodes'].append(copy.deepcopy(data['nodes'][2]))
        self.invalid(data, 'duplicate_id')
        data = fixture(); data['nodes'][2]['dependsOn'] = ['B0', 'B0']
        self.invalid(data, 'duplicate_value')
        data = fixture(); data['selectedFeatures'].append('F01')
        self.invalid(data, 'duplicate_value')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'queue.json'
            path.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaisesRegex(queue.QueueError, '^duplicate_key$'):
                queue.load_queue(path)

    def test_task_and_parent_and_finish_dependency_cycles_rejected(self):
        for cycle in ['task', 'parent', 'finish']:
            data = fixture()
            if cycle == 'task':
                data['nodes'][2]['dependsOn'] = ['F02']
                data['nodes'][3]['dependsOn'] = ['F01']
            elif cycle == 'finish':
                data['nodes'][2]['finishDependsOn'] = ['F02']
                data['nodes'][3]['dependsOn'] = ['F01']
            else:
                data['nodes'][1]['parent'] = 'G'
            self.invalid(data, 'dependency_cycle')
        data = fixture(); data['nodes'][2]['dependsOn'] = ['G']
        self.invalid(data, 'dependency_cycle')

    def test_all_selected_features_required_even_if_selection_list_tampered(self):
        for change in ['node', 'selection', 'both', 'kind']:
            data = fixture()
            if change in ['node', 'both']: data['nodes'].pop()
            if change in ['selection', 'both']: data['selectedFeatures'].pop()
            if change == 'kind': data['nodes'][-1]['kind'] = 'checkpoint'
            self.invalid(data, 'selected_features_mismatch')

    def test_done_without_each_required_proof_or_matching_commit_rejected(self):
        for change in ['empty', 'review_missing', 'wrong_commit', 'failed_ci', 'queued_ci',
                       'missing_commit', 'skipped_ci']:
            data = fixture(); node = data['nodes'][2]; complete(node)
            if change == 'empty': node['evidence'] = []
            elif change == 'review_missing': node['evidence'].pop(1)
            elif change == 'wrong_commit': node['evidence'][0]['commit'] = 'b' * 40
            elif change == 'failed_ci': node['evidence'][2]['result'] = 'failed'
            elif change == 'queued_ci': node['evidence'][2].update(state='queued', result=None)
            elif change == 'missing_commit': node['completionCommit'] = None
            else: node['evidence'][2]['result'] = 'skipped'
            self.invalid(data, 'completion_proof_required')

    def test_done_and_active_cannot_ignore_dependencies(self):
        for status in ['done', 'in_progress', 'awaiting_ci']:
            data = fixture(); node = data['nodes'][2]
            node['dependsOn'] = ['F02']; node['status'] = status
            if status == 'done': complete(node)
            self.invalid(data, 'dependencies_unfinished')

    def test_coreless_work_may_start_before_managed_profile_gate_but_not_finish(self):
        data = fixture(); node = data['nodes'][2]
        node.update(finishDependsOn=['F02'], status='in_progress')
        model = queue.validate_queue(data)
        self.assertEqual(model.blockers('F01'), [])
        self.assertEqual(model.blockers('F01', finishing=True), ['F02'])
        complete(node)
        self.invalid(data, 'dependencies_unfinished')

    def test_ci_metadata_does_not_accept_other_hosts_queries_credentials_or_short_sha(self):
        for ref in ['https://example.com/actions/runs/1',
                    'https://github.com/another/repo/actions/runs/1',
                    'https://github.com/ersingundem/larenor/actions/runs/1?token=secret',
                    'https://u:p@github.com/ersingundem/larenor/actions/runs/1']:
            data = fixture(); data['nodes'][0]['evidence'][2]['ref'] = ref
            self.invalid(data, 'invalid_evidence')
        data = fixture(); data['nodes'][0]['evidence'][2]['commit'] = '123abcd'
        self.invalid(data, 'invalid_evidence')

    def test_bounds_strict_types_unknown_fields_and_paths(self):
        cases = [({'schemaVersion': True}, 'invalid_schema'),
                 ({'schemaVersion': 1.0}, 'invalid_schema'),
                 ({'run': 'echo ignored'}, 'invalid_schema'),
                 ({'updatedAt': '2026-02-30'}, 'invalid_schema'),
                 ({'title': 'X' * 2001}, 'invalid_text'),
                 ({'title': 'private\x1b[31m'}, 'invalid_text'),
                 ({'sources': ['../secrets']}, 'invalid_reference')]
        for patch, code in cases:
            data = fixture(); data.update(patch); self.invalid(data, code)
        for field, value, code in [('status', 'complete', 'invalid_schema'),
                                    ('reason', 'x' * 2001, 'invalid_text'),
                                    ('requiredEvidence', [], 'invalid_schema'),
                                    ('dependsOn', ['B0'] * 513, 'schema_limit')]:
            data = fixture(); data['nodes'][2][field] = value; self.invalid(data, code)

    def test_manual_block_requires_reason_and_does_not_look_done(self):
        data = fixture(); node = data['nodes'][2]
        node.update(status='needs_user', reason='Fiziksel test tableti gerekiyor.')
        model = queue.validate_queue(data)
        self.assertEqual(model.counts()['needs_user'], 1)
        self.assertFalse(model.is_done('F01'))
        node['reason'] = None; self.invalid(data, 'reason_required')

    def test_bounded_reader_rejects_oversize_depth_nonfinite_invalid_utf8_and_missing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'bad.json'
            samples = [(b' ' * (queue.MAX_BYTES + 1), 'input_limit'),
                       (b'[' * 40 + b']' * 40, 'schema_limit'),
                       (b'{"n":NaN}', 'invalid_json'),
                       (b'\xff', 'invalid_json')]
            for content, code in samples:
                path.write_bytes(content)
                with self.assertRaisesRegex(queue.QueueError, '^' + code + '$'):
                    queue.load_queue(path)
            with self.assertRaisesRegex(queue.QueueError, '^input_unavailable$'):
                queue.load_queue(Path(directory) / 'missing.json')


class CliJourneyTest(unittest.TestCase):
    def run_cli(self, argv):
        out, err = io.StringIO(), io.StringIO()
        result = queue.main(argv, stdout=out, stderr=err)
        return result, out.getvalue(), err.getvalue()

    def test_next_survives_restart_and_moves_only_after_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'queue.json'; data = fixture()
            data['nodes'][2]['status'] = 'in_progress'
            data['nodes'][3]['dependsOn'] = ['F01']
            path.write_text(json.dumps(data))
            first = self.run_cli(['next', '--file', str(path), '--json'])
            self.assertEqual(first[0], 0)
            view = json.loads(first[1]); self.assertEqual(view['active'][0]['id'], 'F01')
            self.assertNotIn('F02', [n['id'] for n in view['ready']])
            self.assertEqual(first, self.run_cli(['next', '--file', str(path), '--json']))
            complete(data['nodes'][2]); path.write_text(json.dumps(data))
            view = json.loads(self.run_cli(['next', '--file', str(path), '--json'])[1])
            self.assertEqual(view['active'], [])
            self.assertEqual(view['ready'][0]['id'], 'F02')

    def test_waiting_ci_and_manual_branch_do_not_block_other_ready_tasks(self):
        data = fixture(); data['nodes'][2]['status'] = 'awaiting_ci'
        data['nodes'][2]['evidence'] = [evidence('ci', state='in_progress', result=None)]
        data['nodes'][3].update(status='needs_user', reason='Test cihazı yok.')
        model = queue.validate_queue(data); view = model.next_actions(limit=2)
        self.assertEqual([n['id'] for n in view['ready']], ['F03', 'F04'])
        self.assertEqual(view['awaitingCi'][0]['id'], 'F01')
        self.assertEqual(view['needsUser'][0]['id'], 'F02')

    def test_render_paginates_and_escapes_data_without_running_or_writing_it(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'queue.json'; data = fixture()
            data['nodes'][2]['title'] = '<script>|$(touch NEVER)|`echo unsafe`'
            path.write_text(json.dumps(data)); before = path.read_bytes()
            result, output, error = self.run_cli(['render', '--file', str(path),
                                                '--group', 'G', '--page-size', '2'])
            self.assertEqual((result, error), (0, ''))
            self.assertIn('&lt;script&gt;', output)
            self.assertIn('F01', output); self.assertIn('F02', output)
            self.assertNotIn('| F03 |', output)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ['queue.json'])
            second = self.run_cli(['render', '--file', str(path), '--group', 'G',
                                   '--page-size', '2', '--page', '2'])[1]
            self.assertIn('| F03 |', second); self.assertNotIn('| F01 |', second)

    def test_invalid_cli_input_fails_statically_without_traceback_or_data_leak(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'queue.json'; path.write_text('{"secret":"DO_NOT_ECHO"}')
            result, out, err = self.run_cli(['validate', '--file', str(path)])
            self.assertEqual(result, 2); self.assertEqual(out, '')
            self.assertNotIn('DO_NOT_ECHO', err); self.assertNotIn('Traceback', err)
        for args in [['next', '--limit', '0'], ['status', '--group', 'NOPE'],
                     ['render', '--page-size', '100000'], ['execute', 'F01']]:
            self.assertEqual(self.run_cli(args)[0], 2)

    def test_real_queue_matches_all_selected_sources_and_stays_pending(self):
        model = queue.load_queue(ROOT / 'docs/execution-queue.json')
        selected = json.loads((ROOT / 'docs/feature-candidates-2026-09-05.json').read_text())
        remote = json.loads((ROOT / 'docs/remote-access-plan-2026-09-05.json').read_text())
        ids = {'F%02d' % n for n in selected['selected'] + remote['selected']}
        self.assertEqual(set(model.data['selectedFeatures']), ids)
        self.assertTrue(all(model.nodes[i]['status'] == 'pending' for i in ids))
        self.assertEqual(model.nodes['S06.3a']['status'], 'in_progress')
        for number, dependencies in selected['implementation']['requires'].items():
            self.assertTrue(set(dependencies) <= set(model.nodes['F%02d' % int(number)]['dependsOn']))
        for feature in remote['features']:
            node = model.nodes['F%02d' % feature['id']]
            self.assertNotIn('B3', node['dependsOn'])
            self.assertIn('B3', node['finishDependsOn'])
        for identifier in ['S06.3' + c for c in 'abcdef'] + ['S06.4', 'S06.5', 'S06.6',
                          'S07', 'S08', 'S09', 'FINAL.UI', 'FINAL.README', 'MANUAL.INSTALL']:
            self.assertIn(identifier, model.nodes)
        self.assertEqual(model.counts()['done'], 0)
        self.assertEqual(model.counts()['featuresTotal'], 63)

    def test_real_cli_validate_status_and_summary_document(self):
        run = subprocess.run([sys.executable, str(ROOT / 'tool/execution_queue.py'),
                              'validate'], cwd=ROOT, capture_output=True, text=True, check=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        result, text, err = self.run_cli(['status', '--json'])
        self.assertEqual(result, 0, err)
        self.assertEqual(json.loads(text)['counts']['featuresTotal'], 63)
        summary = self.run_cli(['render', '--summary-only'])[1]
        document = (ROOT / 'docs/EXECUTION_QUEUE.md').read_text()
        self.assertIn(summary.strip(), document)


if __name__ == '__main__':
    unittest.main()
