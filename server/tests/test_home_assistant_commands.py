"""Durable, idempotent switch commands through owned loopback HA only."""
import pytest
from fastapi.testclient import TestClient

from conftest import auth
from test_admin import activate, create as create_user
from test_home_assistant_adapter import bind, ha, setup
from larenor_server.app import create_app
from larenor_server.errors import ApiError, StartupError
from larenor_server.home_assistant import schema


def command_body(record, binding, actor, *, request_id='9' * 32, action='turn_on'):
    return {
        'schemaVersion': 1,
        'requestId': request_id,
        'action': action,
        'expectedBindingRevision': binding['revision'],
        'expectedResourceRevision': record['revision'],
        'expectedAclRevision': record['aclRevision'],
    }


def test_command_is_persisted_before_one_dispatch_and_same_request_is_idempotent(server, ha):
    app, client, admin, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    payload = command_body(record, binding, admin)

    first = client.post(public + '/commands', headers=auth(admin), json=payload)
    assert first.status_code == 202, first.text
    receipt = first.json()['receipt']
    assert receipt == {
        'schemaVersion': 1,
        'requestId': '9' * 32,
        'ref': record['ref'],
        'bindingId': binding['id'],
        'bindingRevision': 1,
        'actorId': admin['user']['id'],
        'action': 'turn_on',
        'dispatchState': 'accepted',
        'providerAccepted': True,
        'observedProjection': {'kind': 'switch', 'state': 'on', 'commandAvailable': False},
        'observationMatchesTarget': True,
        'causalityVerified': False,
        'createdAt': receipt['createdAt'],
        'completedAt': receipt['completedAt'],
    }
    assert receipt['createdAt'].endswith('Z') and receipt['completedAt'].endswith('Z')
    assert ha.command_calls == 1
    assert ha.calls == 2

    repeated = client.post(public + '/commands', headers=auth(admin), json=payload)
    assert repeated.status_code == 202 and repeated.json() == first.json()
    fetched = client.get(public + '/commands/' + '9' * 32, headers=auth(admin))
    assert fetched.status_code == 200 and fetched.json() == first.json()
    assert ha.command_calls == 1

    conflict = client.post(public + '/commands', headers=auth(admin),
        json={**payload, 'action': 'turn_off'})
    assert conflict.status_code == 409
    assert conflict.json()['error']['code'] == 'ha_command_conflict'
    assert ha.command_calls == 1

    with app.state.core.db.connection() as c:
        row = c.execute('SELECT * FROM home_assistant_commands').fetchone()
        assert row is not None
        raw = str(dict(row))
        assert all(value not in raw for value in ('switch.synthetic', 'turn_on', admin['user']['id']))


def test_command_requires_current_write_acl_and_never_dispatches_when_denied(server, ha):
    _, client, admin, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    create_user(client, admin)
    member = activate(client, 'member')
    ref = record['ref']
    grant = f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}/{ref["id"]}/grants/{member["user"]["id"]}'
    assert client.put(grant, headers=auth(admin), json={'expectedAclRevision': 1,
        'permissions': {'read': True, 'write': False}}).status_code == 200

    payload = command_body({**record, 'aclRevision': 2}, binding, member)
    denied = client.post(public + '/commands', headers=auth(member), json=payload)
    assert denied.status_code == 403
    assert ha.command_calls == 0
    assert client.get(public + '/commands/' + payload['requestId'], headers=auth(member)).status_code == 404

    assert client.put(grant, headers=auth(admin), json={'expectedAclRevision': 2,
        'permissions': {'read': True, 'write': True}}).status_code == 200
    allowed = client.post(public + '/commands', headers=auth(member),
        json={**payload, 'expectedAclRevision': 3})
    assert allowed.status_code == 202
    assert allowed.json()['receipt']['actorId'] == member['user']['id']
    assert ha.command_calls == 1


def test_provider_rejection_is_a_durable_result_and_is_never_replayed(server, ha):
    _, client, admin, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    ha.command_status = 401
    payload = command_body(record, binding, admin)
    response = client.post(public + '/commands', headers=auth(admin), json=payload)
    assert response.status_code == 202
    receipt = response.json()['receipt']
    assert receipt['dispatchState'] == 'rejected'
    assert receipt['providerAccepted'] is False
    assert receipt['observedProjection'] is None
    assert receipt['observationMatchesTarget'] is None
    assert ha.command_calls == 1
    assert client.post(public + '/commands', headers=auth(admin), json=payload).json() == response.json()
    assert ha.command_calls == 1


def test_v1_binding_storage_migrates_to_v2_without_losing_the_binding(server, ha):
    app, client, admin, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    with app.state.core.db.transaction() as c:
        c.execute('DROP TABLE home_assistant_commands')
        c.execute("UPDATE metadata SET value='1' WHERE key='home_assistant_schema'")
        c.execute('UPDATE home_assistant_state SET authentication_tag=?',
                  (schema._tag_v1(app.state.core.home_assistant._key,
                                  app.state.core.home_resources.scope, schema.rows(c)),))

    restarted = create_app(server[2])
    with restarted.state.core.db.connection() as c:
        assert c.execute("SELECT value FROM metadata WHERE key='home_assistant_schema'").fetchone()[0] == '2'
        assert c.execute('SELECT COUNT(*) FROM home_assistant_bindings').fetchone()[0] == 1
        assert c.execute('SELECT COUNT(*) FROM home_assistant_commands').fetchone()[0] == 0
    assert restarted.state.core.home_assistant.binding(
        restarted.state.core.auth.authenticate(admin['accessToken']),
        record['ref']['coreId'], record['ref']['homeId'], record['ref']['id'])['binding'] == binding


def test_indeterminate_transport_is_saved_unknown_and_duplicate_never_dispatches(server, ha):
    app, client, admin, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    calls = []
    app.state.core.home_assistant._commander = lambda *args, **kwargs: calls.append(args) or None
    payload = command_body(record, binding, admin)
    first = client.post(public + '/commands', headers=auth(admin), json=payload)
    assert first.status_code == 202
    assert first.json()['receipt']['dispatchState'] == 'unknown'
    assert first.json()['receipt']['providerAccepted'] is None
    assert first.json()['receipt']['observedProjection'] is None
    assert len(calls) == 1
    assert client.post(public + '/commands', headers=auth(admin), json=payload).json() == first.json()
    assert len(calls) == 1


def test_interrupted_pending_intent_becomes_unknown_after_restart_without_dispatch(server, ha):
    app, client, admin, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    adapter = app.state.core.home_assistant
    calls = []
    def interrupted(*args, **kwargs):
        calls.append(args)
        raise SystemExit('synthetic process loss')
    adapter._commander = interrupted
    principal = app.state.core.auth.authenticate(admin['accessToken'])
    with pytest.raises(SystemExit):
        adapter.command(principal, record['ref']['coreId'], record['ref']['homeId'],
                        record['ref']['id'], command_body(record, binding, admin))
    assert len(calls) == 1

    restarted = create_app(server[2])
    with TestClient(restarted) as other:
        result = other.get(public + '/commands/' + '9' * 32, headers=auth(admin))
        assert result.status_code == 200
        assert result.json()['receipt']['dispatchState'] == 'unknown'
        assert result.json()['receipt']['providerAccepted'] is None
        assert other.post(public + '/commands', headers=auth(admin),
                          json=command_body(record, binding, admin)).json() == result.json()
    assert len(calls) == 1


def test_tampered_command_storage_fails_closed_without_rewriting_database(server, ha):
    app, client, admin, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    assert client.post(public + '/commands', headers=auth(admin),
                       json=command_body(record, binding, admin)).status_code == 202
    with app.state.core.db.transaction() as c:
        c.execute('UPDATE home_assistant_commands SET ciphertext=zeroblob(16)')
    with app.state.core.db.connection() as c:
        before = '\n'.join(c.iterdump())
    with pytest.raises(StartupError, match='home_assistant_storage_invalid'):
        create_app(server[2])
    with app.state.core.db.connection() as c:
        assert '\n'.join(c.iterdump()) == before


@pytest.mark.parametrize('change', [
    {'schemaVersion': True}, {'requestId': 'A' * 32}, {'action': 'toggle'},
    {'expectedBindingRevision': 0}, {'expectedResourceRevision': 0},
    {'expectedAclRevision': 0}, {'extra': 'forbidden'},
])
def test_invalid_command_body_never_dispatches(server, ha, change):
    _, client, admin, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    payload = {**command_body(record, binding, admin), **change}
    assert client.post(public + '/commands', headers=auth(admin), json=payload).status_code == 400
    assert ha.command_calls == 0


def test_write_revocation_before_transport_guard_prevents_dispatch_and_leaves_unknown_receipt(server, ha):
    app, client, admin, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    create_user(client, admin)
    member = activate(client, 'member')
    ref = record['ref']
    grant = f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}/{ref["id"]}/grants/{member["user"]["id"]}'
    assert client.put(grant, headers=auth(admin), json={'expectedAclRevision': 1,
        'permissions': {'read': True, 'write': True}}).status_code == 200
    payload = command_body({**record, 'aclRevision': 2}, binding, member)
    adapter = app.state.core.home_assistant
    def revoke_then_guard(service, entity, action, *, guard):
        assert client.put(grant, headers=auth(admin), json={'expectedAclRevision': 2,
            'permissions': {'read': True, 'write': False}}).status_code == 200
        guard()
        pytest.fail('stale WRITE authority reached dispatch')
    adapter._commander = revoke_then_guard
    principal = app.state.core.auth.authenticate(member['accessToken'])
    with pytest.raises(ApiError, match='ha_binding_changed'):
        adapter.command(principal, ref['coreId'], ref['homeId'], ref['id'], payload)
    assert ha.command_calls == 0
    result = client.get(public + '/commands/' + payload['requestId'], headers=auth(member))
    assert result.status_code == 200
    assert result.json()['receipt']['dispatchState'] == 'unknown'


def test_request_id_collision_from_another_actor_is_hidden_and_never_dispatches(server, ha):
    _, client, admin, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, admin, base, body)
    assert client.post(public + '/commands', headers=auth(admin),
                       json=command_body(record, binding, admin)).status_code == 202
    create_user(client, admin)
    member = activate(client, 'member')
    ref = record['ref']
    grant = f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}/{ref["id"]}/grants/{member["user"]["id"]}'
    assert client.put(grant, headers=auth(admin), json={'expectedAclRevision': 1,
        'permissions': {'read': True, 'write': True}}).status_code == 200
    collision = client.post(public + '/commands', headers=auth(member),
        json=command_body({**record, 'aclRevision': 2}, binding, member))
    assert collision.status_code == 404
    assert ha.command_calls == 1
