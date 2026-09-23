import json
import time
from dataclasses import replace

import pytest

from larenor_server.plugins.jellyfin_endpoint import (
    OpenJellyfinEndpoint,
    prove_jellyfin_endpoint,
)
from larenor_server.plugins.jellyfin_media_rows_executor import (
    JellyfinMediaRowsExecutionError,
    JellyfinMediaRowsExecutor,
)
from larenor_server.plugins.jellyfin_media_rows_runtime import (
    JellyfinMediaRowsProtocol,
)
from larenor_server.plugins.media_rows_models import (
    PrivateJellyfinMediaRowsAuthority,
)
from test_jellyfin_bootstrap_executor import prepared  # noqa: F401
from test_jellyfin_startup import Connection, response


INSTALLATION = "7" * 32
USER = "8" * 32
TOKEN = "c" * 32


def json_response(value):
    return response(
        200,
        json.dumps(value, separators=(",", ":")).encode(),
        content_type=b"application/json",
        extra=b"Connection: close\r\n",
    )


def recent():
    return [{
        "Id": "1" * 32,
        "Name": "Arrival",
        "Type": "Movie",
        "DateCreated": "2026-09-23T20:00:00Z",
        "RunTimeTicks": 3600 * 10_000_000,
        "UserData": {"PlaybackPositionTicks": 0},
    }]


def resume():
    return {"Items": [], "TotalRecordCount": 0, "StartIndex": 0}


def authority(stack):
    return PrivateJellyfinMediaRowsAuthority(
        requestId="d" * 32,
        installationId=INSTALLATION,
        installationRevision=4,
        bootstrapRevision=3,
        bindingRevision=1,
        plan=stack,
        apiKey=TOKEN,
        userId=USER,
    )


def executor(binding, operations):
    return JellyfinMediaRowsExecutor(
        operations,
        lambda _plan: binding,
        JellyfinMediaRowsProtocol(revision_seed=100),
    )


def opened(monkeypatch, stack, binding, engine, connections):
    proof = prove_jellyfin_endpoint(
        engine.container, binding, stack, engine.container["Id"]
    )
    pending = list(connections)
    monkeypatch.setattr(
        "larenor_server.plugins.jellyfin_media_rows_executor.open_jellyfin_endpoint",
        lambda *_args, **_kwargs: OpenJellyfinEndpoint(pending.pop(0), proof),
    )
    return proof


def test_read_opens_two_proved_streams_and_revalidates_endpoint(
    prepared, monkeypatch
):
    stack, binding, engine, operations = prepared
    connections = (
        Connection([json_response(recent())]),
        Connection([json_response(resume())]),
    )
    opened(monkeypatch, stack, binding, engine, connections)
    gates = []

    result = executor(binding, operations).read(
        authority(stack),
        deadline=time.monotonic() + 1,
        gate=lambda: gates.append("gate") or True,
    )

    assert result.revision == 100
    assert result.recent[0].title == "Arrival"
    assert len(gates) == 2
    assert all(connection.closed for connection in connections)
    assert USER not in repr(authority(stack)) + repr(result)
    assert TOKEN not in repr(authority(stack)) + repr(result)


def test_gate_loss_opens_no_endpoint(prepared, monkeypatch):
    stack, binding, _engine, operations = prepared
    monkeypatch.setattr(
        "larenor_server.plugins.jellyfin_media_rows_executor.open_jellyfin_endpoint",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            AssertionError("denied authority opened endpoint")
        ),
    )
    with pytest.raises(
        JellyfinMediaRowsExecutionError,
        match="^jellyfin_media_rows_authority_changed$",
    ):
        executor(binding, operations).read(
            authority(stack), deadline=time.monotonic() + 1, gate=lambda: False
        )


def test_second_stream_proof_drift_closes_both(prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    proof = prove_jellyfin_endpoint(
        engine.container, binding, stack, engine.container["Id"]
    )
    first = Connection([json_response(recent())])
    second = Connection([json_response(resume())])
    pending = [
        (first, proof),
        (second, replace(proof, address="172.28.0.99")),
    ]
    selected = executor(binding, operations)
    monkeypatch.setattr(selected, "_open", lambda *_args: pending.pop(0))

    with pytest.raises(
        JellyfinMediaRowsExecutionError,
        match="^jellyfin_media_rows_endpoint_changed$",
    ):
        selected.read(
            authority(stack), deadline=time.monotonic() + 1, gate=lambda: True
        )
    assert first.closed and second.closed


def test_malformed_readback_is_static_and_closes_both(prepared, monkeypatch):
    stack, binding, engine, operations = prepared
    connections = (
        Connection([json_response({"private": "payload"})]),
        Connection([json_response(resume())]),
    )
    opened(monkeypatch, stack, binding, engine, connections)
    with pytest.raises(
        JellyfinMediaRowsExecutionError,
        match="^jellyfin_media_rows_resources_unavailable$",
    ) as raised:
        executor(binding, operations).read(
            authority(stack), deadline=time.monotonic() + 1, gate=lambda: True
        )
    assert all(connection.closed for connection in connections)
    assert USER not in repr(raised.value) and TOKEN not in repr(raised.value)
