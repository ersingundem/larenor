#!/usr/bin/env python3
"""Manual native CI adapter for journaled managed Jellyfin create/start."""

import json
import os
from pathlib import Path
import re
import signal
import sys

from tool import jellyfin_storage_smoke as smoke


class ManagedCIError(Exception):
    """Static evidence failure; raw Engine and helper data never escape."""


class _Cancelled(BaseException):
    pass


def require(value):
    if not value:
        raise ManagedCIError('managed_characterization_evidence_invalid')


def validate_launch(environment, system, machine, uid):
    selected = smoke.native_platform(environment, system, machine, uid)
    event = environment.get('GITHUB_EVENT_NAME')
    repository = environment.get('GITHUB_REPOSITORY')
    manual = (event == 'workflow_dispatch'
              and environment.get('GITHUB_REF') == 'refs/heads/main'
              and environment.get('GITHUB_BASE_REF') == ''
              and environment.get('PR_HEAD_REPOSITORY') == '')
    pull_request = (event == 'pull_request'
        and re.fullmatch(r'refs/pull/[1-9][0-9]*/merge', environment.get('GITHUB_REF', ''))
        and environment.get('GITHUB_BASE_REF') == 'main'
        and environment.get('PR_HEAD_REPOSITORY') == repository)
    require((manual or pull_request)
        and repository == 'ersingundem/larenor'
        and environment.get('GITHUB_WORKFLOW_SHA') == environment.get('GITHUB_SHA')
        and environment.get('EXPECTED_PLATFORM') == selected)
    return selected


def _same(left, right):
    if type(left) is not type(right):
        return False
    if type(right) is dict:
        return left.keys() == right.keys() and all(_same(left[key], value)
                                                   for key, value in right.items())
    if type(right) is list:
        return len(left) == len(right) and all(_same(a, b) for a, b in zip(left, right))
    return left == right


def validate_receipt(value, commit, selected):
    require(type(commit) is str and re.fullmatch(r'[0-9a-f]{40}', commit)
            and selected in ('linux/amd64', 'linux/arm64')
            and type(value) is dict and type(value.get('helper')) is dict)
    helper = value['helper']
    config, server_id = helper.get('configDigest'), value.get('serverId')
    require(type(config) is str and re.fullmatch(r'sha256:[0-9a-f]{64}', config)
            and type(server_id) is str and re.fullmatch(r'[0-9a-f]{32}', server_id))
    source, hashes = smoke.fixture_source(selected), smoke.source_hashes()
    expected = {
        'schemaVersion': 1, 'result': 'characterized', 'platform': selected,
        'catalogDigest': source.catalog.digest,
        'jellyfinManifestDigest': source.image.image.digest,
        'jellyfinConfigDigest': source.image.image.configDigest,
        'helper': {
            'configDigest': config, 'platform': selected, 'sourceCommit': commit,
            'publishedManifestDigest': None,
            'helperSourceSha256': hashes['tool/volume_bootstrap_helper.py'],
            'probeSourceSha256': hashes['tool/jellyfin_storage_probe.py'],
            'dockerfileSha256': hashes['server/Dockerfile.volume-bootstrap'],
            'sourceHashes': hashes,
        },
        'volumeCount': 2, 'restartCount': 1, 'serverId': server_id,
        'containerMode': 'journaled_managed_v2', 'containerJournalVersion': 2,
        'bootstrapAccountConfigured': False, 'installAvailable': False,
        'imageState': 'ready',
        'volumeStates': ['observed_requires_bootstrap'] * 2,
    }
    require(_same(value, expected))


def run():
    selected = validate_launch(
        os.environ, smoke.platform.system(), smoke.platform.machine(), os.geteuid(),
    )
    commit = os.environ['GITHUB_SHA']
    owner = smoke.EphemeralDaemon()
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGALRM)
    previous = {item: signal.getsignal(item) for item in signals}

    def cancel(_signum, _frame):
        for item in signals:
            signal.signal(item, signal.SIG_IGN)
        owner.emergency_cleanup()
        raise _Cancelled()

    try:
        for item in signals:
            signal.signal(item, cancel)
        signal.alarm(1200)
        with smoke.diagnostic_phase('source_capture'):
            binding = smoke.capture_source(commit)
        with owner as daemon:
            with smoke.diagnostic_phase('characterization'):
                value = smoke.characterize(
                    daemon, checkout_binding=binding, managed=True,
                )
        with smoke.diagnostic_phase('source_recheck'):
            smoke.check_source(binding)
        validate_receipt(value, commit, selected)
        print(json.dumps(value, sort_keys=True, separators=(',', ':')))
    finally:
        signal.alarm(0)
        for item, handler in previous.items():
            signal.signal(item, handler)


def _unique(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value)
        value[key] = item
    return value


def _nonfinite(_value):
    raise ManagedCIError('managed_characterization_evidence_invalid')


def verify(path):
    try:
        with Path(path).open('rb') as source:
            raw = source.read(32769)
        require(0 < len(raw) <= 32768)
        value = json.loads(raw, object_pairs_hook=_unique, parse_constant=_nonfinite)
        commit = os.environ.get('GITHUB_SHA', '')
        selected = os.environ.get('EXPECTED_PLATFORM', '')
        smoke.verify_checkout(commit)
        validate_receipt(value, commit, selected)
        print('managed_characterization_receipt_verified')
    except ManagedCIError:
        raise
    except Exception:
        raise ManagedCIError('managed_characterization_evidence_invalid') from None


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    try:
        if args == ['--run-ephemeral-ci']:
            run()
        elif len(args) == 2 and args[0] == '--verify-receipt':
            verify(args[1])
        else:
            raise ManagedCIError('managed_characterization_evidence_invalid')
        return 0
    except _Cancelled:
        print('managed_characterization_cancelled', file=sys.stderr)
    except Exception as error:
        print(smoke.failure_diagnostic(error), file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
