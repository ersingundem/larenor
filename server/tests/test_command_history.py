"""F06: actual Core command persistence/query with an owned loopback HA fixture."""
import json

from fastapi.testclient import TestClient

from conftest import auth
from test_home_assistant_adapter import bind, ha, setup
from test_home_assistant_commands import command_body
from larenor_server.app import create_app
from larenor_server.home_assistant import schema


def stored(app):
    adapter = app.state.core.home_assistant
    with app.state.core.db.connection() as c:
        row = c.execute('SELECT * FROM home_assistant_commands').fetchone()
    return json.loads(adapter._cipher.decrypt(row['nonce'], row['ciphertext'], adapter._command_aad(row)))


def test_history_correlates_durable_actor_source_reason_service_and_result(server, ha):
    app, client, actor, record, service, base, public, body = setup(server, ha)
    _, binding = bind(client, actor, base, body)
    payload = command_body(record, binding, actor)
    adapter = app.state.core.home_assistant
    commander = adapter._commander
    before_dispatch = []

    def capture(*args, **kwargs):
        before_dispatch.append(stored(app))
        return commander(*args, **kwargs)

    adapter._commander = capture
    response = client.post(public + '/commands', headers=auth(actor), json=payload)
    assert response.status_code == 202, response.text
    query = client.get(public + '/history', headers=auth(actor))
    assert query.status_code == 200, query.text
    expected = {'schemaVersion': 1, 'correlationId': payload['requestId'],
        'source': 'core_api', 'reason': 'explicit_command_request',
        'serviceId': service['id'], 'serviceRevision': 1}
    assert before_dispatch[0]['attribution'] == expected
    assert before_dispatch[0]['receipt']['dispatchState'] == 'pending'
    assert query.json() == {'schemaVersion': 1, 'ref': record['ref'],
        'entries': [{'attribution': expected, 'receipt': response.json()['receipt']}], 'nextBefore': None}
    assert query.json()['entries'][0]['receipt']['actorId'] == actor['user']['id']
    assert query.json()['entries'][0]['receipt']['causalityVerified'] is False
    assert query.headers['cache-control'] == 'no-store'
    assert client.post(public + '/commands', headers=auth(actor), json=payload).json() == response.json()
    assert ha.command_calls == 1
    assert stored(app)['attribution'] == expected
    assert all(secret not in query.text for secret in ('synthetic-ha-only', ha.url,
        'switch.synthetic', 'NEVER-PUBLISH-ATTRIBUTES', actor['accessToken']))


def test_history_read_after_restart_is_no_dispatch_and_no_record_mutation(server, ha):
    app, client, actor, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, actor, base, body)
    payload = command_body(record, binding, actor)
    assert client.post(public + '/commands', headers=auth(actor), json=payload).status_code == 202
    first = client.get(public + '/history', headers=auth(actor))
    assert first.status_code == 200
    with app.state.core.db.connection() as c:
        before = [tuple(row) for row in schema.command_rows(c)]
    counters = ha.calls, ha.command_calls
    with TestClient(create_app(server[2])) as restarted:
        assert restarted.get(public + '/history', headers=auth(actor)).json() == first.json()
    with app.state.core.db.connection() as c:
        assert [tuple(row) for row in schema.command_rows(c)] == before
    assert (ha.calls, ha.command_calls) == counters


def test_v2_migration_preserves_existing_receipt_without_inventing_attribution(server, ha):
    app, client, actor, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, actor, base, body)
    payload = command_body(record, binding, actor)
    response = client.post(public + '/commands', headers=auth(actor), json=payload)
    assert response.status_code == 202
    adapter = app.state.core.home_assistant
    with app.state.core.db.transaction() as c:
        row = c.execute('SELECT * FROM home_assistant_commands').fetchone()
        value = json.loads(adapter._cipher.decrypt(row['nonce'], row['ciphertext'], adapter._command_aad(row)))
        value.pop('attribution', None)
        c.execute('UPDATE home_assistant_commands SET ciphertext=?',
            (adapter._cipher.encrypt(row['nonce'], json.dumps(value).encode(), adapter._command_aad(row)),))
        c.execute("UPDATE metadata SET value='2' WHERE key='home_assistant_schema'")
        schema.update(c, adapter._key, app.state.core.home_resources.scope)
    counters = ha.calls, ha.command_calls
    with TestClient(create_app(server[2])) as restarted:
        with restarted.app.state.core.db.connection() as c:
            assert c.execute("SELECT value FROM metadata WHERE key='home_assistant_schema'").fetchone()[0] == '3'
        query = restarted.get(public + '/history', headers=auth(actor))
        assert query.status_code == 200
        assert query.json()['entries'] == [{'receipt': response.json()['receipt'], 'attribution': {
            'schemaVersion': 1, 'correlationId': payload['requestId'], 'source': 'unknown',
            'reason': 'unknown', 'serviceId': None, 'serviceRevision': None}}]
        assert restarted.post(public + '/commands', headers=auth(actor), json=payload).json() == response.json()
    assert (ha.calls, ha.command_calls) == counters
