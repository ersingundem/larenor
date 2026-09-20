"""Immutable, view-scoped bounded-transfer event history."""

from fastapi.testclient import TestClient
import pytest

from conftest import auth, login, ready
from larenor_server.app import create_app
from larenor_server.bounded_transfer.models import BlobDescriptor
from larenor_server.errors import StartupError
from test_admin import activate, create as create_user
from test_bounded_transfer import fixture, request_body, resource


def _path(record):
    ref = record["ref"]
    return (
        f"/api/v1/home-resources/{ref['coreId']}/{ref['homeId']}/"
        f"{ref['id']}/blob"
    )


def _grant(client, admin, record, member):
    ref = record["ref"]
    response = client.put(
        f"/api/v1/admin/home-resources/{ref['coreId']}/{ref['homeId']}/"
        f"{ref['id']}/grants/{member['user']['id']}",
        headers=auth(admin),
        json={
            "expectedAclRevision": record["aclRevision"],
            "permissions": {"read": True, "write": False},
        },
    )
    assert response.status_code == 200, response.text
    grant = response.json()["grant"]
    return {**record, "aclRevision": grant["aclRevision"]}


def test_acceptance_and_result_are_distinct_events_with_one_request_id(tmp_path):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "application/octet-stream", b"event fixture"
        )
        body = request_body(app, admin, record)
        actor = app.state.core.auth.authenticate(admin["accessToken"])
        opened = app.state.core.bounded_transfers.open(
            actor,
            record["ref"]["coreId"],
            record["ref"]["homeId"],
            identity,
            **app.state.core.bounded_transfers.python_arguments(body),
            cancelled=lambda: False,
        )

        accepted = client.get(f"{_path(record)}/transfers/events?limit=1", headers=auth(admin))
        assert accepted.status_code == 200, accepted.text
        first = accepted.json()
        assert first["headSequence"] == 1
        assert first["nextAfter"] is None
        assert first["events"] == [
            {
                "sequence": 1,
                "kind": "accepted",
                "actorId": admin["user"]["id"],
                "receipt": {
                    **first["events"][0]["receipt"],
                    "requestId": body["requestId"],
                    "traceId": body["requestId"],
                    "state": "accepted",
                },
            }
        ]

        list(opened.frames)
        completed = client.get(
            f"{_path(record)}/transfers/events?after=1&limit=1",
            headers=auth(admin),
        )
        assert completed.status_code == 200, completed.text
        final = completed.json()
        assert final["chainId"] == first["chainId"]
        assert final["headSequence"] == 2
        assert final["nextAfter"] is None
        assert [(item["sequence"], item["kind"], item["receipt"]["state"])
                for item in final["events"]] == [(2, "result", "completed")]
        assert final["events"][0]["receipt"]["requestId"] == body["requestId"]


def test_event_view_is_actor_and_resource_scoped_with_canonical_cursor(tmp_path):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        create_user(client, admin)
        member = activate(client, "member")
        first = resource(client, app, admin)
        second = resource(client, app, admin)
        first = _grant(client, admin, first, member)
        for record in (first, second):
            identity = record["ref"]["id"]
            provider.blobs[identity] = BlobDescriptor(
                identity, 1, "application/octet-stream", identity.encode("ascii")
            )

        member_body = request_body(app, member, first)
        admin_body = request_body(app, admin, first)
        other_body = request_body(app, admin, second)
        assert client.post(_path(first), headers=auth(member), json=member_body).status_code == 200
        assert client.post(_path(first), headers=auth(admin), json=admin_body).status_code == 200
        assert client.post(_path(second), headers=auth(admin), json=other_body).status_code == 200

        member_view = client.get(f"{_path(first)}/transfers/events", headers=auth(member)).json()
        admin_view = client.get(f"{_path(first)}/transfers/events", headers=auth(admin)).json()
        other_view = client.get(f"{_path(second)}/transfers/events", headers=auth(admin)).json()
        assert {event["receipt"]["requestId"] for event in member_view["events"]} == {
            member_body["requestId"]
        }
        assert {event["receipt"]["requestId"] for event in admin_view["events"]} == {
            member_body["requestId"], admin_body["requestId"]
        }
        assert {event["receipt"]["requestId"] for event in other_view["events"]} == {
            other_body["requestId"]
        }
        assert len({member_view["chainId"], admin_view["chainId"], other_view["chainId"]}) == 3
        assert [event["sequence"] for event in member_view["events"]] == [1, 2]
        assert [event["sequence"] for event in admin_view["events"]] == [1, 2, 3, 4]

        ref = first["ref"]
        hidden = client.get(
            f"/api/v1/home-resources/{ref['coreId']}/{ref['homeId']}/"
            f"{'f' * 32}/blob/transfers/events",
            headers=auth(member),
        )
        assert hidden.status_code == 404
        for query in ("after=0", "after=01", "after=1&after=2", "limit=0", "unknown=1"):
            response = client.get(
                f"{_path(first)}/transfers/events?{query}", headers=auth(member)
            )
            assert response.status_code == 400
            assert response.json()["error"]["code"] == "invalid_request"


def test_restart_and_replay_do_not_fabricate_new_transfer_events(tmp_path):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "application/octet-stream", b"restart event fixture"
        )
        body = request_body(app, admin, record)
        assert client.post(_path(record), headers=auth(admin), json=body).status_code == 200
        before = client.get(
            f"{_path(record)}/transfers/events", headers=auth(admin)
        ).json()
        assert before["headSequence"] == 2

    restarted = create_app(settings, blob_provider=provider)
    with TestClient(restarted) as client:
        admin = login(client, "admin", "Synthetic new password 2026").json()
        after = client.get(
            f"{_path(record)}/transfers/events", headers=auth(admin)
        ).json()
        assert after == before
        replay = client.post(_path(record), headers=auth(admin), json=body)
        assert replay.status_code == 409
        assert replay.json()["error"]["code"] == "transfer_replay"
        final = client.get(
            f"{_path(record)}/transfers/events", headers=auth(admin)
        ).json()
        assert final == before


@pytest.mark.parametrize(
    "tamper",
    [
        "UPDATE bounded_transfer_events SET state='interrupted' WHERE sequence=1",
        "UPDATE bounded_transfer_events SET entry_hash='" + "0" * 64 + "' WHERE sequence=1",
        "UPDATE bounded_transfer_event_state SET sequence=0",
        "DELETE FROM bounded_transfer_events WHERE sequence=1",
    ],
)
def test_event_chain_tamper_blocks_restart(tmp_path, tamper):
    app, settings, clock, provider = fixture(tmp_path)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        record = resource(client, app, admin)
        identity = record["ref"]["id"]
        provider.blobs[identity] = BlobDescriptor(
            identity, 1, "application/octet-stream", b"tamper fixture"
        )
        assert client.post(
            _path(record),
            headers=auth(admin),
            json=request_body(app, admin, record),
        ).status_code == 200
        with app.state.core.db.connection() as connection:
            connection.execute(tamper)

    with pytest.raises(StartupError, match="bounded_transfer_storage_invalid"):
        create_app(settings, blob_provider=provider)
