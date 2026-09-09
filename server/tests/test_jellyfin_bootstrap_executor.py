"""Worker-private orchestration around endpoint proof and startup effects."""

import socket
import time

import pytest

from larenor_server.plugins.jellyfin_bootstrap_executor import (
    JellyfinBootstrapExecutionError, JellyfinBootstrapExecutor,
)
from larenor_server.plugins.jellyfin_endpoint import OpenJellyfinEndpoint, prove_jellyfin_endpoint
from larenor_server.plugins.jellyfin_startup import JellyfinStartupConfigurator
from larenor_server.plugins.managed_container import (
    JournaledManagedContainerOperations, ManagedWorkerJournal,
)
from larenor_server.plugins.media_service_bootstrap_models import PrivateMediaServiceBootstrap
from test_jellyfin_startup import Connection, SECRET, happy_responses
from test_managed_container_binding import Engine, build, command


JOB = '7' * 32


@pytest.fixture
def prepared(tmp_path):
    with ManagedWorkerJournal(tmp_path / 'managed', initialize=True) as journal:
        _builder, stack, binding = build(container_journal_id=journal.identity)
        engine = Engine(binding)
        operations = JournaledManagedContainerOperations(journal, engine)
        assert operations.apply(command(binding), binding).code == 'container_created'
        assert operations.apply(command(binding, 'start_container', '8' * 32), binding).code == 'container_started'
        attached = next(iter(engine.container['NetworkSettings']['Networks'].values()))
        attached.update({'IPAddress': '172.28.0.2', 'IPPrefixLen': 16,
                         'Gateway': '172.28.0.1'})
        yield stack, binding, engine, operations


def executor(binding, operations):
    return JellyfinBootstrapExecutor(
        operations, lambda _stack: binding, JellyfinStartupConfigurator(),
    )


def private():
    return PrivateMediaServiceBootstrap(credential=SECRET)


def connected(monkeypatch, stack, binding, engine, connection=None):
    connection = connection or Connection(happy_responses())
    proof = prove_jellyfin_endpoint(engine.container, binding, stack, engine.container['Id'])
    calls = []
    def opened(*args, **kwargs):
        calls.append((args, kwargs))
        return OpenJellyfinEndpoint(connection, proof)
    monkeypatch.setattr(
        'larenor_server.plugins.jellyfin_bootstrap_executor.open_jellyfin_endpoint', opened)
    monkeypatch.setattr(socket, 'socket', lambda *_a, **_k: (_ for _ in ()).throw(
        AssertionError('executor must use only the closed endpoint opener')))
    return connection, calls


def test_reconciles_journal_and_rechecks_endpoint_before_and_after_startup(prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    connection, opens = connected(monkeypatch, stack, binding, engine)
    gates = []
    result = executor(binding, operations).execute(
        JOB, stack, private(), deadline=time.monotonic() + 10,
        gate=lambda: gates.append('gate') or True,
    )
    assert result.state == 'credentials_configured'
    assert result.completed_steps[-1] == 'wizard_completed'
    assert len(connection.requests) == 5 and connection.closed
    assert len(opens) == 1 and len(gates) == 3
    assert len([call for call in engine.calls if call[0] == 'inspect']) >= 5
    assert SECRET not in repr(result)


@pytest.mark.parametrize('when', ['initial_gate', 'before_startup', 'after_startup'])
def test_authority_loss_closes_stream_and_never_publishes_success(prepared, monkeypatch, when):
    stack, binding, engine, operations = prepared
    connection, opens = connected(monkeypatch, stack, binding, engine)
    count = {'value': 0}
    denied_at = {'initial_gate': 1, 'before_startup': 2, 'after_startup': 3}[when]
    def gate():
        count['value'] += 1
        return count['value'] != denied_at
    with pytest.raises(JellyfinBootstrapExecutionError, match='^bootstrap_authority_changed$') as raised:
        executor(binding, operations).execute(
            JOB, stack, private(), deadline=time.monotonic() + 10, gate=gate)
    assert connection.closed is (when != 'initial_gate')
    assert len(opens) == (0 if when == 'initial_gate' else 1)
    assert raised.value.uncertain_effect is (when == 'after_startup')
    assert len(connection.requests) == (5 if when == 'after_startup' else 0)


@pytest.mark.parametrize('when', ['after_connect', 'after_startup'])
def test_container_or_endpoint_change_is_detected_around_effect(prepared, monkeypatch, when):
    stack, binding, engine, operations = prepared
    connection, _ = connected(monkeypatch, stack, binding, engine)
    original = engine.inspect_container
    calls = {'value': 0}
    # Journal reconcile is inspect 1; executor pre-open is 2; after-connect is
    # 3 and after-startup is 4.
    changed_at = 3 if when == 'after_connect' else 4
    def inspect(name):
        value = original(name)
        calls['value'] += 1
        if calls['value'] == changed_at:
            next(iter(value['NetworkSettings']['Networks'].values()))['IPAddress'] = '172.28.0.9'
        return value
    engine.inspect_container = inspect
    with pytest.raises(JellyfinBootstrapExecutionError, match='^bootstrap_endpoint_changed$') as raised:
        executor(binding, operations).execute(
            JOB, stack, private(), deadline=time.monotonic() + 10, gate=lambda: True)
    assert connection.closed
    assert raised.value.uncertain_effect is (when == 'after_startup')
    assert len(connection.requests) == (5 if when == 'after_startup' else 0)


def test_startup_partial_result_is_preserved_without_retry(prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    replies = happy_responses()[:2]
    replies[1] = b'HTTP/1.1 500 Error\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}'
    connection, opens = connected(monkeypatch, stack, binding, engine, Connection(replies))
    with pytest.raises(JellyfinBootstrapExecutionError, match='^bootstrap_startup_failed$') as raised:
        executor(binding, operations).execute(
            JOB, stack, private(), deadline=time.monotonic() + 10, gate=lambda: True)
    assert raised.value.completed_steps == ('observed_unconfigured',)
    assert raised.value.uncertain_effect and len(connection.requests) == 2 and len(opens) == 1
    assert SECRET not in str(raised.value) + repr(raised.value)


@pytest.mark.parametrize('job,payload,deadline,gate', [
    ('bad', private(), 10.0, lambda: True),
    (JOB, 'private', 10.0, lambda: True),
    (JOB, private(), True, lambda: True),
    (JOB, private(), float('inf'), lambda: True),
    (JOB, private(), 10.0, 'gate'),
])
def test_invalid_worker_input_never_touches_journal_or_network(prepared, job, payload,
                                                               deadline, gate, monkeypatch):
    stack, binding, engine, operations = prepared
    calls = list(engine.calls)
    monkeypatch.setattr(socket, 'socket', lambda *_a, **_k: (_ for _ in ()).throw(
        AssertionError('invalid input must not open a socket')))
    with pytest.raises(JellyfinBootstrapExecutionError, match='^invalid_bootstrap_execution$'):
        executor(binding, operations).execute(job, stack, payload, deadline=deadline, gate=gate)
    assert engine.calls == calls
