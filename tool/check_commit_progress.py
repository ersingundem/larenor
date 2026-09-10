#!/usr/bin/env python3
"""Verify evidence-backed progress on every commit added by a pull request."""

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys

import execution_queue


TRAILER_PREFIX = re.compile(r'(?m)^Larenor-(Queue|Feature)-Progress[ \t]*:')
TRAILER = re.compile(
    r'(?m)^Larenor-(Queue|Feature)-Progress: '
    r'([0-9]+)/([0-9]+) \(([0-9]+\.[0-9])%\)$')


class ProgressCheckError(ValueError):
    """Stable failure codes that do not echo commit messages."""


@dataclass(frozen=True)
class ProgressValues:
    queue: tuple
    feature: tuple


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


def read_progress(repo, base, head):
    ancestor = subprocess.run(
        ['git', 'merge-base', '--is-ancestor', base, head], cwd=repo,
        check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if ancestor.returncode != 0:
        raise ProgressCheckError('invalid_commit_range')
    commits = subprocess.run(
        ['git', 'rev-list', '--reverse', '--topo-order', f'{base}..{head}'],
        cwd=repo, check=True, text=True, capture_output=True).stdout.splitlines()
    history = []
    for commit in commits:
        message = subprocess.run(
            ['git', 'show', '-s', '--format=%B', commit], cwd=repo,
            check=True, text=True, capture_output=True).stdout
        history.append(parse_message(message))
    return history


def expected_progress(queue_path):
    counts = execution_queue.load_queue(queue_path).counts()
    return ProgressValues(
        (counts['done'], counts['total']),
        (counts['featuresDone'], counts['featuresTotal']))


def main(argv=None, stdout=None, stderr=None):
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    parser.add_argument('--head', required=True)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--queue', type=Path,
                        default=execution_queue.DEFAULT_FILE)
    try:
        args = parser.parse_args(argv)
        history = read_progress(args.repo, args.base, args.head)
        validate_sequence(history, expected_progress(args.queue))
        stdout.write(f'Commit ilerleme kapısı: {len(history)} commit doğrulandı.\n')
        return 0
    except (ProgressCheckError, execution_queue.QueueError,
            subprocess.SubprocessError, OSError) as error:
        code = str(error) if isinstance(
            error, (ProgressCheckError, execution_queue.QueueError)) else 'git_error'
        stderr.write('Commit ilerleme kapısı: ' + code + '\n')
        return 2


if __name__ == '__main__':
    sys.exit(main())
