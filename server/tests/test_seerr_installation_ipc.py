"""Closed Seerr bootstrap roundtrip over the retained worker socket."""

from contextlib import contextmanager
import os
from pathlib import Path
import tempfile
import time

import pytest

from larenor_server.plugins.installation_ipc import (
    InstallationIPCError,
    InstallationWorkerClient,
    InstallationWorkerServer,
    _seerr_bootstrap_result,
)
from larenor_server.plugins.seerr_bootstrap_models import (
    PrivateSeerrArrBinding,
    PrivateSeerrBootstrap,
)
from larenor_server.plugins.seerr_bootstrap_executor import (
    SeerrBootstrapExecutionError,
    SeerrBootstrapExecutionResult,
)
from test_media_host_preflight import stack
from test_seerr_initial_admin import API_KEY, PASSWORD
from larenor_server.plugins.seerr_arr_wiring import SeerrArrWiringResult
from larenor_server.plugins.seerr_initialization import SeerrInitializationResult


def private():
    return PrivateSeerrBootstrap(
        credential=PASSWORD,
        sourceBootstrapId="b" * 32,
        sourceBootstrapRevision=3,
        arrBindings=tuple(
            PrivateSeerrArrBinding(
                serviceId=service,
                configurationId=identifier * 32,
                configurationRevision=3,
                resourceRevision=4,
                serviceRevision=3,
                configurationDigest="c" * 64,
                hostname="larenor-" + identifier * 32,
                apiKey=identifier * 32,
                rootPath="/media/movies" if service == "radarr" else "/media/tv",
                profileId=4 if service == "radarr" else 5,
                profileName="HD-1080p",
            )
            for service, identifier in (("radarr", "1"), ("sonarr", "2"))
        ),
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
            "arr_wiring_verified",
            "initialization_verified",
        ),
        SeerrArrWiringResult("verified", ("radarr", "sonarr"), (7, 8)),
        SeerrInitializationResult("verified", False, ("initialized_verified",)),
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
            "music_assistant",
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


def test_worker_authority_failure_preserves_verified_convergence_receipts():
    wiring = SeerrArrWiringResult("verified", ("radarr", "sonarr"), (7, 8))
    initialization = SeerrInitializationResult(
        "verified", False, ("initialized_verified",)
    )
    failure = SeerrBootstrapExecutionError(
        "seerr_bootstrap_authority_changed",
        completed_steps=receipt().completed_steps,
        uncertain_effect=True,
        api_key=API_KEY,
        arr_wiring=wiring,
        initialization=initialization,
    )
    with running(Backend(failure)) as (_backend, client):
        with pytest.raises(SeerrBootstrapExecutionError) as raised:
            client.bootstrap_seerr(
                "a" * 32,
                stack(),
                private(),
                deadline=time.monotonic() + 0.4,
                gate=lambda: True,
            )

    assert raised.value.completed_steps == receipt().completed_steps
    assert raised.value.arr_wiring == wiring
    assert raised.value.initialization == initialization
    assert API_KEY not in repr(raised.value)


@pytest.mark.parametrize(
    "changes",
    [
        {"completedSteps": list(receipt().completed_steps[:3])},
        {"apiKey": None},
        {
            "completedSteps": list(receipt().completed_steps[:4]),
            "arrInstanceIds": [7, 8],
            "initialized": None,
            "initializationChanged": None,
        },
        {
            "completedSteps": list(receipt().completed_steps[:5]),
            "arrInstanceIds": None,
            "initialized": None,
            "initializationChanged": None,
        },
        {"initialized": None, "initializationChanged": None},
    ],
)
def test_failed_worker_receipts_require_exact_completed_step_coherence(changes):
    value = {
        "state": "failed",
        "apiKey": API_KEY,
        "completedSteps": list(receipt().completed_steps),
        "errorCode": "seerr_bootstrap_authority_changed",
        "uncertainEffect": True,
        "causeCode": None,
        "arrInstanceIds": [7, 8],
        "initialized": True,
        "initializationChanged": False,
    } | changes

    with pytest.raises(InstallationIPCError, match="^invalid_worker_result$"):
        _seerr_bootstrap_result(value)


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
    assert raised.value.completed_steps == receipt().completed_steps
    assert raised.value.api_key == API_KEY
    assert raised.value.arr_wiring == receipt().arr_wiring
    assert raised.value.initialization == receipt().initialization
    assert API_KEY not in repr(raised.value)


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
