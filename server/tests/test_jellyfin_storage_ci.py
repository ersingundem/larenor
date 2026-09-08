"""Offline manual CI launcher/receipt tests; never start Docker."""
import copy
import importlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))


def api():
    assert importlib.util.find_spec('tool.jellyfin_storage_ci') is not None, 'manual CI launcher absent'
    return importlib.import_module('tool.jellyfin_storage_ci')


def environment():
    return {'CI':'true','GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted',
            'RUNNER_ARCH':'X64','GITHUB_SHA':'a'*40,'GITHUB_WORKFLOW_SHA':'a'*40,
            'GITHUB_EVENT_NAME':'workflow_dispatch','GITHUB_REF':'refs/heads/main',
            'GITHUB_REPOSITORY':'ersingundem/larenor','EXPECTED_PLATFORM':'linux/amd64'}


def result(m):
    source = m.smoke.fixture_source('linux/amd64')
    hashes = m.smoke.source_hashes()
    helper = m.smoke.helper_attestation('sha256:'+'f'*64,
        {'Id':'sha256:'+'f'*64,'Os':'linux','Architecture':'amd64',
         'Config':{'Labels':m.smoke.source_labels('a'*40, hashes)}}, 'linux/amd64', 'a'*40)
    return {'schemaVersion':1,'result':'characterized','platform':'linux/amd64',
        'catalogDigest':source.catalog.digest,'jellyfinManifestDigest':source.image.image.digest,
        'jellyfinConfigDigest':source.image.image.configDigest,'helper':helper,
        'volumeCount':2,'restartCount':1,'serverId':'b'*32,'bootstrapAccountConfigured':False,
        'installAvailable':False,'imageState':'ready','volumeStates':['observed_requires_bootstrap']*2}


@pytest.mark.parametrize('field,value', [('GITHUB_REF','refs/heads/unreviewed'),
    ('GITHUB_EVENT_NAME','push'), ('GITHUB_REPOSITORY','other/fork'),
    ('GITHUB_WORKFLOW_SHA','b'*40), ('EXPECTED_PLATFORM','linux/arm64'),
    ('RUNNER_ENVIRONMENT','self-hosted')])
def test_launch_fails_before_daemon_when_manual_source_or_native_boundary_is_wrong(monkeypatch, field, value):
    m = api()
    env = environment()
    env[field] = value
    with pytest.raises((m.CIError, m.smoke.SmokeError)):
        m.validate_launch(env, 'Linux', 'x86_64', 0)


def test_launch_exact_native_platform_is_accepted():
    m = api()
    assert m.validate_launch(environment(), 'Linux', 'x86_64', 0) == 'linux/amd64'
    env = environment() | {'RUNNER_ARCH':'ARM64','EXPECTED_PLATFORM':'linux/arm64'}
    assert m.validate_launch(env, 'Linux', 'aarch64', 0) == 'linux/arm64'


@pytest.mark.parametrize('change', ['skip','counts','bool','source','platform','catalog','config',
    'hashes','published','extra','helper_extra','account','states'])
def test_receipt_rejects_incomplete_or_rebound_evidence(change):
    m = api()
    value = result(m)
    if change == 'skip': value['result'] = 'skipped'
    elif change == 'counts': value['restartCount'] = 0
    elif change == 'bool': value['schemaVersion'] = True
    elif change == 'source': value['helper']['sourceCommit'] = 'b'*40
    elif change == 'platform': value['helper']['platform'] = 'linux/arm64'
    elif change == 'catalog': value['catalogDigest'] = '0'*64
    elif change == 'config': value['jellyfinConfigDigest'] = 'sha256:'+'0'*64
    elif change == 'hashes': value['helper']['sourceHashes']['LICENSE'] = '0'*64
    elif change == 'published': value['helper']['publishedManifestDigest'] = 'sha256:'+'0'*64
    elif change == 'extra': value['privatePath'] = '/synthetic'
    elif change == 'helper_extra': value['helper']['Config'] = {'Env':['synthetic-private']}
    elif change == 'account': value['bootstrapAccountConfigured'] = True
    elif change == 'states': value['volumeStates'] = ['observed_requires_bootstrap']
    with pytest.raises(m.CIError):
        m.validate_receipt(value, 'a'*40, 'linux/amd64')


def test_valid_receipt_is_exact_and_does_not_promote_installation():
    m = api()
    value = result(m)
    assert m.validate_receipt(value, 'a'*40, 'linux/amd64') is None
    assert value['installAvailable'] is False


@pytest.mark.parametrize('signal_name', ['SIGINT','SIGTERM','SIGALRM'])
def test_signal_kills_only_owned_group_and_unwinds_cleanup_without_success(monkeypatch, capsys, signal_name):
    m = api()
    monkeypatch.setenv('GITHUB_SHA', 'a'*40)
    events = []
    handlers = {}
    owner = SimpleNamespace(process=SimpleNamespace(pid=12345))
    class Owned:
        def __enter__(self):
            events.append('enter')
            return owner
        def __exit__(self, *_):
            events.append('cleanup')
        @property
        def process(self): return owner.process
    monkeypatch.setattr(m, 'validate_launch', lambda *args: 'linux/amd64')
    monkeypatch.setattr(m.smoke, 'capture_source', lambda commit: ('a'*40, {}))
    monkeypatch.setattr(m.smoke, 'EphemeralDaemon', Owned)
    monkeypatch.setattr(m.smoke, '_signal_group', lambda proc, sig: events.append(('kill',proc.pid,sig)))
    monkeypatch.setattr(m.signal, 'getsignal', lambda sig: signal.SIG_DFL)
    monkeypatch.setattr(m.signal, 'signal', lambda sig, handler: handlers.__setitem__(sig, handler))
    monkeypatch.setattr(m.signal, 'alarm', lambda seconds: events.append(('alarm',seconds)))
    def interrupted(*args, **kwargs):
        handlers[getattr(signal, signal_name)](getattr(signal, signal_name), None)
    monkeypatch.setattr(m.smoke, 'characterize', interrupted)
    assert m.main(['--run-ephemeral-ci']) == 1
    assert ('kill',12345,signal.SIGKILL) in events
    assert events.index(('kill',12345,signal.SIGKILL)) < events.index('cleanup')
    assert ('alarm',1200) in events and events[-1] == ('alarm',0)
    output = capsys.readouterr()
    assert output.out == '' and output.err == 'storage_characterization_cancelled\n'
    assert all(handlers[sig] == signal.SIG_DFL for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGALRM))


@pytest.mark.parametrize('raw', [b'{}', b'{}'*20000, b'{"schemaVersion":1,"schemaVersion":1}', b'{"x":NaN}', b'\xff'])
def test_verifier_rejects_oversize_duplicate_or_invalid_payload(tmp_path, monkeypatch, raw, capsys):
    m = api()
    path = tmp_path/'receipt.json'
    path.write_bytes(raw)
    monkeypatch.setenv('GITHUB_SHA','a'*40)
    monkeypatch.setenv('EXPECTED_PLATFORM','linux/amd64')
    monkeypatch.setattr(m.smoke,'verify_checkout',lambda _:None)
    monkeypatch.setattr(m.smoke,'EphemeralDaemon',lambda:pytest.fail('verification started daemon'))
    assert m.main(['--verify-receipt',str(path)]) == 1
    assert capsys.readouterr().out == ''
