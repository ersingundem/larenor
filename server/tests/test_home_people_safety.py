"""Current authorization, storage integrity and compatibility for household profiles."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from test_admin import activate, create as create_user
from test_home_people_registry import create, grant, paths
from larenor_server.app import create_app
from larenor_server.errors import ApiError, StartupError
from larenor_server.home_people.models import CreatePersonRequest, SetPersonGrantRequest, UpdatePersonRequest


@pytest.mark.parametrize('change', ['logout', 'disabled', 'demoted', 'reset_password'])
@pytest.mark.parametrize('operation', ['list', 'get', 'create', 'update', 'delete', 'grant', 'grants'])
def test_retired_principals_cannot_bypass_current_people_transaction(server, change, operation):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    user = create_user(client, admin, 'delegate', 'admin'); pair = activate(client, 'delegate')
    actor = app.state.core.auth.authenticate(pair['accessToken'])
    person = create(client, admin, base)
    registry = app.state.core.home_people; scope = app.state.core.context; identity = person['ref']['id']
    if change == 'logout':
        assert client.post('/api/v1/auth/logout', headers=auth(pair)).status_code == 204
    elif change == 'reset_password':
        assert client.post('/api/v1/admin/users/' + user['id'] + '/password', headers=auth(admin),
            json={'expectedRevision': 2, 'temporaryPassword': 'Synthetic replacement password'}).status_code == 200
    else:
        assert client.patch('/api/v1/admin/users/' + user['id'], headers=auth(admin),
            json={'expectedRevision': 2, **({'disabled': True} if change == 'disabled' else {'role': 'member'})}).status_code == 200
    args = actor, scope.coreId, scope.homeId
    actions = {
        'list': lambda: registry.list(*args), 'get': lambda: registry.get(*args, identity),
        'create': lambda: registry.create(*args, CreatePersonRequest(label='New', order=0)),
        'update': lambda: registry.update(*args, identity, UpdatePersonRequest(label='New', order=0, expectedRevision=1, expectedAclRevision=1)),
        'delete': lambda: registry.delete(*args, identity, 1, 1),
        'grant': lambda: registry.set_grant(*args, identity, user['id'], SetPersonGrantRequest(expectedAclRevision=1, permissions={'read': True, 'write': False})),
        'grants': lambda: registry.grants(*args, identity),
    }
    with pytest.raises(ApiError, match='invalid_session'):
        actions[operation]()
    assert client.get(public, headers=auth(admin)).json()['entries'] == [person]


def test_acl_race_has_one_winner_and_stale_metadata_cannot_overwrite_access(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member'); person = create(client, admin, base)
    actor = app.state.core.auth.authenticate(admin['accessToken']); scope = app.state.core.context
    barrier = Barrier(2)
    def apply(write):
        barrier.wait()
        try:
            return app.state.core.home_people.set_grant(actor, scope.coreId, scope.homeId, person['ref']['id'], member['user']['id'],
                SetPersonGrantRequest(expectedAclRevision=1, permissions={'read': True, 'write': write}))
        except ApiError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(apply, [True, False]))
    assert sum(isinstance(result, dict) for result in results) == 1
    assert 'revision_conflict' in results
    response = client.patch(base + '/' + person['ref']['id'], headers=auth(admin),
        json={'label': 'Stale', 'order': 0, 'expectedRevision': 1, 'expectedAclRevision': 1})
    assert response.status_code == 409
    visible = client.get(public, headers=auth(member)).json()['entries'][0]
    assert visible['label'] == 'Deniz' and visible['aclRevision'] == 2


def test_pages_are_bound_to_visible_snapshot_and_deleted_cursor_cannot_skip_entries(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member')
    for i in range(3):
        person = create(client, admin, base, label=f'Person {i}')
        grant(client, admin, base, person, member['user']['id'])
    page = client.get(public, headers=auth(member), params={'limit': 1}).json()
    query = {'after': page['nextAfter'], 'limit': 1, 'expectedSnapshot': page['snapshot']}
    next_page = client.get(public, headers=auth(member), params=query).json()
    assert len(next_page['entries']) == 1
    assert next_page['entries'][0]['ref'] != page['entries'][0]['ref']
    for params in ({'after': page['nextAfter']}, {'limit': 101}, {'limit': 0}, {'expectedSnapshot': 'invalid'}):
        assert client.get(public, headers=auth(member), params=params).status_code == 400
    assert client.delete(base + '/' + page['nextAfter'], headers=auth(admin),
        params={'expectedRevision': 1, 'expectedAclRevision': 2}).status_code == 204
    assert client.get(public, headers=auth(member), params=query).status_code == 409


@pytest.mark.parametrize('change', ['missing_marker', 'unknown_version', 'missing_table', 'extra_index', 'state_tag', 'missing_record'])
def test_schema_and_integrity_tampering_is_preserved_and_rejected_on_restart(server, change):
    app, client, settings, _ = server; admin = ready(server); _, base = paths(app)
    create(client, admin, base)
    commands = {
        'missing_marker': "DELETE FROM metadata WHERE key='home_people_schema'",
        'unknown_version': "UPDATE metadata SET value='2' WHERE key='home_people_schema'",
        'missing_table': 'DROP TABLE home_people_audit',
        'extra_index': 'CREATE INDEX home_people_extra ON home_people_records(id)',
        'state_tag': "UPDATE home_people_state SET authentication_tag='wrong'",
        'missing_record': 'DELETE FROM home_people_records',
    }
    with app.state.core.db.transaction() as connection:
        connection.execute(commands[change])
    with app.state.core.db.connection() as connection:
        before = '\n'.join(connection.iterdump())
    with pytest.raises(StartupError, match='home_people_storage_invalid'):
        create_app(settings)
    with app.state.core.db.connection() as connection:
        assert '\n'.join(connection.iterdump()) == before


@pytest.mark.parametrize('table,column', [
    ('home_people_records', 'kind'),
    ('home_people_state', 'singleton'),
    ('home_people_audit', 'sequence'),
])
@pytest.mark.parametrize('object_kind', ['unique_index', 'ignore_insert_trigger'])
def test_foreign_named_attached_schema_objects_fail_restart_without_changes(
        server, table, column, object_kind):
    app, client, settings, _ = server
    admin = ready(server); _, base = paths(app)
    create(client, admin, base)
    # Names deliberately lack the domain prefix; ownership comes from the
    # attached table. Neither uniqueness nor silent ignored writes is permitted.
    statement = (
        f'CREATE UNIQUE INDEX unrelated_index ON {table}({column})'
        if object_kind == 'unique_index' else
        f'CREATE TRIGGER unrelated_trigger BEFORE INSERT ON {table} '
        'BEGIN SELECT RAISE(IGNORE); END'
    )
    with app.state.core.db.transaction() as connection:
        connection.execute(statement)
    with app.state.core.db.connection() as connection:
        before = '\n'.join(connection.iterdump())
    with pytest.raises(StartupError, match='^home_people_storage_invalid$'):
        create_app(settings)
    with app.state.core.db.connection() as connection:
        assert '\n'.join(connection.iterdump()) == before


def test_valid_primary_key_index_and_unrelated_table_objects_survive_restart(server):
    app, client, settings, _ = server
    admin = ready(server); public, base = paths(app)
    person = create(client, admin, base)
    with app.state.core.db.transaction() as connection:
        indexes = connection.execute('PRAGMA index_list(home_people_records)').fetchall()
        assert len(indexes) == 1 and indexes[0]['origin'] == 'pk'
        assert indexes[0]['unique'] == 1 and indexes[0]['partial'] == 0
        connection.execute('CREATE TABLE unrelated_fixture (id INTEGER)')
        connection.execute('CREATE UNIQUE INDEX unrelated_index ON unrelated_fixture(id)')
        connection.execute('CREATE TRIGGER unrelated_trigger BEFORE INSERT ON unrelated_fixture '
                           'BEGIN SELECT RAISE(IGNORE); END')
    with app.state.core.db.connection() as connection:
        before = '\n'.join(connection.iterdump())
    restarted = create_app(settings)
    with app.state.core.db.connection() as connection:
        assert '\n'.join(connection.iterdump()) == before
    with TestClient(restarted) as next_client:
        assert next_client.get(public + '/' + person['ref']['id'], headers=auth(admin)).json()['person'] == person


def test_additive_people_migration_preserves_old_context_users_tokens_resources_and_vault(server):
    app, client, settings, _ = server; admin = ready(server)
    scope = app.state.core.context
    old = f'/api/v1/home-resources/{scope.coreId}/{scope.homeId}'
    room = client.post('/api/v1/admin' + old.removeprefix('/api/v1'), headers=auth(admin),
        json={'kind': 'room', 'label': 'Eski oda', 'order': 4}).json()['record']
    # Exact pre-people schema: all current production tables are retained;
    # only this newly additive, empty domain is absent.
    with app.state.core.db.transaction() as connection:
        for table in ('home_people_audit', 'home_people_state', 'home_people_records'):
            connection.execute('DROP TABLE ' + table)
        connection.execute("DELETE FROM metadata WHERE key='home_people_schema'")
        tables = [row['name'] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name!='sqlite_sequence' ORDER BY name")]
        before = {table: [tuple(row) for row in connection.execute('SELECT * FROM ' + table)] for table in tables}
    restarted = create_app(settings)
    with restarted.state.core.db.connection() as connection:
        for table, rows in before.items():
            observed = [tuple(row) for row in connection.execute('SELECT * FROM ' + table)]
            if table == 'metadata':
                observed = [row for row in observed if row[0] != 'home_people_schema']
            assert observed == rows, table
    with TestClient(restarted) as next_client:
        assert next_client.get(old, headers=auth(admin)).json()['entries'] == [room]
        assert next_client.get(paths(restarted)[0], headers=auth(admin)).json()['entries'] == []


@pytest.mark.parametrize('version', [1, 2])
def test_historical_database_fixture_predates_all_context_bound_people_state(server, version):
    from test_admin_migration import downgrade_to_known_v1
    from test_core_context import legacy_v2
    app, client, settings, _ = server
    admin = ready(server)
    (downgrade_to_known_v1 if version == 1 else legacy_v2)(app)
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0] == str(version)
        assert connection.execute("SELECT name FROM sqlite_master WHERE name GLOB 'home_people_*'").fetchall() == []
        assert connection.execute("SELECT value FROM metadata WHERE key='home_people_schema'").fetchone() is None
    restored = create_app(settings)
    with TestClient(restored) as next_client:
        public, _ = paths(restored)
        result = next_client.get(public, headers=auth(admin))
        assert result.status_code == 200 and result.json()['entries'] == []
    with restored.state.core.db.connection() as connection:
        assert connection.execute("SELECT value FROM metadata WHERE key='home_people_schema'").fetchone()[0] == '1'
