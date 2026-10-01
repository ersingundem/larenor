#!/usr/bin/env python3
"""Verify evidence-backed progress on every commit added by a pull request."""

import argparse
from collections import Counter
from dataclasses import dataclass
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import execution_queue


TRAILER_PREFIX = re.compile(r'(?m)^Larenor-(Queue|Feature)-Progress[ \t]*:')
TRAILER = re.compile(
    r'(?m)^Larenor-(Queue|Feature)-Progress: '
    r'([0-9]+)/([0-9]+) \(([0-9]+\.[0-9])%\)$')
LOCAL_EVIDENCE = re.compile(
    r'(?:docs|contracts|tool|test|server|integration_test)/'
    r'[A-Za-z0-9_./-]*[A-Za-z0-9_-]')
CI_EVIDENCE = re.compile(
    r'https://github\.com/ersingundem/larenor/actions/runs/[1-9][0-9]{0,19}')
REOPEN_STATUSES = frozenset({'awaiting_ci', 'reworking'})


class ProgressCheckError(ValueError):
    """Stable failure codes that do not echo commit messages."""


@dataclass(frozen=True)
class ProgressValues:
    queue: tuple
    feature: tuple


@dataclass(frozen=True)
class ProgressEntry:
    commit: str
    values: ProgressValues
    parents: tuple[str, ...] = ()


def _parse_value(match):
    done, total = int(match.group(2)), int(match.group(3))
    if total <= 0 or done < 0 or done > total:
        raise ProgressCheckError('invalid_progress_value')
    if match.group(4) != f'{done * 100.0 / total:.1f}':
        raise ProgressCheckError('invalid_progress_percentage')
    return done, total


def parse_message(message):
    prefixes = TRAILER_PREFIX.findall(message)
    matches = list(TRAILER.finditer(message))
    if prefixes.count('Queue') != 1 or prefixes.count('Feature') != 1:
        raise ProgressCheckError('missing_or_duplicate_progress_trailer')
    if len(matches) != 2:
        raise ProgressCheckError('malformed_progress_trailer')
    values = {match.group(1): _parse_value(match) for match in matches}
    if set(values) != {'Queue', 'Feature'}:
        raise ProgressCheckError('missing_or_duplicate_progress_trailer')
    return ProgressValues(values['Queue'], values['Feature'])


def validate_sequence(history, expected):
    if not history:
        raise ProgressCheckError('empty_commit_range')
    previous = history[0]
    for current in history[1:]:
        if (current.queue[0] < previous.queue[0]
                or current.queue[1] < previous.queue[1]
                or current.feature[0] < previous.feature[0]
                or current.feature[1] < previous.feature[1]):
            raise ProgressCheckError('progress_regressed')
        previous = current
    if history[-1] != expected:
        raise ProgressCheckError('head_progress_mismatch')


class RepositoryQueueHistory:
    """Load validated queue snapshots from immutable Git trees."""

    def __init__(self, repo, relative):
        self.repo = repo.resolve()
        self.relative = relative
        self._cache = {}

    @classmethod
    def for_path(cls, repo, queue_path):
        repo = repo.resolve()
        try:
            relative = queue_path.resolve().relative_to(repo)
        except ValueError:
            return None
        return cls(repo, relative)

    def model(self, commit):
        cached = self._cache.get(commit)
        if cached is not None:
            return cached
        if re.fullmatch(r'[0-9a-f]{40}', commit) is None:
            raise ProgressCheckError('invalid_commit_range')
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / 'execution-queue.json'
            with snapshot.open('wb') as output:
                completed = subprocess.run(
                    ['git', 'show', f'{commit}:{self.relative.as_posix()}'],
                    cwd=self.repo,
                    stdout=output,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
            if completed.returncode != 0:
                raise ProgressCheckError('invalid_queue_ref')
            model = execution_queue.load_queue(snapshot)
        self._cache[commit] = model
        return model

    @staticmethod
    def progress(model):
        counts = model.counts()
        return ProgressValues(
            (counts['done'], counts['total']),
            (counts['featuresDone'], counts['featuresTotal']),
        )

    def _reference_exists(self, commit, reference):
        if CI_EVIDENCE.fullmatch(reference):
            return True
        if LOCAL_EVIDENCE.fullmatch(reference) is None:
            return False
        try:
            execution_queue.reference(reference)
        except execution_queue.QueueError:
            return False
        tree = subprocess.run(
            ['git', 'ls-tree', '-z', commit, '--', reference],
            cwd=self.repo,
            text=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if tree.returncode != 0 or not tree.stdout.endswith(b'\0'):
            return False
        records = tree.stdout[:-1].split(b'\0')
        if len(records) != 1:
            return False
        try:
            metadata, observed_path = records[0].split(b'\t', 1)
            mode, kind, object_id = metadata.split(b' ', 2)
        except ValueError:
            return False
        if (observed_path.decode('utf-8', 'strict') != reference
                or mode not in {b'100644', b'100755'}
                or kind != b'blob'
                or re.fullmatch(rb'[0-9a-f]{40}', object_id) is None):
            return False
        size = subprocess.run(
            ['git', 'cat-file', '-s', object_id.decode('ascii')],
            cwd=self.repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return (size.returncode == 0 and size.stdout.strip().isascii()
                and size.stdout.strip().isdigit() and int(size.stdout) > 0)

    @staticmethod
    def _evidence_references(reason):
        if not isinstance(reason, str):
            return set()
        references = set()
        for raw in reason.split():
            token = raw.strip('.,;:()[]{}<>')
            if (LOCAL_EVIDENCE.fullmatch(token)
                    or CI_EVIDENCE.fullmatch(token)):
                references.add(token)
        return references

    @staticmethod
    def _proofs(value):
        return Counter(json.dumps(item, sort_keys=True, separators=(',', ':'))
                       for item in value)

    def validate_reopening(self, parent, commit):
        previous = self.model(parent)
        current = self.model(commit)
        previous_counts = previous.counts()
        current_counts = current.counts()
        if (current_counts['total'] < previous_counts['total']
                or current_counts['featuresTotal'] < previous_counts['featuresTotal']):
            raise ProgressCheckError('invalid_progress_reopening')
        if not set(previous.nodes) <= set(current.nodes):
            raise ProgressCheckError('invalid_progress_reopening')

        previous_done = {
            node['id'] for node in previous.tasks() if node['status'] == 'done'
        }
        current_done = {
            node['id'] for node in current.tasks() if node['status'] == 'done'
        }
        reopened = previous_done - current_done
        if not reopened or current_done - previous_done:
            raise ProgressCheckError('invalid_progress_reopening')
        if previous_counts['done'] - current_counts['done'] != len(reopened):
            raise ProgressCheckError('invalid_progress_reopening')
        selected = set(previous.data['selectedFeatures'])
        if previous.data['selectedFeatures'] != current.data['selectedFeatures']:
            raise ProgressCheckError('invalid_progress_reopening')
        if (previous_counts['featuresDone'] - current_counts['featuresDone']
                != len(reopened & selected)):
            raise ProgressCheckError('invalid_progress_reopening')

        mutable = {'status', 'evidence', 'completionCommit', 'reason'}
        for identifier in reopened:
            old = previous.nodes[identifier]
            new = current.nodes[identifier]
            if (old['kind'] != 'task'
                    or old['status'] != 'done'
                    or new['status'] not in REOPEN_STATUSES
                    or new['completionCommit'] is not None):
                raise ProgressCheckError('invalid_progress_reopening')
            if any(old[key] != new[key] for key in old if key not in mutable):
                raise ProgressCheckError('invalid_progress_reopening')
            if self._proofs(old['evidence']) - self._proofs(new['evidence']):
                raise ProgressCheckError('invalid_progress_reopening')
            old_refs = self._evidence_references(old['reason'])
            new_refs = self._evidence_references(new['reason'])
            added_refs = new_refs - old_refs
            if (new['reason'] == old['reason'] or not added_refs
                    or not all(self._reference_exists(commit, ref)
                               for ref in added_refs)):
                raise ProgressCheckError('invalid_progress_reopening')


def validate_graph(entries, expected, queue_history=None):
    """Parallel histories may differ; progress must advance along ancestry."""
    if not entries:
        raise ProgressCheckError('empty_commit_range')
    values_by_commit = {entry.commit: entry.values for entry in entries}
    for entry in entries:
        if queue_history is not None:
            current_snapshot = queue_history.progress(
                queue_history.model(entry.commit))
            if entry.values != current_snapshot:
                raise ProgressCheckError('commit_progress_mismatch')
        for parent in entry.parents:
            previous = values_by_commit.get(parent)
            if previous is None:
                if queue_history is None:
                    continue  # An accepted base is outside this checked range.
                previous = queue_history.progress(queue_history.model(parent))
            current = entry.values
            if (current.queue[1] < previous.queue[1]
                    or current.feature[1] < previous.feature[1]):
                raise ProgressCheckError('progress_regressed')
            if (current.queue[0] < previous.queue[0]
                    or current.feature[0] < previous.feature[0]):
                if queue_history is None:
                    raise ProgressCheckError('progress_regressed')
                queue_history.validate_reopening(parent, entry.commit)
    if entries[-1].values != expected:
        raise ProgressCheckError('head_progress_mismatch')


def read_progress_entries(repo, base, head):
    common = subprocess.run(
        ['git', 'merge-base', base, head], cwd=repo, check=False, text=True,
        capture_output=True)
    merge_bases = common.stdout.splitlines()
    if common.returncode != 0 or len(merge_bases) != 1:
        raise ProgressCheckError('invalid_commit_range')
    merge_base = merge_bases[0]
    commits = subprocess.run(
        ['git', 'rev-list', '--reverse', '--topo-order',
         '--parents', f'{merge_base}..{head}'],
        cwd=repo, check=True, text=True, capture_output=True).stdout.splitlines()
    history = []
    for line in commits:
        commit, *parents = line.split()
        message = subprocess.run(
            ['git', 'show', '-s', '--format=%B', commit], cwd=repo,
            check=True, text=True, capture_output=True).stdout
        history.append(ProgressEntry(commit, parse_message(message), tuple(parents)))
    return history


def read_progress(repo, base, head):
    return [entry.values for entry in read_progress_entries(repo, base, head)]


def _display(value):
    done, total = value
    return f'{done}/{total} ({done * 100.0 / total:.1f}%)'


def format_report(entries):
    rows = [
        '### Commit ilerlemesi',
        '',
        '| Commit | Kuyruk | Yeni özellikler |',
        '| --- | ---: | ---: |',
    ]
    for entry in entries:
        rows.append(
            f'| `{entry.commit[:7]}` | {_display(entry.values.queue)} | '
            f'{_display(entry.values.feature)} |')
    return '\n'.join(rows) + '\n'


def expected_progress(queue_path):
    counts = execution_queue.load_queue(queue_path).counts()
    return ProgressValues(
        (counts['done'], counts['total']),
        (counts['featuresDone'], counts['featuresTotal']))


def expected_progress_at(repo, head, queue_path):
    """Read the expected queue from the immutable pull-request head tree.

    GitHub checks pull requests from a synthetic merge checkout. Reading the
    working tree there makes an unrelated main-branch queue advance invalidate
    an otherwise current pull-request trailer. Repository-owned queue files are
    therefore resolved from `head`; explicit external fixtures keep their
    existing file-based behavior.
    """
    repo = repo.resolve()
    queue_path = queue_path.resolve()
    history = RepositoryQueueHistory.for_path(repo, queue_path)
    if history is None:
        return expected_progress(queue_path)
    resolved = subprocess.run(
        ['git', 'rev-parse', '--verify', '--end-of-options',
         f'{head}^{{commit}}'],
        cwd=repo,
        text=True,
        capture_output=True,
        check=False,
    )
    resolved_head = resolved.stdout.strip()
    if (resolved.returncode != 0
            or not re.fullmatch(r'[0-9a-f]{40}', resolved_head)):
        raise ProgressCheckError('invalid_head_ref')
    return history.progress(history.model(resolved_head))


def main(argv=None, stdout=None, stderr=None):
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    parser.add_argument('--head', required=True)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--queue', type=Path,
                        default=execution_queue.DEFAULT_FILE)
    parser.add_argument('--summary', type=Path,
                        help='append the per-commit table to a CI summary file')
    try:
        args = parser.parse_args(argv)
        entries = read_progress_entries(args.repo, args.base, args.head)
        queue_history = RepositoryQueueHistory.for_path(args.repo, args.queue)
        validate_graph(
            entries,
            expected_progress_at(args.repo, args.head, args.queue),
            queue_history,
        )
        stdout.write(f'Commit ilerleme kapısı: {len(entries)} commit doğrulandı.\n')
        report = format_report(entries)
        stdout.write(report)
        if args.summary is not None:
            with args.summary.open('a', encoding='utf-8') as summary:
                summary.write(report)
        return 0
    except (ProgressCheckError, execution_queue.QueueError,
            subprocess.SubprocessError, OSError) as error:
        code = str(error) if isinstance(
            error, (ProgressCheckError, execution_queue.QueueError)) else 'git_error'
        stderr.write('Commit ilerleme kapısı: ' + code + '\n')
        return 2


if __name__ == '__main__':
    sys.exit(main())
