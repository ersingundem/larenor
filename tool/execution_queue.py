#!/usr/bin/env python3
"""Validate and read the durable roadmap. Never execute work or update its state."""

import argparse
from datetime import date
import json
import os
from pathlib import Path
import re
import stat
import sys

MAX_BYTES = 1024 * 1024
MAX_NODES = 512
FEATURES = frozenset('F%02d' % n for n in range(1, 64))
DEFAULT_FILE = Path(__file__).resolve().parents[1] / 'docs/execution-queue.json'
STATUSES = ('pending', 'in_progress', 'awaiting_ci', 'needs_user', 'done')
LABELS = dict(zip(STATUSES, ('Bekliyor', 'Çalışılıyor', 'CI bekliyor',
                             'Kullanıcı gerekiyor', 'Kanıtla tamamlandı')))
EVIDENCE_KINDS = {'test', 'review', 'ci', 'manual'}
ID = re.compile(r'[A-Z][A-Za-z0-9]*(?:[.-][A-Za-z0-9]+)*\Z')
SHA = re.compile(r'[0-9a-f]{40}\Z')
CI_REF = re.compile(r'https://github\.com/ersingundem/larenor/actions/runs/[1-9][0-9]{0,19}\Z')
LOCAL_REF = re.compile(r'(?:docs|contracts|tool|test|server|integration_test)/[A-Za-z0-9_./-]+\Z')


class QueueError(ValueError):
    """Static, non-sensitive failure codes suitable for offline CLI output."""


def require(condition, code='invalid_schema'):
    if not condition:
        raise QueueError(code)


def text(value):
    require(isinstance(value, str) and 0 < len(value) <= 2000, 'invalid_text')
    require(all(c.isprintable() and ord(c) >= 32 and not 127 <= ord(c) <= 159
                and not 0xD800 <= ord(c) <= 0xDFFF
                and ord(c) not in range(0x202A, 0x202F)
                and ord(c) not in range(0x2066, 0x206A) for c in value), 'invalid_text')
    return value


def fields(value, expected):
    require(type(value) is dict and set(value) == set(expected))


def strings(value, *, nonempty=False):
    require(type(value) is list)
    require(len(value) <= MAX_NODES, 'schema_limit')
    require(not nonempty or bool(value))
    for item in value:
        text(item)
    require(len(set(value)) == len(value), 'duplicate_value')
    return value


def reference(value):
    text(value)
    require(bool(LOCAL_REF.fullmatch(value)) and '..' not in value.split('/')
            and '//' not in value and not value.endswith('/'), 'invalid_reference')


def references(value):
    for item in strings(value, nonempty=True):
        reference(item)


def _budget(value):
    pending = [(value, 0)]
    count = 0
    while pending:
        item, depth = pending.pop()
        count += 1
        require(depth <= 20 and count <= 50000, 'schema_limit')
        if isinstance(item, dict):
            require(len(item) <= 64, 'schema_limit')
            pending.extend((v, depth + 1) for v in item.values())
        elif isinstance(item, list):
            require(len(item) <= MAX_NODES, 'schema_limit')
            pending.extend((v, depth + 1) for v in item)


def _evidence(item):
    fields(item, ('kind', 'ref', 'commit', 'state', 'result', 'label'))
    require(isinstance(item['kind'], str) and item['kind'] in EVIDENCE_KINDS, 'invalid_evidence')
    require(isinstance(item['commit'], str) and bool(SHA.fullmatch(item['commit'])),
            'invalid_evidence')
    text(item['label'])
    require(item['state'] in ('queued', 'in_progress', 'completed'), 'invalid_evidence')
    if item['state'] == 'completed':
        require(item['result'] in ('passed', 'failed', 'cancelled', 'skipped'), 'invalid_evidence')
    else:
        require(item['kind'] == 'ci' and item['result'] is None, 'invalid_evidence')
    if item['kind'] == 'ci':
        require(isinstance(item['ref'], str) and bool(CI_REF.fullmatch(item['ref'])),
                'invalid_evidence')
    else:
        reference(item['ref'])


def validate_queue(data):
    _budget(data)
    fields(data, ('schemaVersion', 'title', 'updatedAt', 'selectedFeatures', 'sources', 'nodes'))
    require(type(data['schemaVersion']) is int and data['schemaVersion'] == 1)
    text(data['title'])
    require(isinstance(data['updatedAt'], str) and
            bool(re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', data['updatedAt'])))
    try:
        date.fromisoformat(data['updatedAt'])
    except ValueError:
        raise QueueError('invalid_schema') from None
    require(set(strings(data['selectedFeatures'])) == FEATURES, 'selected_features_mismatch')
    references(data['sources'])
    require(type(data['nodes']) is list and 0 < len(data['nodes']) <= MAX_NODES, 'schema_limit')
    nodes = {}
    for node in data['nodes']:
        require(type(node) is dict and isinstance(node.get('id'), str)
                and bool(ID.fullmatch(node['id'])) and len(node['id']) <= 64)
        require(node['id'] not in nodes, 'duplicate_id')
        nodes[node['id']] = node
    require({i for i, n in nodes.items() if i in FEATURES and n.get('kind') == 'task'} == FEATURES,
            'selected_features_mismatch')
    for node in nodes.values():
        kind = node.get('kind')
        require(kind in ('group', 'checkpoint', 'task'))
        base = ('id', 'kind', 'parent', 'title')
        fields(node, base if kind == 'group' else base + (
            'status', 'dependsOn', 'finishDependsOn', 'sources', 'scope', 'acceptance',
            'requiredEvidence', 'evidence', 'completionCommit', 'reason'))
        text(node['title'])
        parent = node['parent']
        require(parent is None or isinstance(parent, str))
        require(parent is None or parent in nodes, 'unknown_reference')
        require(parent is None or nodes[parent].get('kind') == 'group')
        if kind == 'group':
            continue
        require(node['status'] in STATUSES)
        require(kind != 'checkpoint' or node['status'] == 'done')
        for dependency in strings(node['dependsOn']) + strings(node['finishDependsOn']):
            require(dependency in nodes, 'unknown_reference')
        require(not set(node['dependsOn']) & set(node['finishDependsOn']), 'duplicate_value')
        references(node['sources'])
        text(node['scope'])
        strings(node['acceptance'], nonempty=True)
        required = strings(node['requiredEvidence'], nonempty=True)
        require(set(required) <= EVIDENCE_KINDS)
        require({'test', 'review', 'ci'} <= set(required) or
                {'manual', 'review'} <= set(required))
        require(type(node['evidence']) is list and len(node['evidence']) <= 32, 'schema_limit')
        for proof in node['evidence']:
            _evidence(proof)
        commit = node['completionCommit']
        require(commit is None or (isinstance(commit, str) and bool(SHA.fullmatch(commit))))
        if node['reason'] is not None:
            text(node['reason'])
        require(node['status'] != 'needs_user' or node['reason'] is not None, 'reason_required')
        if node['status'] == 'done':
            proofs = node['evidence']
            require(commit is not None and bool(proofs)
                    and all(p['commit'] == commit and p['state'] == 'completed'
                            and p['result'] == 'passed' for p in proofs)
                    and set(required) <= {p['kind'] for p in proofs}, 'completion_proof_required')
        else:
            require(commit is None)
    model = Queue(data, nodes)
    # Group membership participates in the DAG: a child cannot depend on its parent.
    edges = {i: model.children[i] if n['kind'] == 'group'
             else n['dependsOn'] + n['finishDependsOn'] for i, n in nodes.items()}
    require(all(edges[i] for i, n in nodes.items() if n['kind'] == 'group'))
    visiting, visited = set(), set()

    def visit(identifier):
        require(identifier not in visiting, 'dependency_cycle')
        if identifier in visited:
            return
        visiting.add(identifier)
        for dep in edges[identifier]:
            visit(dep)
        visiting.remove(identifier)
        visited.add(identifier)

    for identifier in nodes:
        visit(identifier)
    for identifier, node in nodes.items():
        if node['kind'] == 'group':
            continue
        if node['status'] in ('in_progress', 'awaiting_ci', 'done'):
            require(not model.blockers(identifier, finishing=node['status'] == 'done'),
                    'dependencies_unfinished')
    return model


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate_key')
        result[key] = value
    return result


def _integer(value):
    require(len(value) <= 20, 'schema_limit')
    return int(value)


def _nonfinite(_):
    raise QueueError('invalid_json')


def load_queue(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as stream:
            require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), 'input_unavailable')
            raw = stream.read(MAX_BYTES + 1)
    except OSError:
        raise QueueError('input_unavailable') from None
    require(len(raw) <= MAX_BYTES, 'input_limit')
    try:
        data = json.loads(raw.decode('utf-8'), object_pairs_hook=_pairs,
                          parse_int=_integer, parse_constant=_nonfinite)
    except (ValueError, UnicodeError, RecursionError) as error:
        if isinstance(error, QueueError):
            raise
        raise QueueError('invalid_json') from None
    return validate_queue(data)


class Queue:
    def __init__(self, data, nodes):
        self.data, self.nodes = data, nodes
        self.children = {i: [] for i in nodes}
        for identifier, node in nodes.items():
            if node['parent'] is not None:
                self.children[node['parent']].append(identifier)
        self._done = {}

    def is_done(self, identifier):
        if identifier not in self._done:
            node = self.nodes[identifier]
            self._done[identifier] = (all(self.is_done(i) for i in self.children[identifier])
                                      if node['kind'] == 'group' else node['status'] == 'done')
        return self._done[identifier]

    def blockers(self, identifier, finishing=False):
        node = self.nodes[identifier]
        deps = list(node['dependsOn'])
        if finishing:
            deps.extend(node['finishDependsOn'])
        return [dep for dep in deps if not self.is_done(dep)]

    def tasks(self, group=None):
        if group is not None:
            require(group in self.nodes and self.nodes[group]['kind'] == 'group', 'unknown_group')
        def inside(node):
            parent = node['parent']
            while parent is not None:
                if parent == group:
                    return True
                parent = self.nodes[parent]['parent']
            return False
        return [n for n in self.nodes.values() if n['kind'] == 'task'
                and (group is None or inside(n))]

    def counts(self, group=None):
        nodes = self.tasks(group)
        counts = {s: sum(n['status'] == s for n in nodes) for s in STATUSES}
        counts.update(total=len(nodes), featuresTotal=sum(n['id'] in FEATURES for n in nodes),
                      featuresDone=sum(n['id'] in FEATURES and n['status'] == 'done' for n in nodes))
        return counts

    def next_actions(self, limit=5, group=None):
        require(type(limit) is int and 1 <= limit <= 50, 'invalid_options')
        tasks = self.tasks(group)
        def select(status):
            return [dict(id=n['id'], title=n['title'], reason=n['reason'],
                         blockers=self.blockers(n['id']),
                         finishBlockers=self.blockers(n['id'], finishing=True))
                    for n in tasks if n['status'] == status]
        # Waiting rows are never silently hidden behind a ready-work limit.
        return {'active': select('in_progress'), 'awaitingCi': select('awaiting_ci'),
                'needsUser': select('needs_user'),
                'ready': [n for n in select('pending') if not n['blockers']][:limit]}

    def status(self, group=None):
        groups = [dict(id=i, title=n['title'], counts=self.counts(i))
                  for i, n in self.nodes.items() if n['kind'] == 'group'
                  and (n['parent'] == group)]
        return {'counts': self.counts(group), 'groups': groups}


def escape(value):
    return (value.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            .replace('|', '&#124;').replace('`', '&#96;').replace('[', '&#91;')
            .replace(']', '&#93;'))


def render(model, group=None, page=1, page_size=20, summary_only=False):
    require(type(page) is int and 1 <= page <= MAX_NODES
            and type(page_size) is int and 1 <= page_size <= 50, 'invalid_options')
    status = model.status(group)
    counts = status['counts']
    lines = ['F01–F63 yazılım kapısı: **%d/%d** (fiziksel kabul ayrı). Kalan kuyruk: **%d/%d iş kanıtla tamamlandı**.' %
             (counts['featuresDone'], counts['featuresTotal'], counts['done'], counts['total']),
             '', 'Gruplar ve önceki kabul checkpoint’leri iş sayısına dahil değildir.', '',
             '| Grup | İş | Biten | Çalışılan | CI | Kullanıcı |',
             '| --- | ---: | ---: | ---: | ---: | ---: |']
    for node in status['groups']:
        c = node['counts']
        lines.append('| %s — %s | %d | %d | %d | %d | %d |' %
                     (node['id'], escape(node['title']), c['total'], c['done'],
                      c['in_progress'], c['awaiting_ci'], c['needs_user']))
    if not summary_only:
        tasks = model.tasks(group)
        pages = max(1, (len(tasks) + page_size - 1) // page_size)
        require(page <= pages, 'invalid_options')
        lines.extend(['', 'İşler · sayfa %d/%d · en çok %d satır' % (page, pages, page_size), '',
                      '| ID | İş | Durum | Beklenen bağımlılık |', '| --- | --- | --- | --- |'])
        for node in tasks[(page - 1) * page_size:page * page_size]:
            blocked = ', '.join(model.blockers(node['id'])) or '—'
            lines.append('| %s | %s | %s | %s |' %
                         (node['id'], escape(node['title']), LABELS[node['status']], blocked))
    return '\n'.join(lines) + '\n'


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise QueueError('invalid_options')


def main(argv=None, stdout=None, stderr=None):
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    parser = Parser(description=__doc__)
    parser.add_argument('command', choices=('validate', 'status', 'next', 'render'))
    parser.add_argument('--file', type=Path, default=DEFAULT_FILE)
    parser.add_argument('--group')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--limit', type=int, default=5)
    parser.add_argument('--page', type=int, default=1)
    parser.add_argument('--page-size', type=int, default=20)
    parser.add_argument('--summary-only', action='store_true')
    try:
        args = parser.parse_args(argv)
        require(1 <= args.limit <= 50 and 1 <= args.page <= MAX_NODES
                and 1 <= args.page_size <= 50, 'invalid_options')
        model = load_queue(args.file)
        model.tasks(args.group)
        if args.command == 'validate':
            result = {'valid': True, 'tasks': model.counts()['total'], 'features': 63}
        elif args.command == 'status':
            result = model.status(args.group)
        elif args.command == 'next':
            result = model.next_actions(args.limit, args.group)
        else:
            result = render(model, args.group, args.page, args.page_size, args.summary_only)
        if args.json:
            stdout.write(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        elif args.command in ('render', 'status'):
            stdout.write(result if args.command == 'render' else
                         render(model, args.group, summary_only=True))
        elif args.command == 'validate':
            stdout.write('Kuyruk geçerli: %d iş, 63 seçili özellik.\n' % result['tasks'])
        else:
            for key, label in [('active', 'Devam'), ('awaitingCi', 'CI bekleyen'),
                               ('needsUser', 'Kullanıcı gereken'), ('ready', 'Başlanabilir')]:
                stdout.write(label + ':\n')
                for node in result[key]:
                    stdout.write('  %s — %s%s\n' % (node['id'], node['title'],
                                 ' · ' + node['reason'] if node['reason'] else ''))
                if not result[key]:
                    stdout.write('  —\n')
        return 0
    except QueueError as error:
        stderr.write('Kuyruk hatası: ' + str(error) + '\n')
        return 2


if __name__ == '__main__':
    sys.exit(main())
