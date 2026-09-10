import socket
import time

import pytest
from larenor_server.plugins.arr_authenticated_readback import ArrAuthenticatedReadback
from larenor_server.plugins.arr_bootstrap_executor import (
    ArrBootstrapExecutionError,
    ArrBootstrapExecutor,
)
from larenor_server.plugins.arr_config_models import PrivateArrConfiguration
from larenor_server.plugins.arr_endpoint import OpenArrEndpoint, prove_arr_endpoint
from larenor_server.plugins.arr_managed_root_folders import ArrManagedRootFolders
from larenor_server.plugins.managed_container import (
    JournaledManagedContainerOperations,
    ManagedContainerError,
    ManagedWorkerJournal,
)
from test_arr_authenticated_readback import result
from test_arr_endpoint import build
from test_arr_managed_root_folders import json_response as root_response
from test_jellyfin_startup import Connection
from test_managed_container_binding import Engine, command

JOB = '7' * 32
KEY = '01234567' * 4


@pytest.fixture
def prepared(tmp_path):
    with ManagedWorkerJournal(tmp_path / 'managed', initialize=True) as journal:
        stack, binding, unused = build('sonarr', journal.identity)
        engine = Engine(binding)
        operations = JournaledManagedContainerOperations(journal, engine)
        operations.apply(command(binding), binding)
        operations.apply(command(binding, 'start_container', '8' * 32), binding)
        next(iter(engine.container['NetworkSettings']['Networks'].values())).update(
            IPAddress='172.28.0.2', IPPrefixLen=16, Gateway='172.28.0.1'
        )
        yield stack, binding, engine, operations


def executor(binding, operations):
    return ArrBootstrapExecutor(
        operations,
        lambda _s, service: binding if service == 'sonarr' else None,
        ArrManagedRootFolders(),
        ArrAuthenticatedReadback(),
    )


def test_reconciles_started_container_and_reads_back(prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    readback = Connection([result('sonarr')])
    root = Connection([root_response([{'id': 1, 'path': '/data/shows'}])])
    proof = prove_arr_endpoint(
        engine.container, binding, stack, engine.container['Id'], 'sonarr'
    )
    monkeypatch.setattr(
        'larenor_server.plugins.arr_bootstrap_executor.open_arr_endpoint',
        lambda *_a, **_k: OpenArrEndpoint(next(connections), proof),
    )
    connections = iter([readback, root])
    gates = []
    value = executor(binding, operations).execute(
        JOB,
        stack,
        PrivateArrConfiguration(serviceId='sonarr', apiKey=KEY),
        deadline=time.monotonic() + 10,
        gate=lambda: gates.append(1) or True,
    )
    assert (
        value.state == 'verified'
        and value.service_id == 'sonarr'
        and len(readback.requests) == 1 and readback.closed
        and len(root.requests) == 1 and root.closed
        and value.root_folders.path == '/data/shows'
        and len(gates) >= 7
        and KEY not in repr(value)
    )


def test_authority_loss_before_private_readback_closes_stream(prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    c = Connection([])
    proof = prove_arr_endpoint(
        engine.container, binding, stack, engine.container['Id'], 'sonarr'
    )
    monkeypatch.setattr(
        'larenor_server.plugins.arr_bootstrap_executor.open_arr_endpoint',
        lambda *_a, **_k: OpenArrEndpoint(c, proof),
    )
    gates = iter([True, True, False])
    with pytest.raises(
        ArrBootstrapExecutionError, match='^arr_bootstrap_authority_changed$'
    ):
        executor(binding, operations).execute(
            JOB,
            stack,
            PrivateArrConfiguration(serviceId='sonarr', apiKey=KEY),
            deadline=time.monotonic() + 10,
            gate=lambda: next(gates),
        )
    assert c.closed and c.requests == []


def test_root_folder_conflict_is_projected_without_secret(prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    readback = Connection([result('sonarr')])
    root = Connection([
        root_response([{'id': 1, 'path': '/data/private-other'}])])
    proof = prove_arr_endpoint(
        engine.container, binding, stack, engine.container['Id'], 'sonarr'
    )
    connections = iter([readback, root])
    monkeypatch.setattr(
        'larenor_server.plugins.arr_bootstrap_executor.open_arr_endpoint',
        lambda *_a, **_k: OpenArrEndpoint(next(connections), proof),
    )

    with pytest.raises(
        ArrBootstrapExecutionError, match='^arr_bootstrap_wiring_failed$'
    ) as raised:
        executor(binding, operations).execute(
            JOB, stack,
            PrivateArrConfiguration(serviceId='sonarr', apiKey=KEY),
            deadline=time.monotonic() + 10, gate=lambda: True,
        )

    assert raised.value.cause_code == 'arr_root_folder_conflict'
    assert not raised.value.uncertain_effect
    assert raised.value.boundary == 'after_wiring_connect'
    assert readback.closed and root.closed
    assert KEY not in str(raised.value) + repr(raised.value)


def test_deadline_loss_before_readback_closes_open_stream(prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    c = Connection([])
    proof = prove_arr_endpoint(
        engine.container, binding, stack, engine.container['Id'], 'sonarr'
    )
    monkeypatch.setattr(
        'larenor_server.plugins.arr_bootstrap_executor.open_arr_endpoint',
        lambda *_a, **_k: OpenArrEndpoint(c, proof),
    )
    remaining = iter([10.0])

    def bounded(_deadline):
        try:
            return next(remaining)
        except StopIteration:
            raise ArrBootstrapExecutionError('arr_bootstrap_timeout') from None

    monkeypatch.setattr(
        'larenor_server.plugins.arr_bootstrap_executor._remaining', bounded
    )
    with pytest.raises(ArrBootstrapExecutionError, match='^arr_bootstrap_timeout$'):
        executor(binding, operations).execute(
            JOB,
            stack,
            PrivateArrConfiguration(serviceId='sonarr', apiKey=KEY),
            deadline=time.monotonic() + 10,
            gate=lambda: True,
        )
    assert c.closed and c.requests == []


def test_cross_service_binding_never_reaches_endpoint(prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    monkeypatch.setattr(
        socket, 'socket', lambda *_: (_ for _ in ()).throw(AssertionError())
    )
    with pytest.raises(
        ArrBootstrapExecutionError, match='^arr_bootstrap_resources_unavailable$'
    ):
        ArrBootstrapExecutor(
            operations, lambda *_: object(), ArrManagedRootFolders(),
            ArrAuthenticatedReadback()
        ).execute(
            JOB,
            stack,
            PrivateArrConfiguration(serviceId='radarr', apiKey=KEY),
            deadline=time.monotonic() + 10,
            gate=lambda: True,
        )


def test_resource_proof_failure_preserves_only_static_cause(prepared):
    stack, _binding, _engine, operations = prepared

    def failed_binding(*_args):
        raise ManagedContainerError(
            'resources_unavailable',
            cause_code='resource_proof_network_observation_failed')

    selected = ArrBootstrapExecutor(
        operations,
        failed_binding,
        ArrManagedRootFolders(),
        ArrAuthenticatedReadback(),
    )
    with pytest.raises(
        ArrBootstrapExecutionError,
        match='^arr_bootstrap_resources_unavailable$',
    ) as raised:
        selected.execute(
            JOB,
            stack,
            PrivateArrConfiguration(serviceId='sonarr', apiKey=KEY),
            deadline=time.monotonic() + 10,
            gate=lambda: True,
        )

    assert raised.value.cause_code == (
        'arr_bootstrap_proof_network_observation_failed')
