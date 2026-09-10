"""Authority, bounded query, restart and atomic migration guarantees for F06."""
import json

import pytest
from fastapi.testclient import TestClient

from conftest import auth, bootstrap_password, login
from test_admin import activate, create as create_user
from test_home_assistant_adapter import bind, ha, setup
from test_home_assistant_commands import command_body
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.home_assistant import schema


def command_fixture(server, ha):
    app, client, actor, record, service, base, public, body = setup(server, ha)
    _, binding = bind(client, actor, base, body)
    return app, client, actor, record, service, binding, public


def grant(client, actor, ref, member, revision, *, read=True, write=True):
    path = f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}/{ref["id"]}/grants/{member["user"]["id"]}'
    response = client.put(path, headers=auth(actor), json={'expectedAclRevision': revision,
        'permissions': {'read': read, 'write': write}})
    assert response.status_code == 200, response.text


def test_history_filters_other_actors_and_rechecks_resource_acl_and_session(server, ha):
    app, client, admin, record, _, binding, public = command_fixture(server, ha)
    body = command_body(record, binding, admin)
    assert client.post(public + '/commands', headers=auth(admin), json=body).status_code == 202
    create_user(client, admin)
    member = activate(client, 'member')
    assert client.get(public + '/history', headers=auth(member)).status_code == 404
    grant(client, admin, record['ref'], member, 1)
    assert client.get(public + '/history', headers=auth(member)).json()['entries'] == []
    own_body = {**body, 'requestId': '8' * 32, 'expectedAclRevision': 2}
    assert client.post(public + '/commands', headers=auth(member), json=own_body).status_code == 202
    assert client.get(public + '/history', headers=auth(member)).json()['entries'][0]['receipt']['actorId'] == member['user']['id']
    assert len(client.get(public + '/history', headers=auth(admin)).json()['entries']) == 2
    assert client.get(public + '/history?before=' + body['requestId'], headers=auth(member)).status_code == 404
    assert client.get('/api/v1/admin/services', headers=auth(member)).status_code == 403
    counts = ha.calls, ha.command_calls
    grant(client, admin, record['ref'], member, 2, read=False, write=False)
    assert client.get(public + '/history', headers=auth(member)).status_code == 404
    assert client.post('/api/v1/auth/logout', headers=auth(admin)).status_code == 204
    assert client.get(public + '/history', headers=auth(admin)).status_code == 401
    assert (ha.calls, ha.command_calls) == counts


def test_history_requires_ready_account_and_hides_other_scope_deleted_and_room_targets(server, ha):
    app, client, settings, _ = server
    first = login(client, 'admin', bootstrap_password(settings)).json()
    scope = app.state.core.context
    fake = f'/api/v1/home-assistant/{scope.coreId}/{scope.homeId}/resources/{"f" * 32}/history'
    assert client.get(fake).status_code == 401
    assert client.get(fake, headers=auth(first)).status_code == 403
    _, client, admin, record, _, binding, public = command_fixture(server, ha)
    assert client.post(public + '/commands', headers=auth(admin), json=command_body(record, binding, admin)).status_code == 202
    counts = ha.calls, ha.command_calls
    assert client.get(public.replace(record['ref']['homeId'], 'f' * 32) + '/history', headers=auth(admin)).status_code == 404
    base = f'/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}'
    room = client.post(base, headers=auth(admin), json={'kind': 'room', 'label': 'Synthetic', 'order': 0}).json()['record']
    assert client.get(public.replace(record['ref']['id'], room['ref']['id']) + '/history', headers=auth(admin)).status_code == 404
    assert client.delete(base + '/' + record['ref']['id'], headers=auth(admin),
        params={'expectedRevision': 1, 'expectedAclRevision': 1}).status_code == 204
    assert client.get(public + '/history', headers=auth(admin)).status_code == 404
    assert (ha.calls, ha.command_calls) == counts


@pytest.mark.parametrize('query', ['limit=0', 'limit=51', 'limit=-1', 'limit=true', 'limit=01',
    'limit=1&limit=2', 'before=' + 'f' * 31, 'before=' + 'A' * 32,
    'before=' + 'f' * 32 + '&before=' + 'f' * 32, 'actorId=' + 'f' * 32, 'source=core_api'])
def test_closed_history_queries_never_reach_ha(server, ha, query):
    _, client, admin, _, _, _, public = command_fixture(server, ha)
    counts = ha.calls, ha.command_calls
    response = client.get(public + '/history?' + query, headers=auth(admin))
    assert response.status_code == 400 and response.json()['error']['code'] == 'invalid_request'
    assert (ha.calls, ha.command_calls) == counts


def test_history_has_no_mutator_and_rejects_duplicate_authorization(server, ha):
    _, client, admin, _, _, _, public = command_fixture(server, ha)
    counts = ha.calls, ha.command_calls
    for method in ('POST', 'PUT', 'PATCH', 'DELETE'):
        assert client.request(method, public + '/history', headers=auth(admin)).status_code == 405
    headers = [('Authorization', auth(admin)['Authorization'])] * 2
    assert client.get(public + '/history', headers=headers).status_code == 400
    assert (ha.calls, ha.command_calls) == counts


def test_history_pagination_is_stable_for_same_timestamp_and_does_not_expose_hidden_anchor(server, ha):
    _, client, admin, record, _, binding, public = command_fixture(server, ha)
    receipts = []
    for identity in ('7', '9', '8'):
        response = client.post(public + '/commands', headers=auth(admin),
            json=command_body(record, binding, admin, request_id=identity * 32))
        assert response.status_code == 202
        receipts.append(response.json()['receipt'])
    counts = ha.calls, ha.command_calls
    result = client.get(public + '/history?limit=2', headers=auth(admin)).json()
    assert [v['receipt']['requestId'] for v in result['entries']] == ['9' * 32, '8' * 32]
    assert result['nextBefore'] == '8' * 32
    last = client.get(public + '/history?limit=2&before=' + result['nextBefore'], headers=auth(admin)).json()
    assert [v['receipt']['requestId'] for v in last['entries']] == ['7' * 32]
    assert last['nextBefore'] is None
    assert client.get(public + '/history?before=' + 'f' * 32, headers=auth(admin)).status_code == 404
    assert (ha.calls, ha.command_calls) == counts


def test_pending_history_never_settles_or_replays_intent_and_later_result_preserves_attribution(server, ha):
    app, client, actor, record, _, binding, public = command_fixture(server, ha)
    adapter = app.state.core.home_assistant
    def crash(*args, **kwargs):
        raise SystemExit('synthetic interruption')
    adapter._commander = crash
    principal = app.state.core.auth.authenticate(actor['accessToken'])
    body = command_body(record, binding, actor)
    with pytest.raises(SystemExit):
        adapter.command(principal, record['ref']['coreId'], record['ref']['homeId'], record['ref']['id'], body)
    with app.state.core.db.connection() as c:
        before = [tuple(r) for r in schema.command_rows(c)]
    counts = ha.calls, ha.command_calls
    with TestClient(create_app(server[2])) as restarted:
        history = restarted.get(public + '/history', headers=auth(actor))
        assert history.status_code == 200
        entry = history.json()['entries'][0]
        assert entry['receipt']['dispatchState'] == 'pending' and entry['receipt']['completedAt'] is None
        with app.state.core.db.connection() as c:
            assert [tuple(r) for r in schema.command_rows(c)] == before
        result = restarted.get(public + '/commands/' + body['requestId'], headers=auth(actor))
        assert result.json()['receipt']['dispatchState'] == 'unknown'
        assert restarted.post(public + '/commands', headers=auth(actor), json=body).json() == result.json()
        assert restarted.get(public + '/history', headers=auth(actor)).json()['entries'][0]['attribution'] == entry['attribution']
    assert (ha.calls, ha.command_calls) == counts


@pytest.mark.parametrize('fault', ['ignore', 'abort', 'commit'])
def test_initial_history_persistence_failure_prevents_dispatch_and_rolls_back(server, ha, fault):
    app, client, actor, record, _, binding, public = command_fixture(server, ha)
    with app.state.core.db.transaction() as c:
        if fault == 'commit':
            c.execute('CREATE TABLE synthetic_deferred(id TEXT REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED)')
        trigger = {'ignore': 'BEFORE INSERT ON home_assistant_commands BEGIN SELECT RAISE(IGNORE); END',
            'abort': "BEFORE INSERT ON home_assistant_commands BEGIN SELECT RAISE(ABORT,'synthetic'); END",
            'commit': "AFTER INSERT ON home_assistant_commands BEGIN INSERT INTO synthetic_deferred VALUES('missing'); END"}[fault]
        c.execute('CREATE TRIGGER synthetic_fault ' + trigger)
        before = tuple(c.execute('SELECT * FROM home_assistant_state').fetchone())
    counts = ha.calls, ha.command_calls
    response = client.post(public + '/commands', headers=auth(actor), json=command_body(record, binding, actor))
    assert response.status_code == 503
    with app.state.core.db.connection() as c:
        assert schema.command_rows(c) == []
        assert tuple(c.execute('SELECT * FROM home_assistant_state').fetchone()) == before
    assert (ha.calls, ha.command_calls) == counts


def downgrade(app):
    adapter = app.state.core.home_assistant
    with app.state.core.db.transaction() as c:
        for row in schema.command_rows(c):
            value = json.loads(adapter._cipher.decrypt(row['nonce'], row['ciphertext'], adapter._command_aad(row)))
            value.pop('attribution')
            c.execute('UPDATE home_assistant_commands SET ciphertext=? WHERE request_id=?',
                (adapter._cipher.encrypt(row['nonce'], json.dumps(value).encode(), adapter._command_aad(row)), row['request_id']))
        c.execute("UPDATE metadata SET value='2' WHERE key='home_assistant_schema'")
        schema.update(c, adapter._key, adapter.resources.scope)


@pytest.mark.parametrize('fault', ['bad_tag', 'second_cipher', 'foreign_scope', 'commit'])
def test_migration_is_atomic_and_never_repairs_corrupt_legacy_records(server, ha, fault):
    app, client, actor, record, _, binding, public = command_fixture(server, ha)
    for identity in ('7', '8'):
        assert client.post(public + '/commands', headers=auth(actor),
            json=command_body(record, binding, actor, request_id=identity * 32)).status_code == 202
    downgrade(app)
    adapter = app.state.core.home_assistant
    with app.state.core.db.transaction() as c:
        if fault == 'bad_tag':
            c.execute("UPDATE home_assistant_state SET authentication_tag=?", ('0' * 64,))
        elif fault == 'second_cipher':
            c.execute('UPDATE home_assistant_commands SET ciphertext=zeroblob(16) WHERE request_id=?', ('8' * 32,))
            schema.update(c, adapter._key, adapter.resources.scope)
        elif fault == 'foreign_scope':
            row = schema.command_rows(c)[1]
            value = json.loads(adapter._cipher.decrypt(row['nonce'], row['ciphertext'], adapter._command_aad(row)))
            value['receipt']['ref']['homeId'] = 'f' * 32
            c.execute('UPDATE home_assistant_commands SET ciphertext=? WHERE request_id=?',
                (adapter._cipher.encrypt(row['nonce'], json.dumps(value).encode(), adapter._command_aad(row)), row['request_id']))
            schema.update(c, adapter._key, adapter.resources.scope)
        else:
            c.execute('CREATE TABLE synthetic_deferred(id TEXT REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED)')
            c.execute("CREATE TRIGGER synthetic_commit AFTER UPDATE ON metadata "
                "WHEN NEW.key='home_assistant_schema' AND NEW.value='3' BEGIN "
                "INSERT INTO synthetic_deferred VALUES('missing'); END")
        before = '\n'.join(c.iterdump())
    counts = ha.calls, ha.command_calls
    expected = 'storage_initialization_failed' if fault == 'commit' else 'home_assistant_storage_invalid'
    with pytest.raises(StartupError, match=expected):
        create_app(server[2])
    with app.state.core.db.connection() as c:
        assert '\n'.join(c.iterdump()) == before
    assert (ha.calls, ha.command_calls) == counts


@pytest.mark.parametrize('change', [
    {'correlationId': 'f' * 32}, {'source': 'automation'}, {'reason': 'secret-user-text'},
    {'source': 'unknown'}, {'serviceId': None}, {'schemaVersion': True},
])
def test_malformed_authenticated_attribution_fails_closed_without_echo(server, ha, change):
    app, client, actor, record, _, binding, public = command_fixture(server, ha)
    assert client.post(public + '/commands', headers=auth(actor), json=command_body(record, binding, actor)).status_code == 202
    adapter = app.state.core.home_assistant
    with app.state.core.db.transaction() as c:
        row = schema.command_rows(c)[0]
        value = json.loads(adapter._cipher.decrypt(row['nonce'], row['ciphertext'], adapter._command_aad(row)))
        value['attribution'].update(change)
        c.execute('UPDATE home_assistant_commands SET ciphertext=?',
            (adapter._cipher.encrypt(row['nonce'], json.dumps(value).encode(), adapter._command_aad(row)),))
        schema.update(c, adapter._key, adapter.resources.scope)
        saved = tuple(schema.command_rows(c)[0])
    counts = ha.calls, ha.command_calls
    response = client.get(public + '/history', headers=auth(actor))
    assert response.status_code == 503, response.text
    assert 'secret-user-text' not in response.text
    with pytest.raises(StartupError, match='home_assistant_storage_invalid'):
        create_app(server[2])
    with app.state.core.db.connection() as c:
        # The history's standard read rate-limit counter is allowed to change;
        # the authenticated command row itself must stay untouched.
        assert tuple(schema.command_rows(c)[0]) == saved
    assert (ha.calls, ha.command_calls) == counts
