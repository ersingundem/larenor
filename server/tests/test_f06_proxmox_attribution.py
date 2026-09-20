import json

import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.proxmox_commands.models import PowerReceipt

from conftest import auth, login, ready
from test_proxmox_power_commands import (
    Executor,
    Provider,
    base,
    confirm,
    descriptor,
    fixture,
    preview,
    resource,
    user_revision,
)


def test_attributed_journal_closes_actor_service_command_and_result(tmp_path):
    app, settings, clock, provider, _ = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        proposal = preview(client, app, admin, record, "start").json()["preview"]
        assert confirm(client, admin, record, proposal["id"]).status_code == 200

        response = client.get(
            base(record) + "/journal/attributed", headers=auth(admin)
        )
        assert response.status_code == 200, response.text
        value = response.json()
        assert set(value) == {"schemaVersion", "ref", "entries", "verified"}
        assert value["schemaVersion"] == 1 and value["verified"] is True
        assert value["ref"] == record["ref"]
        assert [event["state"] for event in value["entries"]] == [
            "previewed",
            "accepted",
            "executing",
            "succeeded",
        ]
        for sequence, event in enumerate(value["entries"], 1):
            assert set(event) == {
                "schemaVersion",
                "sequence",
                "attribution",
                "eventKind",
                "requestId",
                "action",
                "state",
                "resultCode",
                "userRevision",
                "resourceRevision",
                "aclRevision",
                "bindingRevision",
                "serviceRevision",
                "statusRevision",
                "operationRef",
                "emittedAt",
            }
            assert event["sequence"] == sequence
            assert event["requestId"] == "d" * 32
            assert event["action"] == "start"
            assert event["attribution"]["correlationId"] == event["requestId"]
            assert event["attribution"]["actorId"] == admin["user"]["id"]
            assert event["attribution"]["serviceId"] == "s" * 32
            assert event["attribution"]["serviceRevision"] == 1
            assert event["attribution"]["source"] == "core_api"
            expected_reason = (
                "explicit_admin_preview"
                if event["eventKind"] == "previewed"
                else "explicit_admin_confirmation"
            )
            assert event["attribution"]["reason"] == expected_reason
        assert not any(
            secret in response.text.lower()
            for secret in ("token", "password", "host", "node", "url")
        )


def test_restart_is_factual_while_legacy_attribution_remains_unknown(tmp_path):
    app, settings, clock, provider, _ = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        common = {
            "action": "start",
            "guestState": "stopped",
            "statusRevision": 1,
            "userRevision": user_revision(app, admin["user"]["id"]),
            "resourceRevision": record["revision"],
            "aclRevision": record["aclRevision"],
            "bindingRevision": 1,
            "serviceRevision": 1,
            "operationRef": None,
            "causalityVerified": False,
            "createdAt": clock.now,
            "updatedAt": clock.now,
        }
        interrupted = PowerReceipt(
            requestId="a" * 32,
            state="accepted",
            resultCode="accepted",
            **common,
        )
        app.state.core.proxmox_power.store.put(
            interrupted,
            record["ref"]["id"],
            admin["user"]["id"],
            service_id="s" * 32,
            source="core_api",
            reason="explicit_admin_confirmation",
        )
        legacy = PowerReceipt(
            requestId="b" * 32,
            state="succeeded",
            resultCode="completed",
            **common,
        )
        app.state.core.proxmox_power.store.put(
            legacy, record["ref"]["id"], admin["user"]["id"]
        )
        before = client.get(
            base(record) + "/journal/attributed", headers=auth(admin)
        ).json()["entries"]
        legacy_event = next(row for row in before if row["requestId"] == "b" * 32)
        assert legacy_event["attribution"] == {
            "schemaVersion": 1,
            "correlationId": "b" * 32,
            "actorId": admin["user"]["id"],
            "source": "unknown",
            "reason": "unknown",
            "serviceId": None,
            "serviceRevision": None,
        }

    restarted = create_app(
        settings,
        proxmox_guest_provider=Provider(provider.descriptor),
        proxmox_power_executor=Executor(Provider(provider.descriptor)),
    )
    with TestClient(restarted) as client:
        response = client.get(
            base(record) + "/journal/attributed", headers=auth(admin)
        )
        assert response.status_code == 200, response.text
        events = response.json()["entries"]
        recovery = [row for row in events if row["requestId"] == "a" * 32][-1]
        assert recovery["state"] == "unknown"
        assert recovery["resultCode"] == "outcome_uncertain"
        assert recovery["attribution"]["source"] == "core_recovery"
        assert recovery["attribution"]["reason"] == "interrupted_after_restart"
        assert recovery["attribution"]["serviceId"] == "s" * 32
        assert "nearby" not in json.dumps(events).lower()


def test_attributed_journal_is_scope_isolated_and_tamper_evident(tmp_path):
    app, settings, clock, provider, _ = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        other = resource(client, app, admin)
        provider.descriptor = descriptor(record, status="stopped")
        assert preview(client, app, admin, record, "start").status_code == 201
        path = base(record) + "/journal/attributed"

        assert client.get(path).status_code == 401
        created = client.post(
            "/api/v1/admin/users",
            headers=auth(admin),
            json={
                "username": "f06-member",
                "role": "member",
                "initialPassword": "Synthetic temporary password 2026",
            },
        )
        assert created.status_code == 201
        member = login(
            client, "f06-member", "Synthetic temporary password 2026"
        ).json()
        assert client.get(path, headers=auth(member)).status_code == 403
        assert (
            client.get(
                base(other) + "/journal/attributed", headers=auth(admin)
            ).json()["entries"]
            == []
        )
        wrong_home = path.replace(record["ref"]["homeId"], "f" * 32)
        assert client.get(wrong_home, headers=auth(admin)).status_code == 404

        deleted = client.delete(
            "/api/v1/admin/home-resources/"
            f"{record['ref']['coreId']}/{record['ref']['homeId']}/"
            f"{record['ref']['id']}?expectedRevision=1&expectedAclRevision=1",
            headers=auth(admin),
        )
        assert deleted.status_code == 204
        assert client.get(path, headers=auth(admin)).status_code == 404

        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE proxmox_power_attribution SET reason='unknown' "
                "WHERE sequence=1"
            )
        assert (
            client.get(
                base(other) + "/journal/attributed", headers=auth(admin)
            ).status_code
            == 503
        )

    with pytest.raises(StartupError, match="proxmox_power_storage_invalid"):
        create_app(settings)
