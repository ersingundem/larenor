"""Proxmox worker commands require a current component egress grant."""

from types import SimpleNamespace

import pytest

from conftest import auth, ready
from larenor_server.errors import ApiError
from larenor_server.proxmox_commands.core_worker import EgressGatedProxmoxExecutor
from larenor_server.proxmox_commands.models import ProxmoxGuestDescriptor
from larenor_server.proxmox_commands.worker_ipc import ProxmoxPowerWorkerError


class Delegate:
    def __init__(self):
        self.calls = []

    def execute_bounded(self, descriptor, action, guard, **options):
        guard()
        options["continuation_guard"]()
        self.calls.append((descriptor, action, options))
        return "ok"


class Egress:
    def __init__(self, addresses=("10.20.30.40",)):
        self.addresses = addresses
        self.calls = []

    def check_component(self, actor, service_id, revision, component):
        self.calls.append((actor, service_id, revision, component))
        return SimpleNamespace(grants=[
            SimpleNamespace(addresses=[
                SimpleNamespace(address=value) for value in self.addresses
            ])
        ])


def descriptor():
    return ProxmoxGuestDescriptor(
        "a" * 32, "binding_1", 7, "service_1", 9,
        "qemu", "stopped", 11,
    )


def test_executor_binds_current_policy_addresses_and_rechecks_during_result():
    delegate, egress = Delegate(), Egress()
    executor = EgressGatedProxmoxExecutor(delegate, egress)
    actor = SimpleNamespace(id="b" * 32)
    guards = []
    result = executor.execute_for_actor(
        actor, descriptor(), "start", lambda: guards.append("dispatch"),
        preview=object(), deadline_ms=2000,
        continuation_guard=lambda: guards.append("continuation"),
    )
    assert result == "ok"
    assert delegate.calls[0][2]["allowed_addresses"] == ("10.20.30.40",)
    assert guards == ["dispatch", "dispatch", "continuation", "continuation"]
    assert len(egress.calls) == 4
    assert all(call[1:] == (
        "service_1", 9, "proxmox_command_worker") for call in egress.calls)


def test_executor_fails_closed_before_worker_when_grant_is_missing():
    class Denied:
        def check_component(self, *_args):
            raise ApiError("outbound_denied", 403)

    delegate = Delegate()
    executor = EgressGatedProxmoxExecutor(delegate, Denied())
    with pytest.raises(ProxmoxPowerWorkerError, match="worker_unavailable"):
        executor.execute_for_actor(
            SimpleNamespace(id="b" * 32), descriptor(), "start", lambda: None,
            preview=object(), deadline_ms=2000,
        )
    assert delegate.calls == []


def test_proxmox_service_policy_is_typed_to_worker_component(server):
    _app, client, _settings, _clock = server
    admin = ready(server)
    service = client.post("/api/v1/admin/services", headers=auth(admin), json={
        "kind": "proxmox", "name": "Synthetic PVE",
        "baseUrl": "https://pve.invalid:8006",
        "credentials": {
            "token": "root@pam!larenor=01234567-89ab-cdef-0123-456789abcdef",
        },
    }).json()["service"]
    response = client.put(
        f"/api/v1/admin/services/{service['id']}/outbound-policy",
        headers=auth(admin), json={
            "expectedRevision": 0, "expectedServiceRevision": 1,
            "grants": [{
                "scheme": "https", "host": "pve.invalid", "port": 8006,
                "addresses": [{"address": "10.20.30.40", "network": "lan"}],
            }],
        },
    )
    assert response.status_code == 200, response.text
    assert response.json()["policy"]["component"] == "proxmox_command_worker"
