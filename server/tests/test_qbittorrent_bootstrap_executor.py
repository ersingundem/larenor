"""Private qBittorrent category and authenticated-readback orchestration."""

import socket
import time

import pytest

from larenor_server.plugins.managed_container import (
    JournaledManagedContainerOperations, ManagedContainerError,
    ManagedWorkerJournal,
)
from larenor_server.plugins.qbittorrent_authenticated_readback import (
    QbittorrentAuthenticatedReadback,
)
from larenor_server.plugins.qbittorrent_bootstrap_executor import (
    QbittorrentBootstrapExecutionError, QbittorrentBootstrapExecutionResult,
    QbittorrentBootstrapExecutor,
)
from larenor_server.plugins.qbittorrent_config_models import (
    PrivateQbittorrentConfiguration,
)
from larenor_server.plugins.qbittorrent_endpoint import (
    OpenQbittorrentEndpoint, QbittorrentEndpointError,
    prove_qbittorrent_endpoint,
)
from larenor_server.plugins.qbittorrent_managed_categories import (
    QbittorrentManagedCategories,
)
from test_jellyfin_startup import Connection, response
from test_managed_container_binding import (
    Engine, build_qbittorrent, command,
)
from test_qbittorrent_authenticated_readback import (
    json_response as readback_json, private_preferences, version_response,
)
from test_qbittorrent_managed_categories import json_response as category_json
from test_qbittorrent_owned_config import PRIVATE_BEARER, PRIVATE_PASSWORD, SALT
from test_qbittorrent_readback import categories


JOB = '7' * 32


@pytest.fixture
def prepared(tmp_path):
    with ManagedWorkerJournal(tmp_path / 'managed', initialize=True) as journal:
        _builder, stack, binding = build_qbittorrent(journal.identity)
        engine = Engine(binding)
        operations = JournaledManagedContainerOperations(journal, engine)
        assert operations.apply(command(binding), binding).code == 'container_created'
        assert operations.apply(
            command(binding, 'start_container', '8' * 32), binding,
        ).code == 'container_started'
        attached = next(iter(engine.container['NetworkSettings']['Networks'].values()))
        attached.update({'IPAddress': '172.28.0.2', 'IPPrefixLen': 16,
                         'Gateway': '172.28.0.1'})
        yield stack, binding, engine, operations


def private():
    return PrivateQbittorrentConfiguration(
        credential=PRIVATE_PASSWORD, apiKey=PRIVATE_BEARER,
        saltHex=SALT.hex())


def executor(binding, operations):
    return QbittorrentBootstrapExecutor(
        operations, lambda _stack, service: binding
        if service == 'qbittorrent' else None,
        QbittorrentManagedCategories(), QbittorrentAuthenticatedReadback())


def connections(monkeypatch, stack, binding, engine, *, category=None,
                readback=None):
    category = category or Connection([category_json(categories())])
    readback = readback or Connection([
        version_response(), readback_json(private_preferences()),
        readback_json(categories(), connection=b'close'),
    ])
    proof = prove_qbittorrent_endpoint(
        engine.container, binding, stack, engine.container['Id'])
    pending = [category, readback]
    calls = []

    def opened(*args, **kwargs):
        calls.append((args, kwargs))
        return OpenQbittorrentEndpoint(pending.pop(0), proof)

    monkeypatch.setattr(
        'larenor_server.plugins.qbittorrent_bootstrap_executor.open_qbittorrent_endpoint',
        opened)
    monkeypatch.setattr(socket, 'socket', lambda *_a, **_k: (_ for _ in ()).throw(
        AssertionError('executor must use only the closed endpoint opener')))
    return category, readback, calls


def test_reconciles_started_container_wires_categories_and_reads_back(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    category, readback, opens = connections(
        monkeypatch, stack, binding, engine)
    gates = []

    result = executor(binding, operations).execute(
        JOB, stack, private(), deadline=time.monotonic() + 10,
        gate=lambda: gates.append('gate') or True)

    assert result.state == 'verified'
    assert result.categories.categories == (
        ('movies', '/data/downloads/movies'),
        ('tv', '/data/downloads/tv'))
    assert result.readback.version == 'v5.2.3'
    assert result.readback.settings.categories == result.categories.categories
    assert len(category.requests) == 1 and category.closed
    assert len(readback.requests) == 3 and readback.closed
    assert len(opens) == 2 and len(gates) == 6
    assert len([item for item in engine.calls if item[0] == 'inspect']) >= 5
    assert PRIVATE_PASSWORD not in repr(result)
    assert PRIVATE_BEARER not in repr(result)


def test_transient_refusal_retries_only_the_same_reproved_endpoint(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    category, readback, _opens = connections(
        monkeypatch, stack, binding, engine)
    proof = prove_qbittorrent_endpoint(
        engine.container, binding, stack, engine.container['Id'])
    outcomes = [QbittorrentEndpointError('qbittorrent_endpoint_unavailable'),
                OpenQbittorrentEndpoint(category, proof),
                OpenQbittorrentEndpoint(readback, proof)]
    attempts = []
    sleeps = []

    def opened(*args, **kwargs):
        attempts.append((args, kwargs))
        value = outcomes.pop(0)
        if isinstance(value, BaseException):
            raise value
        return value

    monkeypatch.setattr(
        'larenor_server.plugins.qbittorrent_bootstrap_executor.open_qbittorrent_endpoint',
        opened)
    monkeypatch.setattr(
        'larenor_server.plugins.qbittorrent_bootstrap_executor.time.sleep',
        lambda value: sleeps.append(value))
    result = executor(binding, operations).execute(
        JOB, stack, private(), deadline=time.monotonic() + 10,
        gate=lambda: True)
    assert result.state == 'verified'
    assert len(attempts) == 3 and sleeps == [0.1]
    assert attempts[0][0] == attempts[1][0]


def test_endpoint_drift_during_readiness_wait_stops_retry(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    attempts = []
    monkeypatch.setattr(
        'larenor_server.plugins.qbittorrent_bootstrap_executor.open_qbittorrent_endpoint',
        lambda *args, **kwargs: attempts.append((args, kwargs)) or (_ for _ in ()).throw(
            QbittorrentEndpointError('qbittorrent_endpoint_unavailable')))
    monkeypatch.setattr(
        'larenor_server.plugins.qbittorrent_bootstrap_executor.time.sleep',
        lambda _value: next(iter(engine.container['NetworkSettings']['Networks'].values())).update(
            IPAddress='172.28.0.9'))
    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^qbittorrent_bootstrap_endpoint_changed$') as raised:
        executor(binding, operations).execute(
            JOB, stack, private(), deadline=time.monotonic() + 10,
            gate=lambda: True)
    assert len(attempts) == 1
    assert raised.value.boundary == 'before_connect'
    assert not raised.value.uncertain_effect


def test_unexpected_failure_preserves_only_static_boundary_diagnostic(
        prepared, monkeypatch):
    stack, binding, _engine, operations = prepared
    monkeypatch.setattr(
        'larenor_server.plugins.qbittorrent_bootstrap_executor.open_qbittorrent_endpoint',
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            KeyError('private native failure')))

    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^qbittorrent_bootstrap_resources_unavailable$') as raised:
        executor(binding, operations).execute(
            JOB, stack, private(), deadline=time.monotonic() + 10,
            gate=lambda: True)

    assert raised.value.boundary == 'before_connect'
    assert raised.value.cause_code == 'qbittorrent_bootstrap_unexpected'
    assert not raised.value.uncertain_effect
    assert 'private' not in str(raised.value) + repr(raised.value)


@pytest.mark.parametrize('private_code,public_cause', [
    ('invalid_installation_plan',
     'qbittorrent_bootstrap_binding_invalid_installation_plan'),
    ('resources_unavailable',
     'qbittorrent_bootstrap_binding_resources_unavailable'),
    ('resources_untrusted',
     'qbittorrent_bootstrap_binding_resources_untrusted'),
])
def test_binding_failure_preserves_only_static_cause(
        prepared, private_code, public_cause):
    stack, _binding, _engine, operations = prepared
    failed = QbittorrentBootstrapExecutor(
        operations,
        lambda *_args: (_ for _ in ()).throw(
            ManagedContainerError(private_code)),
        QbittorrentManagedCategories(), QbittorrentAuthenticatedReadback())

    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^qbittorrent_bootstrap_resources_unavailable$') as raised:
        failed.execute(
            JOB, stack, private(), deadline=time.monotonic() + 10,
            gate=lambda: True)

    assert raised.value.boundary == 'before_connect'
    assert raised.value.cause_code == public_cause
    assert not raised.value.uncertain_effect


def test_binding_proof_failure_preserves_only_static_proof_stage(
        prepared):
    stack, _binding, _engine, operations = prepared
    failed = QbittorrentBootstrapExecutor(
        operations,
        lambda *_args: (_ for _ in ()).throw(ManagedContainerError(
            'resources_unavailable',
            cause_code='resource_proof_volume_bootstrap_failed')),
        QbittorrentManagedCategories(), QbittorrentAuthenticatedReadback())

    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^qbittorrent_bootstrap_resources_unavailable$') as raised:
        failed.execute(
            JOB, stack, private(), deadline=time.monotonic() + 10,
            gate=lambda: True)

    assert raised.value.boundary == 'before_connect'
    assert raised.value.cause_code == (
        'qbittorrent_bootstrap_proof_volume_bootstrap_failed')
    assert not raised.value.uncertain_effect


def test_category_failure_preserves_static_cause_without_readback(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    category = Connection([category_json({}, status=500)])
    category, readback, opens = connections(
        monkeypatch, stack, binding, engine, category=category)

    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^qbittorrent_bootstrap_categories_failed$') as raised:
        executor(binding, operations).execute(
            JOB, stack, private(), deadline=time.monotonic() + 10,
            gate=lambda: True)

    assert raised.value.cause_code == 'qbittorrent_categories_protocol'
    assert not raised.value.uncertain_effect
    assert len(opens) == 1 and category.closed and readback.requests == []
    assert PRIVATE_BEARER not in str(raised.value) + repr(raised.value)


def test_readback_failure_after_categories_is_uncertain_and_secret_free(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    failed = Connection([version_response(status=401)])
    category, readback, opens = connections(
        monkeypatch, stack, binding, engine, readback=failed)

    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^qbittorrent_bootstrap_readback_failed$') as raised:
        executor(binding, operations).execute(
            JOB, stack, private(), deadline=time.monotonic() + 10,
            gate=lambda: True)

    assert raised.value.cause_code == 'qbittorrent_authentication_failed'
    assert raised.value.uncertain_effect
    assert len(opens) == 2 and category.closed and readback.closed
    assert PRIVATE_BEARER not in str(raised.value) + repr(raised.value)


@pytest.mark.parametrize('denied_at,opens,uncertain', [
    (1, 0, False), (2, 0, False), (3, 1, False),
    (4, 1, True), (5, 2, True), (6, 2, True),
])
def test_authority_loss_closes_stream_and_never_publishes_success(
        prepared, monkeypatch, denied_at, opens, uncertain):
    stack, binding, engine, operations = prepared
    category, readback, calls = connections(
        monkeypatch, stack, binding, engine)
    count = {'value': 0}

    def gate():
        count['value'] += 1
        return count['value'] != denied_at

    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^qbittorrent_bootstrap_authority_changed$') as raised:
        executor(binding, operations).execute(
            JOB, stack, private(), deadline=time.monotonic() + 10, gate=gate)

    assert len(calls) == opens
    assert raised.value.uncertain_effect is uncertain
    assert category.closed is (opens >= 1)
    assert readback.closed is (opens >= 2)


@pytest.mark.parametrize('when', ['after_categories_connect', 'after_categories',
                                  'after_readback_connect', 'after_readback'])
def test_endpoint_change_around_effect_never_publishes_success(
        prepared, monkeypatch, when):
    stack, binding, engine, operations = prepared
    connections(monkeypatch, stack, binding, engine)
    original = engine.inspect_container
    calls = {'value': 0}
    changed_at = {
        'after_categories_connect': 2,
        'after_categories': 3,
        'after_readback_connect': 4,
        'after_readback': 5,
    }[when]

    def inspect(name):
        value = original(name)
        calls['value'] += 1
        if calls['value'] == changed_at:
            next(iter(value['NetworkSettings']['Networks'].values()))[
                'IPAddress'] = '172.28.0.9'
        return value

    engine.inspect_container = inspect
    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^qbittorrent_bootstrap_endpoint_changed$') as raised:
        executor(binding, operations).execute(
            JOB, stack, private(), deadline=time.monotonic() + 10,
            gate=lambda: True)
    assert raised.value.boundary == when
    assert raised.value.uncertain_effect is (
        when != 'after_categories_connect')


@pytest.mark.parametrize('job,payload,deadline,gate', [
    ('bad', private(), 10.0, lambda: True),
    (JOB, 'private', 10.0, lambda: True),
    (JOB, private(), True, lambda: True),
    (JOB, private(), float('inf'), lambda: True),
    (JOB, private(), 10.0, 'gate'),
])
def test_invalid_input_never_touches_journal_or_network(
        prepared, monkeypatch, job, payload, deadline, gate):
    stack, binding, engine, operations = prepared
    calls = list(engine.calls)
    monkeypatch.setattr(socket, 'socket', lambda *_a, **_k: (_ for _ in ()).throw(
        AssertionError('invalid input must not open a socket')))
    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^invalid_qbittorrent_bootstrap_execution$'):
        executor(binding, operations).execute(
            job, stack, payload, deadline=deadline, gate=gate)
    assert engine.calls == calls


def test_invalid_executor_dependencies_fail_before_any_effect(prepared):
    _stack, binding, _engine, operations = prepared
    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^invalid_qbittorrent_bootstrap_execution$'):
        QbittorrentBootstrapExecutor(
            operations, lambda _stack, _service: binding,
            'categories', QbittorrentAuthenticatedReadback())


def test_error_drops_unknown_steps_and_private_cause_text():
    error = QbittorrentBootstrapExecutionError(
        'unknown-private-code', cause_code='private-cause',
        category_steps=('private-secret',), readback_steps=('private-secret',))
    assert error.code == 'qbittorrent_bootstrap_resources_unavailable'
    assert error.cause_code is None
    assert error.category_steps == () and error.readback_steps == ()
    assert 'private' not in str(error) + repr(error)


def test_result_rejects_nonexact_readback(prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    _category, _readback, _opens = connections(
        monkeypatch, stack, binding, engine)
    result = executor(binding, operations).execute(
        JOB, stack, private(), deadline=time.monotonic() + 10,
        gate=lambda: True)
    with pytest.raises(
            QbittorrentBootstrapExecutionError,
            match='^qbittorrent_bootstrap_readback_failed$'):
        QbittorrentBootstrapExecutionResult(
            'unverified', result.categories, result.readback)
