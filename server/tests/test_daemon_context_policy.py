"""Explicit private trust anchor; policy validation never observes its target."""
import json
import os

import pytest

from larenor_server.plugins.preflight_runtime import load_policy


def write(tmp_path, version=3, executable='/usr/local/bin/operator-approved-engine'):
    value = {'version': version, 'roots': [{'id': 'appdata', 'path': '/not/observed', 'purpose': 'data'}],
             'docker': {'socketPath': '/run/docker.sock', 'ownerUid': 0}}
    if executable is not None:
        value['docker']['daemonExecutable'] = executable
    path = tmp_path/'policy.json'
    path.write_text(json.dumps(value))
    path.chmod(0o600)
    return path


def test_v3_accepts_explicit_executable_without_observing_or_exposing_it(tmp_path):
    policy = load_policy(write(tmp_path))
    assert policy.docker.daemon_executable == '/usr/local/bin/operator-approved-engine'
    assert 'operator-approved-engine' not in repr(policy.docker)


@pytest.mark.parametrize('version', [1, 2])
def test_legacy_policy_never_silently_gains_context_authority(tmp_path, version):
    if version == 1:
        path = tmp_path/'policy.json'
        path.write_text(json.dumps({'version': 1, 'roots': [{'id': 'appdata', 'path': '/not/observed', 'purpose': 'data'}]}))
        path.chmod(0o600)
        assert load_policy(path).docker is None
    else:
        assert load_policy(write(tmp_path, version=2, executable=None)).docker.daemon_executable is None
        with pytest.raises(ValueError):
            load_policy(write(tmp_path, version=2))


@pytest.mark.parametrize('value', [None, '', 'relative', '/usr/../engine', '/usr//engine', '/usr/engine\n', True, 12])
def test_v3_missing_or_invalid_anchor_is_rejected_without_echo(tmp_path, value):
    with pytest.raises(ValueError) as error:
        load_policy(write(tmp_path, executable=value))
    assert 'engine' not in str(error.value)
