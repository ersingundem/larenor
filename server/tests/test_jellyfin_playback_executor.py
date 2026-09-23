from dataclasses import replace
import time

import pytest

from larenor_server.plugins.jellyfin_endpoint import (
    OpenJellyfinEndpoint,
    prove_jellyfin_endpoint,
)
from larenor_server.plugins.jellyfin_playback_executor import (
    JellyfinPlaybackExecutionError,
    JellyfinPlaybackExecutor,
)
from larenor_server.plugins.jellyfin_playback_runtime import (
    JellyfinPlaybackProtocol,
)
from larenor_server.plugins.media_playback_models import (
    PrivateJellyfinPlaybackAction,
    PrivateJellyfinPlaybackAuthority,
    PrivateMediaPlaybackAction,
    PrivateMediaPlaybackAuthority,
)
from test_jellyfin_bootstrap_executor import prepared  # noqa: F401
from test_jellyfin_playback_runtime import (
    Connection,
    ITEM,
    TOKEN,
    response,
    sessions,
)


JOB = '7' * 32


def authority(stack):
    return PrivateJellyfinPlaybackAuthority(
        authority=PrivateMediaPlaybackAuthority(
            installationId=JOB, installationRevision=4,
            snapshotRevision=8, jellyfinServiceRevision=6,
            itemId=ITEM, mediaKey='movie:tmdb:603'),
        plan=stack, apiKey=TOKEN,
    )


def action(stack):
    return PrivateJellyfinPlaybackAction(
        action=PrivateMediaPlaybackAction(
            requestId='d' * 32, intentId='e' * 32,
            installationId=JOB, installationRevision=4,
            snapshotRevision=8, jellyfinServiceRevision=6,
            itemId=ITEM, mediaKey='movie:tmdb:603',
            expectedPlaybackRevision=100, targetId='c' * 32,
            expectedTargetRevision=100, startSeconds=12),
        plan=stack, apiKey=TOKEN,
    )


def opened(monkeypatch, stack, binding, engine, responses):
    proof = prove_jellyfin_endpoint(
        engine.container, binding, stack, engine.container['Id'])
    pending = list(responses)
    calls = []

    def factory(*args, **kwargs):
        calls.append((args, kwargs))
        return OpenJellyfinEndpoint(pending.pop(0), proof)

    monkeypatch.setattr(
        'larenor_server.plugins.jellyfin_playback_executor.open_jellyfin_endpoint',
        factory)
    return calls


def executor(binding, operations):
    return JellyfinPlaybackExecutor(
        operations, lambda _plan: binding,
        JellyfinPlaybackProtocol(revision_seed=100))


def test_read_reconciles_exact_container_and_rechecks_endpoint(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    connection = Connection(response('200 OK', sessions()))
    calls = opened(monkeypatch, stack, binding, engine, [connection])
    gates = []

    result = executor(binding, operations).read(
        authority(stack), deadline=time.monotonic() + 1,
        gate=lambda: gates.append('gate') or True)

    assert result.playbackRevision == 100
    assert result.targets[0].targetId == 'c' * 32
    assert len(calls) == 1 and len(gates) == 2
    assert len([call for call in engine.calls if call[0] == 'inspect']) >= 2
    assert connection.closed
    assert TOKEN not in repr(authority(stack)) + repr(result)


def test_execute_opens_three_fresh_proved_streams_and_verifies_final_endpoint(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    connections = [
        Connection(response('200 OK', sessions())),
        Connection(response('204 No Content', content_type=False)),
        Connection(response('200 OK', sessions(item=ITEM, position=12))),
    ]
    calls = opened(monkeypatch, stack, binding, engine, connections)

    result = executor(binding, operations).execute(
        action(stack), deadline=time.monotonic() + 1, gate=lambda: True)

    assert result.state == 'succeeded' and result.playbackRevision == 101
    assert len(calls) == 3
    assert all(connection.closed for connection in connections)
    assert len([call for call in engine.calls if call[0] == 'inspect']) >= 4


def test_opened_connection_closes_when_returned_proof_mismatches_fresh_proof(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    connection = Connection(response('200 OK', sessions()))
    proof = prove_jellyfin_endpoint(
        engine.container, binding, stack, engine.container['Id'])
    monkeypatch.setattr(
        'larenor_server.plugins.jellyfin_playback_executor.open_jellyfin_endpoint',
        lambda *_args, **_kwargs: OpenJellyfinEndpoint(
            connection, replace(proof, address='172.28.0.99')))

    with pytest.raises(JellyfinPlaybackExecutionError):
        executor(binding, operations).read(
            authority(stack), deadline=time.monotonic() + 1,
            gate=lambda: True)

    assert connection.closed


def test_execute_revalidates_retained_authority_immediately_before_post(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    connections = [
        Connection(response('200 OK', sessions())),
        Connection(response('204 No Content', content_type=False)),
        Connection(response('200 OK', sessions(item=ITEM, position=12))),
    ]
    opened(monkeypatch, stack, binding, engine, connections)
    gates = iter((True, False))

    with pytest.raises(JellyfinPlaybackExecutionError,
                       match='^jellyfin_playback_authority_changed$') as raised:
        executor(binding, operations).execute(
            action(stack), deadline=time.monotonic() + 1,
            gate=lambda: next(gates))

    assert raised.value.uncertain_effect is False
    assert connections[1].sent == b''
    assert all(connection.closed for connection in connections)


def test_gate_loss_or_missing_journal_opens_no_playback_stream(
        prepared, monkeypatch):
    stack, binding, _engine, operations = prepared
    monkeypatch.setattr(
        'larenor_server.plugins.jellyfin_playback_executor.open_jellyfin_endpoint',
        lambda *_a, **_k: (_ for _ in ()).throw(
            AssertionError('denied authority must open no endpoint')))

    with pytest.raises(JellyfinPlaybackExecutionError,
                       match='^jellyfin_playback_authority_changed$'):
        executor(binding, operations).read(
            authority(stack), deadline=time.monotonic() + 1,
            gate=lambda: False)


def test_post_dispatch_protocol_failure_is_always_uncertain(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    connections = [
        Connection(response('200 OK', sessions())),
        Connection(response('204 No Content', content_type=False) + b'x'),
        Connection(response('200 OK', sessions(item=ITEM, position=12))),
    ]
    opened(monkeypatch, stack, binding, engine, connections)

    with pytest.raises(JellyfinPlaybackExecutionError) as raised:
        executor(binding, operations).execute(
            action(stack), deadline=time.monotonic() + 1, gate=lambda: True)

    assert raised.value.uncertain_effect is True
    assert TOKEN not in str(raised.value) + repr(raised.value)


def test_post_dispatch_final_endpoint_drift_is_always_uncertain(
        prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    connections = [
        Connection(response('200 OK', sessions())),
        Connection(response('204 No Content', content_type=False)),
        Connection(response('200 OK', sessions(item=ITEM, position=12))),
    ]
    opened(monkeypatch, stack, binding, engine, connections)
    selected = executor(binding, operations)
    monkeypatch.setattr(
        selected, '_final',
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            JellyfinPlaybackExecutionError(
                'jellyfin_playback_endpoint_changed')))

    with pytest.raises(JellyfinPlaybackExecutionError) as raised:
        selected.execute(
            action(stack), deadline=time.monotonic() + 1, gate=lambda: True)

    assert raised.value.uncertain_effect is True
