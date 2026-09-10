"""F20: real Core SQLite/HTTP history and owned loopback HA only."""
from fastapi.testclient import TestClient

from conftest import auth
from test_home_assistant_adapter import bind, ha, setup
from test_home_assistant_commands import command_body
from larenor_server.app import create_app
from larenor_server.home_assistant import schema


def fixture(server, ha):
    app, client, actor, record, _, base, public, body = setup(server, ha)
    _, binding = bind(client, actor, base, body)
    scope = record['ref']
    verify = f'/api/v1/admin/home-assistant/{scope["coreId"]}/{scope["homeId"]}/history/verification'
    return app, client, actor, record, binding, public, verify


def test_command_chain_precedes_dispatch_and_verification_is_read_only(server, ha):
    app, client, actor, record, binding, public, verify = fixture(server, ha)
    initial = client.get(verify, headers=auth(actor))
    assert initial.status_code == 200, initial.text
    assert initial.json()['verification']['sequence'] == 0
    adapter = app.state.core.home_assistant
    commander = adapter._commander
    observed = []
    def capture(*args, **kwargs):
        with app.state.core.db.connection() as c:
            observed.append(c.execute('SELECT COUNT(*) FROM command_history_chain').fetchone()[0])
        return commander(*args, **kwargs)
    adapter._commander = capture
    response = client.post(public + '/commands', headers=auth(actor), json=command_body(record, binding, actor))
    assert response.status_code == 202
    assert observed == [1]
    counts = ha.calls, ha.command_calls
    result = client.get(verify, headers=auth(actor))
    assert result.status_code == 200
    proof = result.json()['verification']
    assert proof['verified'] is True and proof['sequence'] == 2
    assert proof['causalityVerified'] is False
    assert len(proof['headHash']) == 64
    assert proof['checkpoint'] != initial.json()['verification']['checkpoint']
    with app.state.core.db.connection() as c:
        before = [tuple(r) for r in c.execute('SELECT * FROM command_history_chain')]
    check = client.get(verify, headers=auth(actor), params={'checkpoint': proof['checkpoint']})
    assert check.status_code == 200 and check.json()['verification']['comparedCheckpoint'] is True
    assert check.json()['verification']['checkpoint'] == proof['checkpoint']
    with app.state.core.db.connection() as c:
        assert [tuple(r) for r in c.execute('SELECT * FROM command_history_chain')] == before
    assert (ha.calls, ha.command_calls) == counts
    assert all(secret not in result.text for secret in (ha.url, 'synthetic-ha-only',
        actor['accessToken'], actor['user']['id'], 'switch.synthetic'))


def test_current_command_deletion_fails_closed_even_with_legacy_inventory_tag_updated(server, ha):
    app, client, actor, record, binding, public, verify = fixture(server, ha)
    assert client.post(public + '/commands', headers=auth(actor), json=command_body(record, binding, actor)).status_code == 202
    adapter = app.state.core.home_assistant
    with app.state.core.db.transaction() as c:
        c.execute('DELETE FROM home_assistant_commands')
        schema.update(c, adapter._key, adapter.resources.scope)
    counts = ha.calls, ha.command_calls
    assert client.get(public + '/history', headers=auth(actor)).status_code == 503
    assert client.get(verify, headers=auth(actor)).status_code == 503
    assert (ha.calls, ha.command_calls) == counts


def test_authenticated_legacy_commands_migrate_as_baseline_without_fake_append_order(server, ha):
    app, client, actor, record, binding, public, verify = fixture(server, ha)
    response = client.post(public + '/commands', headers=auth(actor), json=command_body(record, binding, actor))
    assert response.status_code == 202
    with app.state.core.db.transaction() as c:
        for name in ('command_history_chain', 'command_history_state'):
            c.execute('DROP TABLE IF EXISTS ' + name)
        c.execute("DELETE FROM metadata WHERE key='command_history_schema'")
    counts = ha.calls, ha.command_calls
    with TestClient(create_app(server[2])) as restarted:
        result = restarted.get(verify, headers=auth(actor))
        assert result.status_code == 200
        assert result.json()['verification']['sequence'] == 1
        with restarted.app.state.core.db.connection() as c:
            assert c.execute('SELECT kind FROM command_history_chain').fetchone()[0] == 'baseline'
        assert restarted.get(public + '/commands/' + '9' * 32, headers=auth(actor)).json() == response.json()
    assert (ha.calls, ha.command_calls) == counts
