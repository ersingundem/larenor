"""Tampering, retained checkpoints and bounded failure/authority paths."""
import base64
import json
import sqlite3
from contextlib import contextmanager

import pytest
from fastapi.testclient import TestClient

from conftest import auth, bootstrap_password, login
from test_admin import activate, create as create_user
from test_home_assistant_adapter import ha
from test_home_assistant_commands import command_body
from test_command_history_integrity import fixture
from larenor_server.app import create_app
from larenor_server.database import Database
from larenor_server.errors import StartupError
from larenor_server.home_assistant import command_chain as chain


def completed(server, ha):
    values = fixture(server, ha)
    app, client, actor, record, binding, public, verify = values
    assert client.post(public + '/commands', headers=auth(actor), json=command_body(record, binding, actor)).status_code == 202
    return values


@pytest.mark.parametrize('sql', [
    'DELETE FROM command_history_chain WHERE sequence=1',
    'DELETE FROM command_history_chain WHERE sequence=2',
    "UPDATE command_history_chain SET previous_hash='" + 'f' * 64 + "' WHERE sequence=2",
    'UPDATE command_history_chain SET ciphertext=zeroblob(16) WHERE sequence=1',
    'UPDATE command_history_chain SET sequence=sequence+5',
    "UPDATE command_history_chain SET kind='baseline' WHERE sequence=2",
    "UPDATE command_history_state SET authentication_tag='" + 'f' * 64 + "'",
    'DELETE FROM command_history_state',
    'CREATE UNIQUE INDEX renamed_index ON command_history_chain(request_id,sequence)',
    "CREATE TRIGGER renamed_trigger BEFORE INSERT ON command_history_chain BEGIN SELECT RAISE(IGNORE); END",
])
def test_tampered_chain_blocks_reads_writes_and_restart_without_cleanup(server, ha, sql):
    app, client, actor, record, binding, public, verify = completed(server, ha)
    with app.state.core.db.transaction() as c:
        c.execute(sql)
    counts = ha.calls, ha.command_calls
    assert client.get(verify, headers=auth(actor)).status_code == 503
    assert client.get(public + '/history', headers=auth(actor)).status_code == 503
    assert client.post(public + '/commands', headers=auth(actor),
        json=command_body(record, binding, actor, request_id='8' * 32)).status_code == 503
    with pytest.raises(StartupError, match='home_assistant_storage_invalid'):
        create_app(server[2])
    # Read rate-limit writes are expected. Capture after them to prove restart
    # never repairs, deletes or recreates tampered history.
    with app.state.core.db.connection() as c:
        after = '\n'.join(c.iterdump())
    with pytest.raises(StartupError):
        create_app(server[2])
    with app.state.core.db.connection() as c:
        assert '\n'.join(c.iterdump()) == after
    assert (ha.calls, ha.command_calls) == counts


def test_actual_reordering_is_not_hidden_by_complete_row_inventory(server, ha):
    app, client, actor, _, _, _, verify = completed(server, ha)
    with app.state.core.db.transaction() as c:
        c.execute('UPDATE command_history_chain SET sequence=9 WHERE sequence=1')
        c.execute('UPDATE command_history_chain SET sequence=1 WHERE sequence=2')
        c.execute('UPDATE command_history_chain SET sequence=2 WHERE sequence=9')
    assert client.get(verify, headers=auth(actor)).status_code == 503


def snapshot(c):
    return {name: [tuple(row) for row in c.execute('SELECT * FROM ' + name)] for name in
        ('home_assistant_commands', 'home_assistant_state', 'command_history_chain', 'command_history_state')}


def test_external_checkpoint_detects_whole_valid_rollback_and_old_prefix_remains_verifiable(server, ha):
    app, client, actor, record, binding, public, verify = completed(server, ha)
    first = client.get(verify, headers=auth(actor)).json()['verification']
    with app.state.core.db.connection() as c:
        old = snapshot(c)
    assert client.post(public + '/commands', headers=auth(actor),
        json=command_body(record, binding, actor, request_id='8' * 32)).status_code == 202
    newest = client.get(verify, headers=auth(actor), params={'checkpoint': first['checkpoint']})
    assert newest.status_code == 200 and newest.json()['verification']['sequence'] == 4
    retained = newest.json()['verification']['checkpoint']
    with app.state.core.db.transaction() as c:
        for name, rows in old.items():
            c.execute('DELETE FROM ' + name)
            for row in rows:
                c.execute('INSERT INTO ' + name + ' VALUES(' + ','.join('?' for _ in row) + ')', row)
    counts = ha.calls, ha.command_calls
    with TestClient(create_app(server[2])) as restarted:
        local = restarted.get(verify, headers=auth(actor))
        assert local.status_code == 200 and local.json()['verification']['sequence'] == 2
        checked = restarted.get(verify, headers=auth(actor), params={'checkpoint': retained})
        assert checked.status_code == 409 and checked.json()['error']['code'] == 'revision_conflict'
        assert restarted.get(verify, headers=auth(actor), params={'checkpoint': first['checkpoint']}).status_code == 200
    assert (ha.calls, ha.command_calls) == counts


def test_new_chain_baseline_cannot_impersonate_an_externally_retained_chain(server, ha):
    app, client, actor, _, _, _, verify = completed(server, ha)
    retained = client.get(verify, headers=auth(actor)).json()['verification']['checkpoint']
    with app.state.core.db.transaction() as c:
        c.execute('DROP TABLE command_history_chain')
        c.execute('DROP TABLE command_history_state')
        c.execute("DELETE FROM metadata WHERE key='command_history_schema'")
    with TestClient(create_app(server[2])) as restarted:
        assert restarted.get(verify, headers=auth(actor), params={'checkpoint': retained}).status_code == 409


def test_checkpoint_admin_boundary_and_current_auth_have_zero_ha_io(server, ha):
    app, client, settings, _ = server
    first = login(client, 'admin', bootstrap_password(settings)).json()
    scope = app.state.core.context
    verify = f'/api/v1/admin/home-assistant/{scope.coreId}/{scope.homeId}/history/verification'
    assert client.get(verify).status_code == 401
    assert client.get(verify, headers=auth(first)).status_code == 403
    _, client, actor, _, _, _, verify = completed(server, ha)
    create_user(client, actor)
    member = activate(client, 'member')
    counts = ha.calls, ha.command_calls
    assert client.get(verify, headers=auth(member)).status_code == 403
    assert client.get(verify.replace(scope.homeId, 'f' * 32), headers=auth(actor)).status_code == 404
    assert client.post('/api/v1/auth/logout', headers=auth(actor)).status_code == 204
    assert client.get(verify, headers=auth(actor)).status_code == 401
    assert (ha.calls, ha.command_calls) == counts


@pytest.mark.parametrize('query', ['checkpoint=', 'checkpoint=bad', 'checkpoint=' + 'a' * 513,
    'checkpoint=a&checkpoint=b', 'source=core_api', 'limit=1'])
def test_verification_query_is_closed_bounded_and_has_no_mutator(server, ha, query):
    _, client, actor, _, _, _, verify = completed(server, ha)
    counts = ha.calls, ha.command_calls
    assert client.get(verify + '?' + query, headers=auth(actor)).status_code == 400
    for method in ('POST', 'PUT', 'PATCH', 'DELETE'):
        assert client.request(method, verify, headers=auth(actor)).status_code == 405
    assert client.get(verify, headers=[('Authorization', auth(actor)['Authorization'])] * 2).status_code == 400
    assert (ha.calls, ha.command_calls) == counts


@pytest.mark.parametrize('part', ['signature', 'scope', 'head', 'boolean', 'noncanonical'])
def test_checkpoint_fields_cannot_be_forged_or_reinterpreted(server, ha, part):
    app, client, actor, _, _, _, verify = completed(server, ha)
    proof = client.get(verify, headers=auth(actor)).json()['verification']
    encoded, signature = proof['checkpoint'].split('.')
    data = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
    expected = 409
    if part == 'signature':
        signature = '0' * 64
    else:
        if part == 'scope': data[0] = 'f' * 32
        if part == 'head': data[4] = 'f' * 64
        if part == 'boolean': data[3] = True; expected = 400
        raw = chain._json(data)
        if part == 'noncanonical': raw = json.dumps(data).encode(); expected = 400
        encoded = base64.urlsafe_b64encode(raw).decode().rstrip('=')
        signature = chain._signed(app.state.core.home_assistant._key, b'larenor-command-checkpoint-v1\0', data)
    assert client.get(verify, headers=auth(actor), params={'checkpoint': encoded + '.' + signature}).status_code == expected


@pytest.mark.parametrize('column,prefix', [('chain_id', 'f' * 32), ('head_hash', 'f' * 64),
    ('authentication_tag', 'f' * 64)])
def test_state_nul_suffix_is_rejected_before_python_materializes_it(server, ha, column, prefix):
    app, client, actor, _, _, _, verify = completed(server, ha)
    import tracemalloc
    with app.state.core.db.transaction() as c:
        c.execute('UPDATE command_history_state SET ' + column + '=?', (prefix + '\0' + 'x' * 4_000_000,))
    tracemalloc.start()
    try:
        assert client.get(verify, headers=auth(actor)).status_code == 503
        _, peak = tracemalloc.get_traced_memory()
        assert peak < 2_000_000
    finally:
        tracemalloc.stop()


def test_chain_quota_failure_rolls_back_new_command_before_dispatch(server, ha, monkeypatch):
    app, client, actor, record, binding, public, verify = completed(server, ha)
    monkeypatch.setattr(chain, 'MAX_ENTRIES', 2)  # Reach the same production boundary with a tiny fixture.
    with app.state.core.db.connection() as c:
        before = snapshot(c)
    counts = ha.calls, ha.command_calls
    response = client.post(public + '/commands', headers=auth(actor),
        json=command_body(record, binding, actor, request_id='8' * 32))
    assert response.status_code == 429
    with app.state.core.db.connection() as c:
        assert snapshot(c) == before
    assert (ha.calls, ha.command_calls) == counts


def test_chain_insert_denied_after_command_write_rolls_everything_back(server, ha, monkeypatch):
    app, client, actor, record, binding, public, _ = fixture(server, ha)
    original = Database.connection
    denied = []
    @contextmanager
    def restricted(db):
        with original(db) as c:
            def authorize(action, name, *_):
                if action == sqlite3.SQLITE_INSERT and name == 'command_history_chain':
                    # The current command write has happened inside this TX.
                    denied.append(True)
                    return sqlite3.SQLITE_DENY
                return sqlite3.SQLITE_OK
            c.set_authorizer(authorize)
            yield c
    with app.state.core.db.connection() as c:
        before = snapshot(c)
    monkeypatch.setattr(Database, 'connection', restricted)
    counts = ha.calls, ha.command_calls
    response = client.post(public + '/commands', headers=auth(actor), json=command_body(record, binding, actor))
    assert response.status_code == 503 and denied == [True]
    with app.state.core.db.connection() as c:
        assert snapshot(c) == before
    assert (ha.calls, ha.command_calls) == counts


def test_migration_commit_failure_preserves_old_records_and_absent_chain(server, ha):
    app, client, actor, _, _, _, _ = completed(server, ha)
    with app.state.core.db.transaction() as c:
        c.execute('DROP TABLE command_history_chain')
        c.execute('DROP TABLE command_history_state')
        c.execute("DELETE FROM metadata WHERE key='command_history_schema'")
        c.execute('CREATE TABLE synthetic_deferred(id TEXT REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED)')
        c.execute("CREATE TRIGGER synthetic_commit AFTER INSERT ON metadata "
            "WHEN NEW.key='command_history_schema' BEGIN INSERT INTO synthetic_deferred VALUES('missing'); END")
        before = '\n'.join(c.iterdump())
    with pytest.raises(StartupError, match='storage_initialization_failed'):
        create_app(server[2])
    with app.state.core.db.connection() as c:
        assert '\n'.join(c.iterdump()) == before
