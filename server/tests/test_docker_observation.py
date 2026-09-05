"""Context and local storage share one synthetic, read-only Docker connection."""

from dataclasses import FrozenInstanceError
import os
import time
from types import SimpleNamespace

import pytest

from larenor_server.plugins import docker_probe
from larenor_server.plugins.docker_probe import DockerEndpoint, DockerProbe
from test_docker_probe import synthetic_engine, response


@pytest.mark.parametrize('path', ['', '/', 'relative', '/a//b', '/a/../b', '/a/./b',
                                '/a/', '/a\\b', '/a\x00b', '/a\nb', 7, True,
                                '/a' + 'b' * 4096])
def test_executable_policy_is_canonical_bounded_and_optional(path):
    with pytest.raises(ValueError, match='^invalid_docker_endpoint$'):
        DockerEndpoint('/run/docker.sock', daemon_executable=path)


def test_executable_policy_and_local_value_are_private_and_immutable():
    endpoint = DockerEndpoint('/run/private.sock', daemon_executable='/usr/bin/private-engine')
    assert 'private' not in repr(endpoint)
    assert DockerEndpoint('/run/socket').daemon_executable is None
    observation = docker_probe.DockerObservation('unknown', None, '/private/storage')
    assert 'private' not in repr(observation)
    with pytest.raises(FrozenInstanceError):
        observation.status = 'passed'


def observed_probe(engine, **kwargs):
    return DockerProbe(DockerEndpoint(str(engine.path), os.getuid(), '/usr/bin/operator-engine'),
                       peer_uid=lambda connection: os.getuid(), **kwargs)


def context_stub(monkeypatch, trace, *, valid=True):
    context = SimpleNamespace(same_mount_namespace=True, same_network_namespace=False,
                              same_process_root=True)
    def capture(connection, expected_uid, daemon_executable, deadline):
        assert connection.fileno() >= 0
        assert expected_uid == os.getuid()
        assert daemon_executable == '/usr/bin/operator-engine'
        trace.append('capture')
        def revalidate(later_deadline):
            assert later_deadline == deadline
            trace.append('revalidate')
            return valid
        return SimpleNamespace(context=context, revalidate=revalidate,
                               close=lambda: trace.append('close'))
    monkeypatch.setattr(docker_probe, 'capture_daemon_context', capture)
    return context


def test_context_brackets_callback_on_the_same_verified_connection(monkeypatch):
    trace = []
    expected = context_stub(monkeypatch, trace)
    def reply(connection):
        trace.append('version')
        connection.sendall(response())
    with synthetic_engine(reply) as engine:
        def during():
            trace.append('storage')
            return ('independent', 42)
        result = observed_probe(engine).observe('linux/amd64', during=during)
    assert trace == ['capture', 'version', 'storage', 'revalidate', 'close']
    assert result.status == 'passed' and result.context is expected
    assert result.value == ('independent', 42)
    assert len(engine.requests) == 1 and engine.requests[0].startswith(b'GET /version ')


@pytest.mark.parametrize('mode', ['absent', 'wrong_uid', 'capture_unavailable', 'changed',
                                 'http_unavailable', 'expired'])
def test_local_callback_runs_exactly_once_and_survives_unknown_context(monkeypatch, mode):
    trace = []
    context_stub(monkeypatch, trace, valid=mode != 'changed')
    if mode == 'capture_unavailable':
        monkeypatch.setattr(docker_probe, 'capture_daemon_context', lambda *args: None)
    with synthetic_engine(response(status=503) if mode == 'http_unavailable' else None) as engine:
        instance = observed_probe(engine)
        if mode == 'absent':
            instance = DockerProbe(DockerEndpoint('/nonexistent-synthetic.sock'))
        elif mode == 'wrong_uid':
            instance._peer_uid = lambda _: -1
        result = instance.observe('linux/amd64', during=lambda: trace.append('storage') or 71,
                                  deadline=time.monotonic() - 1 if mode == 'expired' else None)
    assert trace.count('storage') == 1 and result.value == 71
    assert result.context is None
    assert result.status == ('passed' if mode in ('capture_unavailable', 'changed') else 'unknown')


def test_v1_policy_does_not_attempt_process_observation(monkeypatch):
    monkeypatch.setattr(docker_probe, 'capture_daemon_context',
                        lambda *args: pytest.fail('no executable trust anchor'))
    with synthetic_engine() as engine:
        instance = DockerProbe(DockerEndpoint(str(engine.path), os.getuid()), peer_uid=lambda _: os.getuid())
        result = instance.observe('linux/amd64', during=lambda: 11)
    assert (result.status, result.context, result.value) == ('passed', None, 11)


def test_legacy_inspect_does_not_require_context_support(monkeypatch):
    monkeypatch.setattr(docker_probe, 'capture_daemon_context',
                        lambda *args: pytest.fail('legacy status should not need pidfds'))
    with synthetic_engine() as engine:
        assert observed_probe(engine).inspect('linux/amd64') == 'passed'


def test_callback_overrun_never_returns_passed_or_discards_local_value(monkeypatch):
    trace = []
    context_stub(monkeypatch, trace)
    with synthetic_engine() as engine:
        def during():
            time.sleep(0.06)
            return 'local-only'
        result = observed_probe(engine, timeout=0.03).observe('linux/amd64', during=during)
    assert (result.status, result.context, result.value) == ('unknown', None, 'local-only')
    assert trace[-1] == 'close'


def test_callback_error_is_not_retried_and_all_resources_close(monkeypatch):
    trace = []
    context_stub(monkeypatch, trace)
    with synthetic_engine() as engine:
        def during():
            trace.append('storage')
            raise RuntimeError('trusted-callback-error')
        with pytest.raises(RuntimeError, match='trusted-callback-error'):
            observed_probe(engine).observe('linux/amd64', during=during)
    assert trace.count('storage') == 1 and trace[-1] == 'close'


def test_endpoint_replacement_during_callback_invalidates_both_observations(monkeypatch):
    trace = []
    context_stub(monkeypatch, trace)
    with synthetic_engine() as engine:
        def during():
            engine.path.chmod(0o666)
            return 23
        result = observed_probe(engine).observe('linux/amd64', during=during)
    assert (result.status, result.context, result.value) == ('unknown', None, 23)


@pytest.mark.parametrize('deadline', [True, '2', float('nan'), float('inf')])
def test_invalid_shared_deadline_is_static(deadline):
    with pytest.raises(ValueError, match='^invalid_observation$'):
        DockerProbe(DockerEndpoint('/nonexistent.sock')).observe('linux/amd64', deadline=deadline)
