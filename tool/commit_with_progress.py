#!/usr/bin/env python3
"""Create a Git commit with evidence-backed Larenor progress trailers."""

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys

import execution_queue

RESERVED_TRAILER = re.compile(
    r'(?im)^Larenor-(?:Queue|Feature)-Progress[ \t]*:'
)


class CommitProgressError(ValueError):
    """Static error codes that do not expose commit or queue contents."""


@dataclass(frozen=True)
class Progress:
    queue_done: int
    queue_total: int
    feature_done: int
    feature_total: int

    @staticmethod
    def _value(done, total):
        return '%d/%d (%.1f%%)' % (done, total, done * 100.0 / total)

    @property
    def queue_trailer(self):
        return self._value(self.queue_done, self.queue_total)

    @property
    def feature_trailer(self):
        return self._value(self.feature_done, self.feature_total)


def progress_for(model):
    counts = model.counts()
    values = (counts['done'], counts['total'],
              counts['featuresDone'], counts['featuresTotal'])
    if (any(type(value) is not int for value in values)
            or values[1] <= 0 or values[3] <= 0
            or not 0 <= values[0] <= values[1]
            or not 0 <= values[2] <= values[3]):
        raise CommitProgressError('invalid_progress')
    return Progress(*values)


def message_with_progress(message, progress):
    if not isinstance(message, str) or not message.strip() or '\x00' in message:
        raise CommitProgressError('invalid_message')
    if RESERVED_TRAILER.search(message):
        raise CommitProgressError('reserved_progress_trailer')
    body = message.rstrip('\r\n')
    return (
        body + '\n\n'
        'Larenor-Queue-Progress: ' + progress.queue_trailer + '\n'
        'Larenor-Feature-Progress: ' + progress.feature_trailer + '\n'
    )


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise CommitProgressError('invalid_options')


def main(argv=None, stdout=None, stderr=None):
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    parser = Parser(description=__doc__)
    parser.add_argument('-m', '--message', action='append', required=True,
                        help='commit message paragraph; may be repeated')
    parser.add_argument('--queue', type=Path, default=execution_queue.DEFAULT_FILE,
                        help='validated execution queue source')
    parser.add_argument('--dry-run', action='store_true',
                        help='print the final message without creating a commit')
    try:
        args = parser.parse_args(argv)
        model = execution_queue.load_queue(args.queue)
        progress = progress_for(model)
        message = message_with_progress('\n\n'.join(args.message), progress)
        if args.dry_run:
            stdout.write(message)
            return 0
        run = subprocess.run(
            ['git', 'commit', '--cleanup=verbatim', '--file=-'],
            input=message,
            text=True,
            check=False,
        )
        return run.returncode
    except (CommitProgressError, execution_queue.QueueError) as error:
        stderr.write('Commit ilerleme hatası: ' + str(error) + '\n')
        return 2
    except OSError:
        stderr.write('Commit ilerleme hatası: git_unavailable\n')
        return 2


if __name__ == '__main__':
    sys.exit(main())
