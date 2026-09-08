"""Durable, idempotent switch commands through owned loopback HA only."""
from conftest import auth
from test_admin import activate, create as create_user
from test_home_assistant_adapter import bind, ha, setup


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
        'causalityVerified': False,
        'createdAt': receipt['createdAt'],
        'completedAt': receipt['completedAt'],
    }
    assert receipt['createdAt'].endswith('Z') and receipt['completedAt'].endswith('Z')
    assert ha.command_calls == 1

    repeated = client.post(public + '/commands', headers=auth(admin), json=payload)
    assert repeated.status_code == 202 and repeated.json() == first.json()
    fetched = client.get(public + '/commands/' + '9' * 32, headers=auth(admin))
    assert fetched.status_code == 200 and fetched.json() == first.json()
    assert ha.command_calls == 1

    conflict = client.post(public + '/commands', headers=auth(admin),
        json={**payload, 'action': 'turn_off'})
    assert conflict.status_code == 409
    assert conflict.json()['code'] == 'ha_command_conflict'
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
    assert ha.command_calls == 1
    assert client.post(public + '/commands', headers=auth(admin), json=payload).json() == response.json()
    assert ha.command_calls == 1
