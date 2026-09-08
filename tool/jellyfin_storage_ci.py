#!/usr/bin/env python3
"""Manual CI adapter for the owned ephemeral fixture, not an installer grant.

Only SIGINT/SIGTERM/the local 20-minute alarm get best-effort Python cleanup.
SIGKILL, a dead VM, or an uninterruptible kernel operation cannot be repaired by
this handler. No signal or cleanup operation selects an ambient Docker daemon.
"""
import json
import os
from pathlib import Path
import re
import signal
import sys

from tool import jellyfin_storage_smoke as smoke


class CIError(Exception):
    """Static CI protocol failure; no arbitrary diagnostics escape."""


class _Cancelled(BaseException):
    pass


def require(value):
    if not value:
        raise CIError('storage_characterization_evidence_invalid')


def validate_launch(environment, system, machine, uid):
    selected = smoke.native_platform(environment, system, machine, uid)
    require(environment.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
        and environment.get('GITHUB_REF') == 'refs/heads/main'
        and environment.get('GITHUB_REPOSITORY') == 'ersingundem/larenor'
        and environment.get('GITHUB_WORKFLOW_SHA') == environment.get('GITHUB_SHA')
        and environment.get('EXPECTED_PLATFORM') == selected)
    return selected


def _same(left, right):
    if type(left) is not type(right):
        return False
    if type(right) is dict:
        return left.keys() == right.keys() and all(_same(left[k], v) for k, v in right.items())
    if type(right) is list:
        return len(left) == len(right) and all(_same(a, b) for a, b in zip(left, right))
    return left == right


def validate_receipt(value, commit, selected):
    require(type(commit) is str and re.fullmatch(r'[0-9a-f]{40}', commit)
        and selected in ('linux/amd64', 'linux/arm64'))
    require(type(value) is dict and type(value.get('helper')) is dict)
    helper = value['helper']
    config = helper.get('configDigest')
    server_id = value.get('serverId')
    require(type(config) is str and re.fullmatch(r'sha256:[0-9a-f]{64}', config)
        and type(server_id) is str and re.fullmatch(r'[0-9a-f]{32}', server_id))
    source = smoke.fixture_source(selected)
    hashes = smoke.source_hashes()
    expected = {'schemaVersion':1, 'result':'characterized', 'platform':selected,
        'catalogDigest':source.catalog.digest, 'jellyfinManifestDigest':source.image.image.digest,
        'jellyfinConfigDigest':source.image.image.configDigest,
        'helper':{'configDigest':config, 'platform':selected, 'sourceCommit':commit,
            'publishedManifestDigest':None,
            'helperSourceSha256':hashes['tool/volume_bootstrap_helper.py'],
            'probeSourceSha256':hashes['tool/jellyfin_storage_probe.py'],
            'dockerfileSha256':hashes['server/Dockerfile.volume-bootstrap'], 'sourceHashes':hashes},
        'volumeCount':2, 'restartCount':1, 'serverId':server_id,
        'bootstrapAccountConfigured':False, 'installAvailable':False,
        'imageState':'ready', 'volumeStates':['observed_requires_bootstrap']*2}
    require(_same(value, expected))


def run():
    with smoke.diagnostic_phase('launch_validation'):
        selected = validate_launch(os.environ, smoke.platform.system(), smoke.platform.machine(), os.geteuid())
    commit = os.environ['GITHUB_SHA']
    owner = smoke.EphemeralDaemon()
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGALRM)
    previous = {sig:signal.getsignal(sig) for sig in signals}
    def cancel(signum, frame):
        # Repeated cancellation must not interrupt the first cleanup's finally.
        for sig in signals:
            signal.signal(sig, signal.SIG_IGN)
        if owner.process is not None:
            smoke._signal_group(owner.process, signal.SIGKILL)
        raise _Cancelled()
    try:
        for sig in signals:
            signal.signal(sig, cancel)
        signal.alarm(1200)
        with smoke.diagnostic_phase('source_capture'):
            binding = smoke.capture_source(commit)
        with owner as daemon:
            with smoke.diagnostic_phase('characterization'):
                value = smoke.characterize(daemon, checkout_binding=binding)
        with smoke.diagnostic_phase('source_recheck'):
            smoke.check_source(binding)
        with smoke.diagnostic_phase('receipt_validate'):
            validate_receipt(value, commit, selected)
        print(json.dumps(value, sort_keys=True, separators=(',', ':')))
    finally:
        signal.alarm(0)
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def _unique(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value)
        value[key] = item
    return value


def _nonfinite(_):
    raise CIError('storage_characterization_evidence_invalid')


def verify(path):
    with Path(path).open('rb') as source:
        raw = source.read(32769)
    require(0 < len(raw) <= 32768)
    value = json.loads(raw, object_pairs_hook=_unique, parse_constant=_nonfinite)
    commit, selected = os.environ.get('GITHUB_SHA', ''), os.environ.get('EXPECTED_PLATFORM', '')
    smoke.verify_checkout(commit)
    validate_receipt(value, commit, selected)
    print('storage_characterization_receipt_verified')


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    try:
        if args == ['--run-ephemeral-ci']:
            run()
        elif len(args) == 2 and args[0] == '--verify-receipt':
            with smoke.diagnostic_phase('receipt_verify'):
                verify(args[1])
        else:
            raise CIError('storage_characterization_evidence_invalid')
        return 0
    except _Cancelled:
        print('storage_characterization_cancelled', file=sys.stderr)
    except Exception as error:
        print(smoke.failure_diagnostic(error), file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
