"""Worker-private Seerr bootstrap orchestration over exact managed peers."""

import base64
import copy
import time
from dataclasses import replace

import pytest

from larenor_server.plugins.managed_container import (
    JournaledManagedContainerOperations,
    ManagedWorkerJournal,
)
from larenor_server.plugins.seerr_bootstrap_models import (
    PrivateSeerrArrBinding,
    PrivateSeerrBootstrap,
)
from larenor_server.plugins.seerr_bootstrap_executor import (
    SeerrBootstrapExecutionError,
    SeerrBootstrapExecutor,
)
from larenor_server.plugins.seerr_endpoint import (
    OpenSeerrEndpoint,
    prove_seerr_endpoint,
)
from larenor_server.plugins.seerr_endpoint import SeerrEndpointError
from larenor_server.plugins.seerr_initial_admin import (
    SeerrInitialAdmin,
    SeerrInitialAdminResult,
)
from larenor_server.plugins.seerr_arr_wiring import SeerrArrWiring, SeerrArrWiringResult
from test_jellyfin_startup import Connection
from test_managed_container_binding import (
    Engine,
    build as build_jellyfin,
    command,
    snapshot,
)
from test_seerr_endpoint import build as build_seerr
from test_seerr_initial_admin import PASSWORD, response, valid_responses


JOB = "7" * 32
API_KEY = base64.b64encode(b"178900000000012345678-1234-4abc-8def-123456789abc").decode(
    "ascii"
)


def private():
    return PrivateSeerrBootstrap(
        credential=PASSWORD,
        sourceBootstrapId="a" * 32,
        sourceBootstrapRevision=3,
    )


def bound_private():
    return private().model_copy(
        update={
            "arrBindings": tuple(
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
            )
        }
    )


@pytest.fixture
def prepared(tmp_path):
    with ManagedWorkerJournal(tmp_path / "managed", initialize=True) as journal:
        stack, seerr, _unused = build_seerr(journal.identity)
        _builder, jellyfin_stack, jellyfin = build_jellyfin(
            container_journal_id=journal.identity
        )
        assert stack == jellyfin_stack and seerr.network_id == jellyfin.network_id
        engine = Engine(seerr)
        operations = JournaledManagedContainerOperations(journal, engine)
        operations.apply(command(seerr), seerr)
        operations.apply(command(seerr, "start_container", "8" * 32), seerr)
        seerr_observed = copy.deepcopy(engine.container)
        next(iter(seerr_observed["NetworkSettings"]["Networks"].values())).update(
            IPAddress="172.28.0.5", IPPrefixLen=16, Gateway="172.28.0.1"
        )
        jellyfin_observed = snapshot(jellyfin)
        jellyfin_observed["State"] = {"Status": "running", "Running": True}
        next(iter(jellyfin_observed["NetworkSettings"]["Networks"].values())).update(
            IPAddress="172.28.0.2", IPPrefixLen=16, Gateway="172.28.0.1"
        )
        observed = {
            seerr.name: seerr_observed,
            jellyfin.name: jellyfin_observed,
        }

        def inspect(name):
            engine.calls.append(("inspect", name))
            return copy.deepcopy(observed[name])

        engine.inspect_container = inspect
        yield stack, seerr, jellyfin, observed, engine, operations


def executor(seerr, jellyfin, operations):
    return SeerrBootstrapExecutor(
        operations,
        lambda _stack, service="jellyfin": {
            "seerr": seerr,
            "jellyfin": jellyfin,
        }[service],
        SeerrInitialAdmin(),
    )


def connected(monkeypatch, stack, seerr, observed, connection=None, on_open=None):
    connection = connection or Connection(valid_responses())
    proof = prove_seerr_endpoint(
        observed[seerr.name], seerr, stack, observed[seerr.name]["Id"]
    )
    calls = []

    def opened(*args, **kwargs):
        calls.append((args, kwargs))
        if on_open is not None:
            on_open()
        return OpenSeerrEndpoint(connection, proof)

    monkeypatch.setattr(
        "larenor_server.plugins.seerr_bootstrap_executor.open_seerr_endpoint",
        opened,
    )
    return connection, calls


def test_reconciles_seerr_and_bootstraps_against_exact_jellyfin_peer(
    prepared, monkeypatch
):
    stack, seerr, jellyfin, observed, engine, operations = prepared
    connection, opens = connected(monkeypatch, stack, seerr, observed)
    gates = []

    result = executor(seerr, jellyfin, operations).execute(
        JOB,
        stack,
        private(),
        deadline=time.monotonic() + 10,
        gate=lambda: gates.append(1) or True,
    )

    assert result.state == "verified" and result.api_key == API_KEY
    assert result.completed_steps[-1] == "session_destroyed"
    assert len(opens) == 1 and connection.closed and len(gates) >= 3
    assert jellyfin.name.encode() in connection.requests[1]
    assert (
        len([call for call in engine.calls if call == ("inspect", jellyfin.name)]) >= 2
    )
    assert PASSWORD not in repr(result) and API_KEY not in repr(result)


def test_production_executor_wires_exact_bound_arr_services_before_success(
    prepared, monkeypatch
):
    stack, seerr, jellyfin, observed, _engine, operations = prepared
    connected(monkeypatch, stack, seerr, observed)
    calls = []

    def configure(_self, connection, **values):
        calls.append((connection, values))
        return SeerrArrWiringResult("verified", ("radarr", "sonarr"), (8, 9))

    monkeypatch.setattr(SeerrArrWiring, "configure", configure)
    result = SeerrBootstrapExecutor(
        operations,
        lambda _stack, service="jellyfin": {
            "seerr": seerr,
            "jellyfin": jellyfin,
        }[service],
        SeerrInitialAdmin(),
        SeerrArrWiring(),
    ).execute(
        JOB,
        stack,
        bound_private(),
        deadline=time.monotonic() + 10,
        gate=lambda: True,
    )

    assert result.completed_steps[-1] == "arr_wiring_verified"
    assert result.arr_wiring.instance_ids == (8, 9)
    services = calls[0][1]["services"]
    assert [(item.service_id, item.profile_id, item.root_path) for item in services] == [
        ("radarr", 4, "/media/movies"),
        ("sonarr", 5, "/media/tv"),
    ]
    assert calls[0][1]["close_connection"] is False


def test_jellyfin_drift_after_connect_blocks_credentials(prepared, monkeypatch):
    stack, seerr, jellyfin, observed, _engine, operations = prepared
    connection = Connection([])

    def drift():
        observed[jellyfin.name]["State"] = {"Status": "exited", "Running": False}

    connected(monkeypatch, stack, seerr, observed, connection, drift)
    with pytest.raises(
        SeerrBootstrapExecutionError, match="^seerr_bootstrap_peer_changed$"
    ) as raised:
        executor(seerr, jellyfin, operations).execute(
            JOB,
            stack,
            private(),
            deadline=time.monotonic() + 10,
            gate=lambda: True,
        )

    assert not connection.requests and connection.closed
    assert not raised.value.uncertain_effect


def test_different_managed_network_never_opens_endpoint(prepared, monkeypatch):
    stack, seerr, jellyfin, _observed, _engine, operations = prepared
    foreign = replace(jellyfin, network_id="9" * 64)
    monkeypatch.setattr(
        "larenor_server.plugins.seerr_bootstrap_executor.open_seerr_endpoint",
        lambda *_a, **_k: (_ for _ in ()).throw(AssertionError()),
    )
    with pytest.raises(
        SeerrBootstrapExecutionError, match="^seerr_bootstrap_peer_changed$"
    ):
        executor(seerr, foreign, operations).execute(
            JOB,
            stack,
            private(),
            deadline=time.monotonic() + 10,
            gate=lambda: True,
        )


def test_initial_admin_failure_preserves_static_effect_state(prepared, monkeypatch):
    stack, seerr, jellyfin, observed, _engine, operations = prepared
    connection = Connection(
        [
            response({"initialized": False, "applicationTitle": "Seerr"}),
            response({}, status=500, close=True),
        ]
    )
    connected(monkeypatch, stack, seerr, observed, connection)
    with pytest.raises(
        SeerrBootstrapExecutionError, match="^seerr_bootstrap_initial_admin_failed$"
    ) as raised:
        executor(seerr, jellyfin, operations).execute(
            JOB,
            stack,
            private(),
            deadline=time.monotonic() + 10,
            gate=lambda: True,
        )
    assert raised.value.uncertain_effect
    assert raised.value.cause_code == "seerr_initial_admin_protocol"
    assert PASSWORD not in repr(raised.value)


def test_endpoint_refusal_is_static_and_closes_before_credentials(
    prepared, monkeypatch
):
    stack, seerr, jellyfin, _observed, _engine, operations = prepared
    monkeypatch.setattr(
        "larenor_server.plugins.seerr_bootstrap_executor.open_seerr_endpoint",
        lambda *_a, **_k: (_ for _ in ()).throw(
            SeerrEndpointError("seerr_endpoint_unavailable")
        ),
    )
    with pytest.raises(
        SeerrBootstrapExecutionError, match="^seerr_bootstrap_endpoint_unavailable$"
    ) as raised:
        executor(seerr, jellyfin, operations).execute(
            JOB,
            stack,
            private(),
            deadline=time.monotonic() + 10,
            gate=lambda: True,
        )
    assert not raised.value.uncertain_effect


def test_peer_drift_after_admin_is_uncertain(prepared, monkeypatch):
    stack, seerr, jellyfin, observed, _engine, operations = prepared
    connected(monkeypatch, stack, seerr, observed)
    original = SeerrInitialAdmin.create

    def create(self, *args, **kwargs):
        result = original(self, *args, **kwargs)
        observed[jellyfin.name]["State"] = {"Status": "exited", "Running": False}
        return result

    monkeypatch.setattr(SeerrInitialAdmin, "create", create)
    with pytest.raises(
        SeerrBootstrapExecutionError, match="^seerr_bootstrap_peer_changed$"
    ) as raised:
        executor(seerr, jellyfin, operations).execute(
            JOB,
            stack,
            private(),
            deadline=time.monotonic() + 10,
            gate=lambda: True,
        )
    assert raised.value.uncertain_effect
    assert raised.value.completed_steps[-1] == "session_destroyed"


def test_authority_loss_after_admin_is_uncertain(prepared, monkeypatch):
    stack, seerr, jellyfin, observed, _engine, operations = prepared
    connected(monkeypatch, stack, seerr, observed)
    gates = iter((True, True, True, False))
    with pytest.raises(
        SeerrBootstrapExecutionError, match="^seerr_bootstrap_authority_changed$"
    ) as raised:
        executor(seerr, jellyfin, operations).execute(
            JOB,
            stack,
            private(),
            deadline=time.monotonic() + 10,
            gate=lambda: next(gates),
        )
    assert raised.value.uncertain_effect


def test_invalid_adapter_result_is_uncertain_and_never_exposes_key(
    prepared, monkeypatch
):
    stack, seerr, jellyfin, observed, _engine, operations = prepared
    connected(monkeypatch, stack, seerr, observed)
    forged = SeerrInitialAdminResult(
        "verified",
        API_KEY,
        (
            "uninitialized_verified",
            "admin_created",
            "api_key_verified",
            "session_destroyed",
        ),
    )
    object.__setattr__(forged, "api_key", "private-invalid-key")
    monkeypatch.setattr(SeerrInitialAdmin, "create", lambda *_a, **_k: forged)
    with pytest.raises(
        SeerrBootstrapExecutionError, match="^seerr_bootstrap_initial_admin_failed$"
    ) as raised:
        executor(seerr, jellyfin, operations).execute(
            JOB,
            stack,
            private(),
            deadline=time.monotonic() + 10,
            gate=lambda: True,
        )
    assert raised.value.uncertain_effect
    assert "private-invalid-key" not in repr(raised.value)


def test_authority_loss_before_endpoint_never_connects(prepared, monkeypatch):
    stack, seerr, jellyfin, _observed, _engine, operations = prepared
    monkeypatch.setattr(
        "larenor_server.plugins.seerr_bootstrap_executor.open_seerr_endpoint",
        lambda *_a, **_k: (_ for _ in ()).throw(AssertionError()),
    )
    with pytest.raises(
        SeerrBootstrapExecutionError, match="^seerr_bootstrap_authority_changed$"
    ):
        executor(seerr, jellyfin, operations).execute(
            JOB,
            stack,
            private(),
            deadline=time.monotonic() + 10,
            gate=lambda: False,
        )


@pytest.mark.parametrize(
    "change",
    [
        {"credential": "short"},
        {"sourceBootstrapId": JOB},
        {"username": "foreign"},
    ],
)
def test_unverified_or_invalid_jellyfin_private_state_is_rejected(
    prepared, monkeypatch, change
):
    stack, seerr, jellyfin, _observed, _engine, operations = prepared
    payload = private().model_copy(update=change)
    monkeypatch.setattr(
        "larenor_server.plugins.seerr_bootstrap_executor.open_seerr_endpoint",
        lambda *_a, **_k: (_ for _ in ()).throw(AssertionError()),
    )
    with pytest.raises(
        SeerrBootstrapExecutionError, match="^invalid_seerr_bootstrap_execution$"
    ):
        executor(seerr, jellyfin, operations).execute(
            JOB,
            stack,
            payload,
            deadline=time.monotonic() + 10,
            gate=lambda: True,
        )
