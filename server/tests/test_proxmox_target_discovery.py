"""Admin-only Proxmox target discovery; every provider value is synthetic."""
from dataclasses import dataclass
import socket

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.proxmox_commands.discovery_models import TargetDiscoveryPage
from larenor_server.proxmox_commands.models import ProxmoxGuestDescriptor
from test_admin import activate, create as create_user
from test_proxmox_resource_adapter import bind, setup


@dataclass
class DiscoveryProvider:
    values: list
    reads: int = 0
    on_read: object = None

    def discover(self, resource_id):
        self.reads += 1
        values = list(self.values)
        if self.on_read is not None:
            callback, self.on_read = self.on_read, None
            callback()
        return [value for value in values if value.resource_id == resource_id]


def discovered(record, binding, service, *, node="pve-a", guest_id=101,
               kind="qemu", state="running", status_revision=7,
               installation_id=None, ready=True):
    return ProxmoxGuestDescriptor(
        resource_id=record["ref"]["id"],
        binding_id=binding["id"],
        binding_revision=binding["revision"],
        service_id=service["id"],
        service_revision=service["revision"],
        guest_kind=kind,
        status=state,
        status_revision=status_revision,
        installation_id=installation_id or service["id"],
        node=node,
        guest_id=guest_id,
        capability_ready=ready,
    )


def prepared(server):
    app, client, admin, record, service, resource_base, _, body, _ = setup(server)
    _, binding = bind(client, admin, resource_base, body)
    power_base = (
        "/api/v1/admin/proxmox-power/"
        f"{record['ref']['coreId']}/{record['ref']['homeId']}/{record['ref']['id']}"
    )
    return app, client, admin, record, service, binding, power_base


def test_admin_reads_exact_redacted_command_ready_target(server):
    app, client, admin, record, service, binding, base = prepared(server)
    provider = DiscoveryProvider([discovered(record, binding, service)])
    app.state.core.proxmox_power.provider = provider

    response = client.get(base + "/targets", headers=auth(admin))
    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body) == {
        "schemaVersion", "scope", "resourceId", "userRevision",
        "resourceRevision", "aclRevision", "bindingId", "bindingRevision",
        "serviceId", "serviceRevision", "snapshot", "targets", "nextAfter",
    }
    target = body["targets"][0]
    assert target == {
        "schemaVersion": 1,
        "targetId": target["targetId"],
        "installationId": service["id"],
        "node": "pve-a",
        "guestKind": "qemu",
        "guestId": 101,
        "currentState": "running",
        "statusRevision": 7,
        "allowedCommands": ["shutdown", "stop", "reboot", "suspend"],
        "capabilityReady": True,
    }
    assert len(target["targetId"]) == 32
    assert provider.reads == 2
    text = response.text.lower()
    assert all(secret not in text for secret in (
        "pve.invalid", "root@pam", "01234567-89ab", "credentials", "token",
    ))
    TargetDiscoveryPage.model_validate(body)


def test_member_and_missing_binding_fail_before_provider_read(server):
    app, client, admin, record, service, binding, base = prepared(server)
    provider = DiscoveryProvider([discovered(record, binding, service)])
    app.state.core.proxmox_power.provider = provider
    create_user(client, admin)
    member = activate(client, "member")
    assert client.get(base + "/targets", headers=auth(member)).status_code == 403
    assert provider.reads == 0

    other = client.post(
        f"/api/v1/admin/home-resources/{record['ref']['coreId']}/{record['ref']['homeId']}",
        headers=auth(admin),
        json={"kind": "resource", "label": "Unbound VM", "order": 2},
    ).json()["record"]
    other_base = (
        "/api/v1/admin/proxmox-power/"
        f"{other['ref']['coreId']}/{other['ref']['homeId']}/{other['ref']['id']}/targets"
    )
    assert client.get(other_base, headers=auth(admin)).status_code == 404
    assert provider.reads == 0


def test_default_discovery_is_offline_and_never_opens_a_network_socket(
    server, monkeypatch
):
    app, client, admin, record, service, binding, base = prepared(server)
    real_socket = socket.socket

    def deny_network(family=socket.AF_INET, *args, **kwargs):
        if family in (socket.AF_INET, socket.AF_INET6):
            pytest.fail("target discovery opened a network socket")
        return real_socket(family, *args, **kwargs)

    monkeypatch.setattr(socket, "socket", deny_network)
    assert client.get(base + "/targets", headers=auth(admin)).status_code == 404

@pytest.mark.parametrize("mode", ["missing", "duplicate", "oversized", "malformed"])
def test_missing_ambiguous_and_unbounded_provider_results_fail_closed(server, mode):
    app, client, admin, record, service, binding, base = prepared(server)
    value = discovered(record, binding, service)
    values = {
        "missing": [],
        "duplicate": [value, value],
        "oversized": [
            discovered(record, binding, service, guest_id=index + 1, node=f"pve-{index}")
            for index in range(257)
        ],
        "malformed": [discovered(record, binding, service, node="../private")],
    }[mode]
    app.state.core.proxmox_power.provider = DiscoveryProvider(values)
    response = client.get(base + "/targets", headers=auth(admin))
    assert response.status_code == {
        "missing": 404,
        "duplicate": 409,
        "oversized": 429,
        "malformed": 503,
    }[mode]
    assert "private" not in response.text


def test_pagination_is_snapshot_bound_and_multiple_guests_are_not_command_ready(server):
    app, client, admin, record, service, binding, base = prepared(server)
    provider = DiscoveryProvider([
        discovered(record, binding, service, guest_id=102, kind="lxc", state="stopped"),
        discovered(record, binding, service, guest_id=101),
    ])
    app.state.core.proxmox_power.provider = provider
    first = client.get(base + "/targets?limit=1", headers=auth(admin))
    assert first.status_code == 200, first.text
    page = first.json()
    assert len(page["targets"]) == 1 and page["nextAfter"] is not None
    assert page["targets"][0]["capabilityReady"] is False
    assert page["targets"][0]["allowedCommands"] == []
    second = client.get(
        base + "/targets",
        headers=auth(admin),
        params={
            "limit": "1",
            "after": page["nextAfter"],
            "expectedSnapshot": page["snapshot"],
        },
    )
    assert second.status_code == 200
    assert len(second.json()["targets"]) == 1
    assert second.json()["nextAfter"] is None

    provider.values[0] = discovered(
        record, binding, service, guest_id=102, kind="lxc", state="running",
        status_revision=8,
    )
    stale = client.get(
        base + "/targets",
        headers=auth(admin),
        params={
            "limit": "1",
            "after": page["nextAfter"],
            "expectedSnapshot": page["snapshot"],
        },
    )
    assert stale.status_code == 409


@pytest.mark.parametrize("query", [
    "?limit=0", "?limit=101", "?limit=01", "?after=bad",
    "?after=" + "a" * 32, "?expectedSnapshot=" + "b" * 64,
    "?limit=1&limit=1", "?limit=" + "9" * 1000, "?unknown=1",
])
def test_query_bounds_and_cursor_contract_are_exact(server, query):
    app, client, admin, record, service, binding, base = prepared(server)
    provider = DiscoveryProvider([discovered(record, binding, service)])
    app.state.core.proxmox_power.provider = provider
    assert client.get(base + "/targets" + query, headers=auth(admin)).status_code == 400
    assert provider.reads == 0


def test_duplicate_authorization_and_unbound_installation_are_rejected(server):
    app, client, admin, record, service, binding, base = prepared(server)
    provider = DiscoveryProvider([discovered(record, binding, service)])
    app.state.core.proxmox_power.provider = provider
    duplicate = client.get(
        base + "/targets",
        headers=[
            ("Authorization", "Bearer " + admin["accessToken"]),
            ("Authorization", "Bearer " + admin["accessToken"]),
        ],
    )
    assert duplicate.status_code == 400
    assert provider.reads == 0

    provider.values = [
        discovered(record, binding, service, installation_id="9" * 32)
    ]
    assert client.get(base + "/targets", headers=auth(admin)).status_code == 409


def test_binding_ciphertext_corruption_and_provider_revision_drift_are_static(server):
    app, client, admin, record, service, binding, base = prepared(server)
    provider = DiscoveryProvider([discovered(record, binding, service)])
    app.state.core.proxmox_power.provider = provider
    with app.state.core.db.connection() as connection:
        connection.execute(
            "UPDATE proxmox_resource_bindings SET ciphertext=? WHERE resource_id=?",
            (b"corrupt", record["ref"]["id"]),
        )
    assert client.get(base + "/targets", headers=auth(admin)).status_code == 503
    assert provider.reads == 0


def test_session_loss_and_late_status_revision_are_discarded(server):
    app, client, admin, record, service, binding, base = prepared(server)
    first = discovered(record, binding, service)
    provider = DiscoveryProvider([first])
    app.state.core.proxmox_power.provider = provider

    def drift():
        provider.values = [discovered(
            record, binding, service, state="stopped", status_revision=8,
        )]

    provider.on_read = drift
    assert client.get(base + "/targets", headers=auth(admin)).status_code == 409

    provider.values = [first]
    family = app.state.core.auth.authenticate(admin["accessToken"]).family_id

    def revoke():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE session_families SET revoked_at=? WHERE id=?",
                (app.state.core.settings.clock(), family),
            )

    provider.on_read = revoke
    assert client.get(base + "/targets", headers=auth(admin)).status_code == 401


def test_strict_public_model_rejects_extra_or_success_like_capability(server):
    app, client, admin, record, service, binding, base = prepared(server)
    provider = DiscoveryProvider([discovered(record, binding, service)])
    app.state.core.proxmox_power.provider = provider
    body = client.get(base + "/targets", headers=auth(admin)).json()
    with pytest.raises(ValueError):
        TargetDiscoveryPage.model_validate({**body, "host": "private.invalid"})
    target = body["targets"][0]
    with pytest.raises(ValueError):
        TargetDiscoveryPage.model_validate({
            **body,
            "targets": [{**target, "capabilityReady": False}],
        })
