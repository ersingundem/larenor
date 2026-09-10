import json
import os
import socket
import time

import pytest

from larenor_server.keenetic_commands.credential_lease import (
    KeeneticCredentialLeaseIssuer,
    KeeneticCredentialLeaseVerifier,
    KeeneticLeaseError,
)
from larenor_server.keenetic_commands.rci_adapter import PackagedRciCommandAdapter
from larenor_server.keenetic_commands.rci_transport import LeasedKeeneticRciTransport
from larenor_server.keenetic_commands.service import KeeneticEffectError
from larenor_server.keenetic_commands.worker_ipc import (
    KeeneticCommandWorkerClient,
    KeeneticCommandWorkerServer,
    LeasedKeeneticCommandWorkerClient,
)
from larenor_server.keenetic_commands.worker_runtime import (
    RuntimeConfigurationError,
    load_policy,
    main,
    runtime_adapter_factory,
)

from conftest import auth, ready
from test_keenetic_command_authority import Actor, request, state
from test_keenetic_command_worker_ipc import socket_directory
from test_keenetic_rci_transport import (
    SECRET,
    Services,
    ScriptFactory,
    binding,
    challenge,
    ok,
)


class Clock:
    def __init__(self, value=1000.0):
        self.value = value

    def __call__(self):
        return self.value


def private_bytes(path, value):
    path.write_bytes(value)
    path.chmod(0o600)
    return path


def rci_policy(path, secret):
    path.write_text(json.dumps({
        "version": 1,
        "adapter": "rci",
        "secretFile": str(secret),
    }))
    path.chmod(0o600)
    return path


def test_lease_is_encrypted_revision_bound_one_use_and_zeroized(server):
    app, client, _, _ = server
    pair = ready(server)
    saved = client.post("/api/v1/admin/services", headers=auth(pair), json={
        "name": "Lease router",
        "kind": "keenetic",
        "baseUrl": "https://192.168.1.1",
        "credentials": {"username": "fixture-admin", "password": SECRET},
    }).json()["service"]
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    expected = state().model_copy(update={
        "coreId": app.state.core.context.coreId,
        "homeId": app.state.core.context.homeId,
        "serviceId": saved["id"],
        "serviceRevision": saved["revision"],
    })
    clock = Clock()
    key = b"L" * 32
    lease = KeeneticCredentialLeaseIssuer(
        app.state.core.services, key, clock=clock
    ).issue(actor, expected, worker_id="a" * 32, ttl_seconds=5)
    assert SECRET not in json.dumps(lease.model_dump(mode="json")) + repr(lease)

    verifier = KeeneticCredentialLeaseVerifier(
        key, worker_id="a" * 32, clock=clock
    )
    with verifier.open(lease, expected) as connection:
        assert connection.service_id == expected.serviceId
        assert connection.service_revision == expected.serviceRevision
        assert connection.password_text() == SECRET
        buffers = connection._buffers
    assert all(not any(buffer) for buffer in buffers)
    with pytest.raises(KeeneticLeaseError, match="^keenetic_lease_invalid$"):
        verifier.open(lease, expected)


@pytest.mark.parametrize("failure", ["tamper", "audience", "expired", "rollback", "tuple"])
def test_lease_tamper_expiry_audience_rollback_and_tuple_fail_closed(failure):
    current = state()
    clock = Clock()
    key = b"K" * 32
    lease = KeeneticCredentialLeaseIssuer(
        Services(binding()), key, clock=clock
    ).issue(Actor(), current, worker_id="a" * 32, ttl_seconds=5)
    verifier = KeeneticCredentialLeaseVerifier(
        key,
        worker_id="b" * 32 if failure == "audience" else "a" * 32,
        clock=clock,
    )
    candidate = lease
    expected = current
    if failure == "tamper":
        suffix = "A" if lease.token[-1] != "A" else "B"
        candidate = lease.model_copy(update={"token": lease.token[:-1] + suffix})
    elif failure == "expired":
        clock.value += 6
    elif failure == "rollback":
        verifier.open(lease, current).close()
        clock.value = 999
    elif failure == "tuple":
        expected = current.model_copy(
            update={"stateRevision": current.stateRevision + 1}
        )
    with pytest.raises(KeeneticLeaseError, match="^keenetic_lease_invalid$") as caught:
        verifier.open(candidate, expected)
    assert SECRET not in str(caught.value)


def test_encrypted_lease_crosses_private_worker_for_one_dispatch():
    current = state(target="WifiMaster0/AccessPoint1")
    clock = Clock()
    key = b"W" * 32
    worker_id = "a" * 32
    issuer = KeeneticCredentialLeaseIssuer(
        Services(binding()), key, clock=clock
    )
    factory = ScriptFactory([challenge(), ok(current, "enabled")])
    adapter = PackagedRciCommandAdapter(LeasedKeeneticRciTransport(
        KeeneticCredentialLeaseVerifier(key, worker_id=worker_id, clock=clock),
        transport_factory=factory,
    ))
    with socket_directory() as directory:
        worker = KeeneticCommandWorkerServer(
            directory / "keenetic.sock",
            adapter,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
            timeout=.5,
        )
        worker.start()
        try:
            raw = KeeneticCommandWorkerClient(
                worker.path,
                owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(),
                timeout=.5,
            )
            effect = LeasedKeeneticCommandWorkerClient(
                raw, issuer, worker_id=worker_id, ttl_seconds=5
            )
            observed = effect.execute_for_actor(
                Actor(), request(current=current), lambda: None
            )
            assert observed.value == "enabled"
            assert SECRET not in repr(effect) + repr(adapter) + repr(observed)
        finally:
            worker.close()
    assert len([call for call in factory.calls if call[0] == "POST"]) == 1


def test_missing_corrupt_or_public_runtime_key_fails_before_network(tmp_path, monkeypatch):
    monkeypatch.setattr(socket, "socket", lambda *_args, **_kwargs: pytest.fail("socket opened"))
    monkeypatch.setattr(socket, "getaddrinfo", lambda *_args, **_kwargs: pytest.fail("DNS used"))
    monkeypatch.setattr(
        "larenor_server.keenetic_commands.worker_runtime._platform",
        lambda: "linux/amd64",
    )
    candidates = [tmp_path / "missing.key"]
    corrupt = private_bytes(tmp_path / "corrupt.key", b"short")
    public = private_bytes(tmp_path / "public.key", b"P" * 32)
    public.chmod(0o644)
    candidates.extend([corrupt, public])
    for index, secret in enumerate(candidates):
        source = rci_policy(tmp_path / f"policy-{index}.json", secret)
        assert main(["--policy", str(source), "--check-config"]) == 2


def test_check_config_validates_key_without_starting_worker(tmp_path, monkeypatch):
    key = private_bytes(tmp_path / "worker.key", b"Q" * 32)
    source = rci_policy(tmp_path / "worker.json", key)
    monkeypatch.setattr(socket, "socket", lambda *_args, **_kwargs: pytest.fail("socket opened"))
    monkeypatch.setattr(socket, "getaddrinfo", lambda *_args, **_kwargs: pytest.fail("DNS used"))
    monkeypatch.setattr(
        "larenor_server.keenetic_commands.worker_runtime._platform",
        lambda: "linux/amd64",
    )
    assert main(["--policy", str(source), "--check-config"]) == 0
    policy = load_policy(source)
    factory = runtime_adapter_factory(policy, clock=Clock())
    assert callable(factory)


def test_post_effect_uncertainty_spends_lease_and_cannot_retry():
    current = state(target="WifiMaster0/AccessPoint1")
    clock = Clock()
    key = b"R" * 32
    worker_id = "c" * 32
    lease = KeeneticCredentialLeaseIssuer(
        Services(binding()), key, clock=clock
    ).issue(Actor(), current, worker_id=worker_id, ttl_seconds=5)
    from larenor_server.keenetic_commands.rci_adapter import RciCommand
    from larenor_server.services.transport import ProbeTransportError

    factory = ScriptFactory([challenge(), ProbeTransportError("request_timeout")])
    transport = LeasedKeeneticRciTransport(
        KeeneticCredentialLeaseVerifier(key, worker_id=worker_id, clock=clock),
        transport_factory=factory,
    )
    command = RciCommand(
        operation="guest_wifi_enable",
        expectedState=current,
        credentialLease=lease,
    )
    with pytest.raises(KeeneticEffectError) as first:
        transport(command, deadline=time.monotonic() + 1, cancelled=lambda: False)
    assert first.value.uncertain is True
    with pytest.raises(KeeneticEffectError, match="^keenetic_effect_unavailable$") as second:
        transport(command, deadline=time.monotonic() + 1, cancelled=lambda: False)
    assert second.value.uncertain is False
    assert [call[0] for call in factory.calls if call[0] in {"GET", "POST"}] == [
        "GET", "POST"
    ]
