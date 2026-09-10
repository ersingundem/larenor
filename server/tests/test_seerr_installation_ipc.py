"""Closed Seerr bootstrap roundtrip over the retained worker socket."""

from contextlib import contextmanager
import os
from pathlib import Path
import tempfile
import time

import pytest

from larenor_server.plugins.installation_ipc import (
    InstallationWorkerClient,
    InstallationWorkerServer,
)
from larenor_server.plugins.seerr_bootstrap_models import PrivateSeerrBootstrap
from larenor_server.plugins.seerr_bootstrap_executor import (
    SeerrBootstrapExecutionError,
    SeerrBootstrapExecutionResult,
)
from test_media_host_preflight import stack
from test_seerr_initial_admin import API_KEY, PASSWORD


def private():
    return PrivateSeerrBootstrap(
        credential=PASSWORD,
        sourceBootstrapId="b" * 32,
        sourceBootstrapRevision=3,
    )


def receipt():
    return SeerrBootstrapExecutionResult(
        "verified",
        API_KEY,
        (
            "uninitialized_verified",
            "admin_created",
            "api_key_verified",
            "session_destroyed",
        ),
    )


class Backend:
    def __init__(self, result=None):
        self.result = result
        self.calls = []

    def bootstrap_seerr(self, job, plan, payload, *, deadline):
        self.calls.append((job, plan, payload, deadline))
        if isinstance(self.result, BaseException):
            raise self.result
        return receipt() if self.result is None else self.result


@contextmanager
def running(backend=None):
    with tempfile.TemporaryDirectory(
        prefix="lsi-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    ) as root:
        path = Path(root) / "worker.sock"
        selected = backend or Backend()
        server = InstallationWorkerServer(
            path,
            selected,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
            timeout=0.5,
        )
        server.start()
        try:
            yield (
                selected,
                InstallationWorkerClient(
                    path,
                    owner_uid=os.getuid(),
                    peer_uid=lambda _connection: os.getuid(),
                    timeout=0.5,
                ),
            )
        finally:
            server.close()


def test_private_seerr_bootstrap_roundtrip_and_worker_capability():
    selected = stack()
    payload = private()
    with running() as (backend, client):
        assert client.status()["services"] == [
            "jellyfin",
            "qbittorrent",
            "sonarr",
            "radarr",
            "seerr",
        ]
        result = client.bootstrap_seerr(
            "a" * 32,
            selected,
            payload,
            deadline=time.monotonic() + 0.4,
            gate=lambda: True,
        )

    assert result == receipt()
    assert backend.calls[0][:3] == ("a" * 32, selected, payload)
    assert backend.calls[0][3] > time.monotonic() - 1
    assert PASSWORD not in repr(result) and API_KEY not in repr(result)


def test_worker_failure_preserves_only_static_seerr_state():
    failure = SeerrBootstrapExecutionError(
        "seerr_bootstrap_initial_admin_failed",
        completed_steps=("uninitialized_verified",),
        uncertain_effect=True,
        cause_code="seerr_initial_admin_protocol",
    )
    with running(Backend(failure)) as (backend, client):
        with pytest.raises(
            SeerrBootstrapExecutionError,
            match="^seerr_bootstrap_initial_admin_failed$",
        ) as raised:
            client.bootstrap_seerr(
                "a" * 32,
                stack(),
                private(),
                deadline=time.monotonic() + 0.4,
                gate=lambda: True,
            )
    assert raised.value.uncertain_effect
    assert raised.value.completed_steps == ("uninitialized_verified",)
    assert raised.value.cause_code == "seerr_initial_admin_protocol"
    assert len(backend.calls) == 1 and PASSWORD not in repr(raised.value)


def test_client_authority_loss_before_dispatch_never_reaches_worker():
    with running() as (backend, client):
        with pytest.raises(
            SeerrBootstrapExecutionError,
            match="^seerr_bootstrap_authority_changed$",
        ):
            client.bootstrap_seerr(
                "a" * 32,
                stack(),
                private(),
                deadline=time.monotonic() + 0.4,
                gate=lambda: False,
            )
    assert backend.calls == []


def test_client_authority_loss_after_effect_is_uncertain():
    gates = iter((True, False))
    with running() as (backend, client):
        with pytest.raises(
            SeerrBootstrapExecutionError,
            match="^seerr_bootstrap_authority_changed$",
        ) as raised:
            client.bootstrap_seerr(
                "a" * 32,
                stack(),
                private(),
                deadline=time.monotonic() + 0.4,
                gate=lambda: next(gates),
            )
    assert raised.value.uncertain_effect and len(backend.calls) == 1


@pytest.mark.parametrize("result", [{"apiKey": API_KEY}, object()])
def test_invalid_worker_result_fails_closed(result):
    with running(Backend(result)) as (_backend, client):
        with pytest.raises(
            SeerrBootstrapExecutionError,
            match="^seerr_bootstrap_resources_unavailable$",
        ) as raised:
            client.bootstrap_seerr(
                "a" * 32,
                stack(),
                private(),
                deadline=time.monotonic() + 0.4,
                gate=lambda: True,
            )
    assert raised.value.uncertain_effect
    assert API_KEY not in repr(raised.value)


def test_unrecognized_private_worker_cause_is_not_accepted(monkeypatch, tmp_path):
    client = InstallationWorkerClient(
        tmp_path / "worker.sock", owner_uid=os.getuid(), timeout=0.5
    )
    monkeypatch.setattr(
        client,
        "_exchange",
        lambda *_a, **_k: {
            "state": "failed",
            "apiKey": None,
            "completedSteps": [],
            "errorCode": "seerr_bootstrap_initial_admin_failed",
            "uncertainEffect": True,
            "causeCode": "private-worker-detail",
        },
    )
    with pytest.raises(
        SeerrBootstrapExecutionError,
        match="^seerr_bootstrap_resources_unavailable$",
    ) as raised:
        client.bootstrap_seerr(
            "a" * 32,
            stack(),
            private(),
            deadline=time.monotonic() + 0.4,
            gate=lambda: True,
        )
    assert raised.value.uncertain_effect
    assert "private-worker-detail" not in repr(raised.value)
