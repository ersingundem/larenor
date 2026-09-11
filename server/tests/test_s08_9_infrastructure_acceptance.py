"""Cross-adapter acceptance for the S08.9 infrastructure authority boundary.

All upstream reads and effects are synthetic.  These tests intentionally bind
Proxmox and Keenetic to the same security promises without contacting a LAN.
"""
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.errors import ApiError
from larenor_server.proxmox_commands.models import ProxmoxPowerEffectResult
from test_admin import activate, create as create_user
from test_keenetic_command_authority import (
    Actor as KeeneticActor,
    Harness as KeeneticHarness,
    authority as keenetic_authority,
    request as keenetic_request,
)
from test_keenetic_resource_adapter import _snapshot as keenetic_snapshot
from test_keenetic_resource_adapter import setup as setup_keenetic
from test_proxmox_power_commands import (
    base as proxmox_command_base,
    confirm as confirm_proxmox_command,
    descriptor as proxmox_descriptor,
    fixture as proxmox_command_fixture,
    preview as preview_proxmox_command,
    resource as create_proxmox_resource,
)
from test_proxmox_resource_adapter import SUMMARY as PROXMOX_SUMMARY
from test_proxmox_resource_adapter import setup as setup_proxmox


def _revoke_session(app, pair):
    family_id = app.state.core.auth.authenticate(pair["accessToken"]).family_id
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE session_families SET revoked_at=? WHERE id=?",
            (app.state.core.settings.clock(), family_id),
        )


def _change_resource(client, admin, record):
    ref = record["ref"]
    response = client.patch(
        f"/api/v1/admin/home-resources/{ref['coreId']}/{ref['homeId']}/{ref['id']}",
        headers=auth(admin),
        json={
            "expectedRevision": record["revision"],
            "expectedAclRevision": record["aclRevision"],
            "label": "Changed after preview",
            "order": 1,
        },
    )
    assert response.status_code == 200, response.text


def _change_acl(client, admin, record):
    create_user(client, admin)
    member = activate(client, "member")
    ref = record["ref"]
    response = client.put(
        f"/api/v1/admin/home-resources/{ref['coreId']}/{ref['homeId']}/{ref['id']}"
        f"/grants/{member['user']['id']}",
        headers=auth(admin),
        json={
            "expectedAclRevision": record["aclRevision"],
            "permissions": {"read": True, "write": False},
        },
    )
    assert response.status_code == 200, response.text


@pytest.mark.parametrize("adapter", ["proxmox", "keenetic"])
@pytest.mark.parametrize("drift", ["endpoint_and_credential", "resource", "acl", "session"])
def test_old_binding_preview_cannot_cross_authority_changes(server, adapter, drift):
    if adapter == "proxmox":
        app, client, admin, record, service, base, _public, body, _calls = setup_proxmox(server)
        app.state.core.proxmox._reader = lambda _connection, *, guard: (guard(), PROXMOX_SUMMARY)[1]
        changed_url = "https://moved-pve.invalid:8006"
        credentials = {"token": "root@pam!moved=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
        secret = "root@pam!moved"
    else:
        app, client, admin, record, service, base, _public, body = setup_keenetic(server)
        app.state.core.keenetic_resources._reader = (
            lambda _connection, guard: (guard(), keenetic_snapshot())[1]
        )
        changed_url = "https://moved-router.invalid"
        credentials = {"username": "moved", "password": "NEVER-RETURN-MOVED-SECRET"}
        secret = "NEVER-RETURN-MOVED-SECRET"

    proposed = client.post(base + "/binding-preview", headers=auth(admin), json=body)
    assert proposed.status_code == 201, proposed.text
    preview_id = proposed.json()["preview"]["id"]

    if drift == "endpoint_and_credential":
        changed = client.patch(
            f"/api/v1/admin/services/{service['id']}",
            headers=auth(admin),
            json={
                "expectedRevision": service["revision"],
                "name": "Moved infrastructure service",
                "baseUrl": changed_url,
                "credentials": credentials,
            },
        )
        assert changed.status_code == 200, changed.text
    elif drift == "resource":
        _change_resource(client, admin, record)
    elif drift == "acl":
        _change_acl(client, admin, record)
    else:
        _revoke_session(app, admin)

    confirmed = client.post(
        base + "/binding-confirm",
        headers=auth(admin),
        json={"previewId": preview_id},
    )
    assert confirmed.status_code == (401 if drift == "session" else 409), confirmed.text
    assert changed_url not in confirmed.text
    assert secret not in confirmed.text


@pytest.mark.parametrize("adapter", ["proxmox", "keenetic"])
@pytest.mark.parametrize("drift", ["binding", "service", "resource", "acl", "session"])
def test_old_command_preview_cannot_cross_authority_changes(tmp_path, adapter, drift):
    if adapter == "proxmox":
        app, settings, clock, provider, executor = proxmox_command_fixture(
            tmp_path / f"proxmox-{drift}"
        )
        with TestClient(app) as client:
            admin = ready((app, client, settings, clock))
            record = create_proxmox_resource(client, app, admin)
            provider.descriptor = proxmox_descriptor(record, status="stopped")
            proposal = preview_proxmox_command(
                client, app, admin, record, "start"
            ).json()["preview"]

            if drift == "binding":
                provider.descriptor = replace(provider.descriptor, binding_revision=2)
            elif drift == "service":
                provider.descriptor = replace(provider.descriptor, service_revision=2)
            elif drift == "resource":
                _change_resource(client, admin, record)
            elif drift == "acl":
                _change_acl(client, admin, record)
            else:
                _revoke_session(app, admin)

            response = confirm_proxmox_command(client, admin, record, proposal["id"])
            assert response.status_code == (401 if drift == "session" else 409), response.text
            assert executor.calls == 0
        return

    harness = KeeneticHarness()
    command = keenetic_authority(harness)
    actor = KeeneticActor()
    proposal = command.preview(actor, keenetic_request())["preview"]
    if drift == "session":
        actor = replace(actor, session_current=False)
    else:
        field = {
            "binding": "bindingRevision",
            "service": "serviceRevision",
            "resource": "resourceRevision",
            "acl": "aclRevision",
        }[drift]
        harness.current = harness.current.model_copy(
            update={field: getattr(harness.current, field) + 1}
        )
    with pytest.raises(ApiError):
        command.confirm(actor, proposal["id"], proposal["confirmToken"])
    assert harness.effects == []


@pytest.mark.parametrize("adapter", ["proxmox", "keenetic"])
def test_late_or_unknown_result_stays_closed_and_is_never_replayed(tmp_path, adapter):
    if adapter == "proxmox":
        app, settings, clock, provider, executor = proxmox_command_fixture(
            tmp_path / "proxmox-unknown"
        )
        with TestClient(app) as client:
            admin = ready((app, client, settings, clock))
            record = create_proxmox_resource(client, app, admin)
            provider.descriptor = proxmox_descriptor(record, status="stopped")

            def uncertain(current, _action, guard):
                executor.calls += 1
                guard()
                return ProxmoxPowerEffectResult(
                    "unknown", current.status, current.status_revision
                )

            executor.execute = uncertain
            proposal = preview_proxmox_command(
                client, app, admin, record, "start"
            ).json()["preview"]
            receipt = confirm_proxmox_command(
                client, admin, record, proposal["id"]
            ).json()["receipt"]
            assert receipt["state"] == "unknown"
            assert receipt["state"] != "succeeded"
            assert confirm_proxmox_command(
                client, admin, record, proposal["id"]
            ).status_code == 409
            assert executor.calls == 1
        return

    class Clock:
        value = 100.0

        def __call__(self):
            return self.value

    clock = Clock()
    harness = KeeneticHarness()

    def late(command_request, guard):
        guard()
        harness.effects.append(command_request.action)
        harness.current = harness.current.model_copy(
            update={"value": "enabled", "stateRevision": 12}
        )
        clock.value += 11

    command = keenetic_authority(harness, effect=late, clock=clock)
    proposal = command.preview(KeeneticActor(), keenetic_request())["preview"]
    receipt = command.confirm(
        KeeneticActor(), proposal["id"], proposal["confirmToken"]
    )["receipt"]
    assert receipt["status"] == "unknown"
    assert receipt["status"] != "succeeded"
    assert command.confirm(
        KeeneticActor(), proposal["id"], proposal["confirmToken"]
    )["receipt"] == receipt
    assert harness.effects == ["guest_wifi_enable"]
