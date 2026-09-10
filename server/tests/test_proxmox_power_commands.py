"""Synthetic Proxmox power authority; no LAN or Proxmox request is made."""
from dataclasses import dataclass, replace
import socket

import pytest
from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import StartupError
from larenor_server.proxmox_commands.models import (
    ConfirmRequest,
    PowerReceipt,
    ProxmoxGuestDescriptor,
    ProxmoxPowerEffectResult,
)


@dataclass
class Provider:
    descriptor: ProxmoxGuestDescriptor | None = None
    reads: int = 0

    def resolve(self, resource_id):
        self.reads += 1
        value = self.descriptor
        return value if value is not None and value.resource_id == resource_id else None


@dataclass
class Executor:
    provider: Provider
    outcome: str = "succeeded"
    calls: int = 0
    action: str | None = None

    def execute(self, descriptor, action, guard):
        self.calls += 1
        self.action = action
        guard()
        target = {
            "start": "running",
            "shutdown": "stopped",
            "stop": "stopped",
            "reboot": "running",
            "reset": "running",
            "suspend": "suspended",
            "resume": "running",
        }[action]
        if self.outcome == "succeeded":
            self.provider.descriptor = replace(
                descriptor, status=target, status_revision=descriptor.status_revision + 1
            )
            return ProxmoxPowerEffectResult("succeeded", target, descriptor.status_revision + 1)
        return ProxmoxPowerEffectResult(self.outcome, descriptor.status, descriptor.status_revision)


def fixture(tmp_path, *, provider=None, executor=None):
    root = tmp_path.resolve()
    clock = Clock()
    settings = Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )
    provider = provider or Provider()
    executor = executor or Executor(provider)
    app = create_app(
        settings,
        proxmox_guest_provider=provider,
        proxmox_power_executor=executor,
    )
    return app, settings, clock, provider, executor


def resource(client, app, admin):
    scope = app.state.core.context
    response = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=auth(admin),
        json={"kind": "resource", "label": "Synthetic VM", "order": 0},
    )
    assert response.status_code == 201
    return response.json()["record"]


def user_revision(app, user_id):
    with app.state.core.db.connection() as connection:
        return connection.execute(
            "SELECT revision FROM users WHERE id=?", (user_id,)
        ).fetchone()[0]


def descriptor(record, *, kind="qemu", status="running"):
    return ProxmoxGuestDescriptor(
        resource_id=record["ref"]["id"],
        binding_id="b" * 32,
        binding_revision=1,
        service_id="s" * 32,
        service_revision=1,
        guest_kind=kind,
        status=status,
        status_revision=1,
    )


def base(record):
    ref = record["ref"]
    return f"/api/v1/admin/proxmox-power/{ref['coreId']}/{ref['homeId']}/{ref['id']}"


def journal(client, admin, record, limit=50):
    return client.get(
        base(record) + f"/journal?limit={limit}", headers=auth(admin)
    )


def preview_body(app, admin, record, action, request_id="d" * 32):
    current = app.state.core.proxmox_power.provider.resolve(record["ref"]["id"])
    return {
        "schemaVersion": 1,
        "requestId": request_id,
        "action": action,
        "expectedUserRevision": user_revision(app, admin["user"]["id"]),
        "expectedResourceRevision": record["revision"],
        "expectedAclRevision": record["aclRevision"],
        "expectedBindingId": current.binding_id,
        "expectedBindingRevision": current.binding_revision,
        "expectedServiceId": current.service_id,
        "expectedServiceRevision": current.service_revision,
        "expectedGuestKind": current.guest_kind,
        "expectedCurrentState": current.status,
        "expectedStatusRevision": current.status_revision,
    }


def preview(client, app, admin, record, action, request_id="d" * 32):
    return client.post(
        base(record) + "/previews",
        headers=auth(admin),
        json=preview_body(app, admin, record, action, request_id),
    )


def confirm(client, admin, record, preview_id, request_id="d" * 32, high=False):
    return client.post(
        base(record) + f"/previews/{preview_id}/confirm",
        headers=auth(admin),
        json={
            "schemaVersion": 1,
            "requestId": request_id,
            "highRiskConfirmed": high,
            "deadlineMs": 5000,
        },
    )


@pytest.mark.parametrize(
    "kind,state,action,risk,target",
    [
        ("qemu", "stopped", "start", "low", "running"),
        ("lxc", "running", "shutdown", "moderate", "stopped"),
        ("qemu", "running", "stop", "high", "stopped"),
        ("lxc", "running", "reboot", "high", "running"),
        ("qemu", "running", "reset", "high", "running"),
        ("qemu", "running", "suspend", "moderate", "suspended"),
        ("lxc", "suspended", "resume", "low", "running"),
    ],
)
def test_packaged_allowlist_preview_binds_guest_and_risk(
    tmp_path, kind, state, action, risk, target
):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, kind=kind, status=state)
        response = preview(client, app, admin, record, action)
        assert response.status_code == 201, response.text
        proposal = response.json()["preview"]
        assert proposal["action"] == action
        assert proposal["riskClass"] == risk
        assert proposal["requiresSecondConfirmation"] is (risk == "high")
        assert proposal["currentState"] == state
        assert proposal["expectedResultState"] == target
        assert proposal["guestKind"] == kind
        assert executor.calls == 0
        assert not any(key in str(proposal).lower() for key in ("url", "host", "node", "token", "password"))


@pytest.mark.parametrize("action", ["start", "shutdown", "stop", "reboot", "reset", "suspend", "resume"])
def test_invalid_current_state_never_creates_preview(tmp_path, action):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="unavailable")
        assert preview(client, app, admin, record, action).status_code == 409
        assert executor.calls == 0


def test_member_is_forbidden_and_default_provider_never_uses_network(tmp_path, monkeypatch):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        created = client.post(
            "/api/v1/admin/users",
            headers=auth(admin),
            json={
                "username": "member",
                "role": "member",
                "initialPassword": "Synthetic temporary password 2026",
            },
        ).json()["user"]
        assert created["role"] == "member"
        # The admin-only boundary rejects before resource/effect handling.
        from conftest import login

        member = login(client, "member", "Synthetic temporary password 2026").json()
        response = client.post(
            base(record) + "/previews",
            headers=auth(member),
            json=preview_body(app, admin, record, "start"),
        )
        assert response.status_code == 403
        assert executor.calls == 0

    empty_app, empty_settings, empty_clock, _, empty_executor = fixture(tmp_path / "empty")
    real_socket = socket.socket

    def deny_network(family=socket.AF_INET, *args, **kwargs):
        if family in (socket.AF_INET, socket.AF_INET6):
            pytest.fail("network forbidden")
        return real_socket(family, *args, **kwargs)

    monkeypatch.setattr(socket, "socket", deny_network)
    with TestClient(empty_app) as client:
        admin = ready((empty_app, client, empty_settings, empty_clock))
        record = resource(client, empty_app, admin)
        response = client.post(
            base(record) + "/previews",
            headers=auth(admin),
            json={
                "schemaVersion": 1,
                "requestId": "e" * 32,
                "action": "start",
                "expectedUserRevision": user_revision(empty_app, admin["user"]["id"]),
                "expectedResourceRevision": record["revision"],
                "expectedAclRevision": record["aclRevision"],
                "expectedBindingId": "b" * 32,
                "expectedBindingRevision": 1,
                "expectedServiceId": "s" * 32,
                "expectedServiceRevision": 1,
                "expectedGuestKind": "qemu",
                "expectedCurrentState": "stopped",
                "expectedStatusRevision": 1,
            },
        )
        assert response.status_code == 404
        assert empty_executor.calls == 0


def test_high_risk_needs_second_confirm_preview_is_one_use_and_cancel_is_final(tmp_path):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record)
        proposal = preview(client, app, admin, record, "stop").json()["preview"]
        denied = confirm(client, admin, record, proposal["id"], high=False)
        assert denied.status_code == 400
        assert executor.calls == 0
        # A failed confirmation consumes the capability.
        assert confirm(client, admin, record, proposal["id"], high=True).status_code == 409

        proposal = preview(client, app, admin, record, "stop", "e" * 32).json()["preview"]
        cancelled = client.delete(
            base(record) + f"/previews/{proposal['id']}", headers=auth(admin)
        )
        assert cancelled.status_code == 204
        assert confirm(client, admin, record, proposal["id"], "e" * 32, high=True).status_code == 409
        assert executor.calls == 0


def test_expired_preview_and_wrong_resource_path_never_execute(tmp_path):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        other = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        proposal = preview(client, app, admin, record, "start").json()["preview"]
        wrong = client.delete(
            base(other) + f"/previews/{proposal['id']}", headers=auth(admin)
        )
        assert wrong.status_code == 409
        clock.now += 61
        assert confirm(client, admin, record, proposal["id"]).status_code == 409
        assert executor.calls == 0


def test_confirm_executes_once_persists_receipt_and_adapts_to_event_payload(tmp_path):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        proposal = preview(client, app, admin, record, "start").json()["preview"]
        completed = confirm(client, admin, record, proposal["id"])
        assert completed.status_code == 200, completed.text
        receipt = completed.json()["receipt"]
        assert receipt["state"] == "succeeded"
        assert receipt["resultCode"] == "completed"
        assert receipt["guestState"] == "running"
        assert receipt["statusRevision"] == 2
        assert receipt["causalityVerified"] is False
        assert executor.calls == 1
        result = client.get(
            base(record) + "/results/" + "d" * 32, headers=auth(admin)
        )
        assert result.json()["receipt"] == receipt
        assert app.state.core.proxmox_power.receipt_event_payload("d" * 32) == {
            "schemaVersion": 1,
            "idempotencyKey": "d" * 32,
            "state": "succeeded",
            "resultCode": "completed",
        }
        assert preview(client, app, admin, record, "start").status_code == 409
        assert executor.calls == 1

    # Restart keeps the idempotency receipt and cannot replay the effect.
    second_provider = Provider(provider.descriptor)
    second_executor = Executor(second_provider)
    restarted = create_app(
        settings,
        proxmox_guest_provider=second_provider,
        proxmox_power_executor=second_executor,
    )
    with TestClient(restarted) as client:
        signed = client.post(
            "/api/v1/auth/login",
            json={
                "username": "admin",
                "password": "Synthetic new password 2026",
                "deviceName": "Restart tablet",
            },
        ).json()
        assert preview(client, restarted, signed, record, "start").status_code == 409
        assert second_executor.calls == 0


@pytest.mark.parametrize("mode", ["unknown", "late", "drift"])
def test_unknown_late_and_revision_drift_never_become_success(tmp_path, mode):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        if mode == "unknown":
            executor.outcome = "unknown"
        elif mode == "late":
            original = executor.execute

            def late(*args):
                value = original(*args)
                clock.now += 6
                return value

            executor.execute = late
        else:
            original = executor.execute

            def drift(*args):
                value = original(*args)
                provider.descriptor = replace(provider.descriptor, binding_revision=2)
                return value

            executor.execute = drift
        proposal = preview(client, app, admin, record, "start").json()["preview"]
        result = confirm(client, admin, record, proposal["id"])
        assert result.status_code == 200
        receipt = result.json()["receipt"]
        assert receipt["state"] == "unknown"
        assert receipt["resultCode"] == "outcome_uncertain"
        assert app.state.core.proxmox_power.receipt_event_payload("d" * 32)["state"] == "unknown"
        assert executor.calls == 1
        assert confirm(client, admin, record, proposal["id"]).status_code == 409


@pytest.mark.parametrize(
    "outcome,state,code",
    [("failed", "failed", "effect_failed"), ("cancelled", "cancelled", "cancelled")],
)
def test_terminal_effect_outcomes_remain_distinct(tmp_path, outcome, state, code):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        executor.outcome = outcome
        proposal = preview(client, app, admin, record, "start").json()["preview"]
        receipt = confirm(client, admin, record, proposal["id"]).json()["receipt"]
        assert (receipt["state"], receipt["resultCode"]) == (state, code)
        assert executor.calls == 1


def test_unknown_effect_keeps_only_redacted_operation_reference_in_journal(tmp_path):
    app, settings, clock, provider, executor = fixture(tmp_path)
    operation = "UPID-SHA256:" + "f" * 64
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")

        def accepted(current, action, guard):
            executor.calls += 1
            guard()
            return ProxmoxPowerEffectResult(
                "unknown", current.status, current.status_revision, operation,
            )

        executor.execute = accepted
        proposal = preview(client, app, admin, record, "start").json()["preview"]
        receipt = confirm(client, admin, record, proposal["id"]).json()["receipt"]
        assert receipt["state"] == "unknown"
        assert receipt["operationRef"] == operation
        assert journal(client, admin, record).json()["entries"][-1]["operationRef"] == operation
        assert executor.calls == 1


def test_receipt_payload_is_encrypted_and_never_contains_guest_or_action(tmp_path):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        proposal = preview(client, app, admin, record, "start").json()["preview"]
        assert confirm(client, admin, record, proposal["id"]).status_code == 200
        with app.state.core.db.connection() as connection:
            row = connection.execute(
                "SELECT nonce,ciphertext FROM proxmox_power_receipts WHERE request_id=?",
                ("d" * 32,),
            ).fetchone()
        assert len(row["nonce"]) == 12
        assert b"start" not in row["ciphertext"]
        assert b"running" not in row["ciphertext"]


def test_disconnect_guard_stops_effect_and_persists_unknown(tmp_path):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        proposal = preview(client, app, admin, record, "start").json()["preview"]
        principal = app.state.core.auth.authenticate(admin["accessToken"])
        result = app.state.core.proxmox_power.confirm(
            principal,
            record["ref"]["coreId"],
            record["ref"]["homeId"],
            record["ref"]["id"],
            proposal["id"],
            ConfirmRequest(
                schemaVersion=1,
                requestId="d" * 32,
                highRiskConfirmed=False,
                deadlineMs=5000,
            ),
            disconnected=lambda: True,
        )
        assert result["receipt"]["state"] == "unknown"
        assert provider.descriptor.status == "stopped"
        assert executor.calls == 1


def test_restart_marks_interrupted_receipt_unknown_without_replay(tmp_path):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        receipt = PowerReceipt(
            requestId="f" * 32,
            action="start",
            state="accepted",
            resultCode="accepted",
            guestState="stopped",
            statusRevision=1,
            causalityVerified=False,
            createdAt=clock.now,
            updatedAt=clock.now,
        )
        app.state.core.proxmox_power.store.put(
            receipt, record["ref"]["id"], admin["user"]["id"]
        )
    restarted_provider = Provider(descriptor(record, status="stopped"))
    restarted_executor = Executor(restarted_provider)
    restarted = create_app(
        settings,
        proxmox_guest_provider=restarted_provider,
        proxmox_power_executor=restarted_executor,
    )
    assert restarted.state.core.proxmox_power.receipt_event_payload("f" * 32) == {
        "schemaVersion": 1,
        "idempotencyKey": "f" * 32,
        "state": "unknown",
        "resultCode": "outcome_uncertain",
    }
    assert restarted_executor.calls == 0


def test_append_only_journal_covers_preview_cancel_and_command_transitions(tmp_path):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        first = preview(client, app, admin, record, "start", "1" * 32).json()["preview"]
        assert client.delete(
            base(record) + f"/previews/{first['id']}", headers=auth(admin)
        ).status_code == 204
        second = preview(client, app, admin, record, "start", "2" * 32).json()["preview"]
        receipt = confirm(client, admin, record, second["id"], "2" * 32).json()["receipt"]
        assert receipt["operationRef"] is None
        response = journal(client, admin, record)
        assert response.status_code == 200, response.text
        entries = response.json()["entries"]
        assert [entry["eventKind"] for entry in entries] == [
            "previewed", "preview_cancelled", "previewed",
            "command_status", "command_status", "command_status",
        ]
        assert [entry["state"] for entry in entries[-3:]] == [
            "accepted", "executing", "succeeded",
        ]
        for entry in entries:
            assert entry["resourceRevision"] == record["revision"]
            assert entry["aclRevision"] == record["aclRevision"]
            assert entry["userRevision"] == user_revision(app, admin["user"]["id"])
            assert entry["bindingRevision"] == 1
            assert entry["serviceRevision"] == 1
            assert entry["operationRef"] is None
            assert not any(word in str(entry).lower() for word in (
                "token", "password", "url", "host", "node",
            ))


def test_journal_integrity_is_admin_only_and_detects_live_or_restart_tamper(tmp_path):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        assert preview(client, app, admin, record, "start").status_code == 201
        integrity_path = base(record) + "/journal/integrity"
        verified = client.get(integrity_path, headers=auth(admin))
        assert verified.status_code == 200
        assert verified.json() == {
            "schemaVersion": 1,
            "verified": True,
            "eventCount": 1,
            "headHash": verified.json()["headHash"],
        }
        assert len(verified.json()["headHash"]) == 64
        created = client.post(
            "/api/v1/admin/users",
            headers=auth(admin),
            json={
                "username": "journal-member",
                "role": "member",
                "initialPassword": "Synthetic temporary password 2026",
            },
        ).json()["user"]
        assert created["role"] == "member"
        from conftest import login
        member = login(client, "journal-member", "Synthetic temporary password 2026").json()
        assert client.get(integrity_path, headers=auth(member)).status_code == 403
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE proxmox_power_journal SET result_code='effect_failed' WHERE sequence=1"
            )
        assert client.get(integrity_path, headers=auth(admin)).status_code == 503
    with pytest.raises(StartupError, match="proxmox_power_storage_invalid"):
        create_app(settings)


def test_journal_limit_is_bounded_and_unknown_never_claims_operation_reference(tmp_path):
    app, settings, clock, provider, executor = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        executor.outcome = "unknown"
        proposal = preview(client, app, admin, record, "start").json()["preview"]
        receipt = confirm(client, admin, record, proposal["id"]).json()["receipt"]
        assert receipt["state"] == "unknown"
        assert receipt["operationRef"] is None
        assert journal(client, admin, record, 0).status_code == 400
        assert journal(client, admin, record, 51).status_code == 400
        assert len(journal(client, admin, record, 2).json()["entries"]) == 2
