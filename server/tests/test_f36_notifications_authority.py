"""F36 current-member authority and the durable F54 completion handoff."""

import uuid

from conftest import auth, ready
from test_admin import activate, create as create_user


def _root(app):
    scope = app.state.core.context
    return f"/api/v1/fair-chores/{scope.coreId}/{scope.homeId}"


def _notification_root(app):
    scope = app.state.core.context
    return f"/api/v1/local-notifications/{scope.coreId}/{scope.homeId}"


def _create(client, actor, root, clock, *, command="1" * 32):
    page = client.get(root, headers=auth(actor)).json()
    response = client.post(
        root,
        headers=auth(actor),
        json={
            "schemaVersion": 2,
            "commandId": command,
            "expectedMembersRevision": page["authority"]["membersRevision"],
            "title": "Clean kitchen",
            "timezone": "Europe/Istanbul",
            "intervalDays": 7,
            "dueAt": clock() + 3600,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()["task"]


def _register(client, actor, root, clock):
    response = client.post(
        root + "/subscriptions",
        headers=auth(actor),
        json={
            "schemaVersion": 1,
            "registrationId": uuid.uuid4().hex,
            "permission": "granted",
            "expiresAt": clock() + 3600,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()["subscription"]


def test_completion_hands_next_assignee_one_private_f54_event_and_replay_is_exact(
    server,
):
    app, client, _settings, clock = server
    admin = ready(server)
    create_user(client, admin)
    member = activate(client, "member")
    root = _root(app)
    notification_root = _notification_root(app)
    subscriptions = {
        admin["user"]["id"]: (admin, _register(client, admin, notification_root, clock)),
        member["user"]["id"]: (
            member,
            _register(client, member, notification_root, clock),
        ),
    }
    task = _create(client, admin, root, clock)
    authority = client.get(root, headers=auth(admin)).json()["authority"]
    body = {
        "schemaVersion": 2,
        "commandId": "2" * 32,
        "expectedRevision": task["revision"],
        "expectedMembersRevision": authority["membersRevision"],
        "completedAt": clock() + 30 * 86400,
    }

    response = client.post(
        f"{root}/{task['id']}/commands/complete",
        headers=auth(admin),
        json=body,
    )
    assert response.status_code == 200, response.text
    assignee = response.json()["task"]["assigneeId"]
    assert assignee != task["assigneeId"]
    replay = client.post(
        f"{root}/{task['id']}/commands/complete",
        headers=auth(admin),
        json=body,
    )
    assert replay.status_code == 200
    assert replay.json() == response.json()

    recipient, subscription = subscriptions[assignee]
    events = client.get(
        notification_root
        + f"/subscriptions/{subscription['ref']['id']}/events",
        headers=auth(recipient),
        params={"expectedRevision": subscription["revision"]},
    ).json()["events"]
    assert len(events) == 1
    assert events[0]["category"] == "fair_chore"
    assert events[0]["sensitivity"] == "private"
    assert events[0]["target"] == "/chores"
    assert events[0]["publicProjection"] == {
        "title": "Larenor",
        "body": "",
        "target": None,
        "redacted": True,
    }
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM fair_chore_events WHERE action='completed'"
        ).fetchone()[0] == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM local_notification_events"
        ).fetchone()[0] == 1


def test_stale_member_authority_and_revocation_inside_notification_roll_back(server, monkeypatch):
    app, client, _settings, clock = server
    admin = ready(server)
    user = create_user(client, admin)
    activate(client, "member")
    root = _root(app)
    before = client.get(root, headers=auth(admin)).json()["authority"]

    create_user(client, admin, "late-member")
    activate(client, "late-member")
    stale = client.post(
        root,
        headers=auth(admin),
        json={
            "schemaVersion": 2,
            "commandId": "3" * 32,
            "expectedMembersRevision": before["membersRevision"],
            "title": "Stale authority",
            "timezone": "Europe/Istanbul",
            "intervalDays": 1,
            "dueAt": clock() + 3600,
        },
    )
    assert stale.status_code == 409, stale.text

    task = _create(client, admin, root, clock, command="4" * 32)
    authority = client.get(root, headers=auth(admin)).json()["authority"]
    writer = app.state.core.local_notifications
    append = writer.append_internal

    def revoke_after_append(connection, value):
        result = append(connection, value)
        connection.execute(
            "UPDATE users SET disabled=1,revision=revision+1 WHERE id=?",
            (user["id"],),
        )
        return result

    monkeypatch.setattr(writer, "append_internal", revoke_after_append)
    failed = client.post(
        f"{root}/{task['id']}/commands/complete",
        headers=auth(admin),
        json={
            "schemaVersion": 2,
            "commandId": "5" * 32,
            "expectedRevision": task["revision"],
            "expectedMembersRevision": authority["membersRevision"],
            "completedAt": clock(),
        },
    )
    assert failed.status_code in {401, 409}, failed.text
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT revision FROM fair_chore_tasks WHERE id=?", (task["id"],)
        ).fetchone()[0] == 1
        assert connection.execute(
            "SELECT COUNT(*) FROM local_notification_events"
        ).fetchone()[0] == 0
        assert connection.execute(
            "SELECT disabled FROM users WHERE id=?", (user["id"],)
        ).fetchone()[0] == 0


def test_list_revalidates_session_after_ledger_read(server, monkeypatch):
    app, client, _settings, clock = server
    admin = ready(server)
    root = _root(app)
    _create(client, admin, root, clock)
    actual = app.state.core.fair_chores.store.list

    def list_then_revoke(*args, **kwargs):
        result = actual(*args, **kwargs)
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE session_families SET revoked_at=? WHERE id=?",
                (clock(), admin["sessionFamilyId"]),
            )
        return result

    monkeypatch.setattr(app.state.core.fair_chores.store, "list", list_then_revoke)
    response = client.get(root, headers=auth(admin))
    assert response.status_code == 401
    assert "tasks" not in response.json()


def test_household_over_the_rotation_limit_is_a_bounded_error(server):
    app, client, settings, clock = server
    admin = ready(server)
    with app.state.core.db.transaction() as connection:
        encoded = connection.execute('SELECT password_hash FROM users WHERE id=?',
                                     (admin['user']['id'],)).fetchone()[0]
        connection.executemany(
            "INSERT INTO users(id,username,role,password_hash,must_change_password,created_at) "
            "VALUES(?,?,'member',?,0,?)",
            [(uuid.uuid4().hex, f'large-house-{index}', encoded, clock()) for index in range(32)],
        )
    response = client.get(_root(app), headers=auth(admin))
    assert response.status_code == 413
    assert response.json()['error']['code'] == 'fair_chore_members_limit_reached'
    with app.state.core.db.connection() as connection:
        assert connection.execute('SELECT COUNT(*) FROM fair_chore_tasks').fetchone()[0] == 0
