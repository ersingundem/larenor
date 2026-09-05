"""Actual HTTP/auth/SQLite guarantees for the metadata registry, no upstream services."""
from concurrent.futures import ThreadPoolExecutor
import json
from threading import Barrier

import pytest
from fastapi.testclient import TestClient

from conftest import auth, bootstrap_password, document, login, ready
from test_admin import activate, create as create_user
from larenor_server.app import create_app
from larenor_server.errors import ApiError, StartupError


def paths(app):
    c = app.state.core.context
    suffix = f'/home-resources/{c.coreId}/{c.homeId}'
    return '/api/v1' + suffix, '/api/v1/admin' + suffix


def create(client, pair, base, **changes):
    r = client.post(base, headers=auth(pair), json={'kind': 'room', 'label': 'Salon', 'order': 0, **changes})
    assert r.status_code == 201, r.text
    return r.json()['record']


def grant(client, admin, base, record, subject, *, revision=1, read=True, write=False):
    r = client.put(f"{base}/{record['ref']['id']}/grants/{subject}", headers=auth(admin),
                   json={'expectedAclRevision': revision, 'permissions': {'read': read, 'write': write}})
    assert r.status_code == 200, r.text
    return r.json()['grant']


def test_real_registry_flow_is_encrypted_stable_and_consumes_explicit_acl(server):
    app, client, settings, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member')
    record = create(client, admin, base); identity = record['ref']['id']
    assert record['revision'] == record['aclRevision'] == 1
    assert record['permissions'] == {'read': True, 'write': True}
    assert client.get(public, headers=auth(member)).json()['entries'] == []
    hidden = client.get(public + '/' + identity, headers=auth(member))
    missing = client.get(public + '/' + 'f' * 32, headers=auth(member))
    assert hidden.status_code == missing.status_code == 404 and hidden.json() == missing.json()
    g = grant(client, admin, base, record, member['user']['id'])
    assert g['aclRevision'] == 2
    visible = client.get(public + '/' + identity, headers=auth(member)).json()['record']
    assert visible['permissions'] == {'read': True, 'write': False}
    saved = client.patch(base + '/' + identity, headers=auth(admin), json={
        'expectedRevision': 1, 'expectedAclRevision': 2, 'label': 'Başka oda', 'order': 8})
    assert saved.status_code == 200
    renamed = saved.json()['record']; assert renamed['revision'] == 2 and renamed['aclRevision'] == 2
    assert renamed['ref'] == record['ref']
    assert client.get(public, headers=auth(member)).json()['entries'][0]['label'] == 'Başka oda'
    with app.state.core.db.connection() as c:
        dump = '\n'.join(c.iterdump())
    assert 'Salon' not in dump and 'Başka oda' not in dump
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(public + '/' + identity, headers=auth(member)).json()['record'] == {
            **renamed, 'permissions': {'read': True, 'write': False}}
    grant(client, admin, base, record, member['user']['id'], revision=2, read=False)
    assert client.get(public + '/' + identity, headers=auth(member)).status_code == 404
    assert client.delete(base + '/' + identity + '?expectedRevision=2&expectedAclRevision=3', headers=auth(admin)).status_code == 204
    assert client.get(public, headers=auth(admin)).json()['entries'] == []


def test_registry_cannot_open_other_users_vault_or_account_management(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member')
    assert client.put('/api/v1/vault', headers=auth(member), json={'expectedRevision': 0, 'document': document()}).status_code == 200
    record = create(client, admin, base, kind='resource')
    grant(client, admin, base, record, member['user']['id'], write=True)
    assert client.get(public + '/' + record['ref']['id'], headers=auth(member)).json()['record']['permissions']['write']
    assert client.get('/api/v1/vault', headers=auth(admin)).json()['document'] is None
    for kind in ('vault', 'person', 'user', 'session', 'service_credentials'):
        r = client.post(base, headers=auth(admin), json={'kind': kind, 'label': 'X', 'order': 0})
        assert r.status_code == 400
    assert client.get('/api/v1/admin/users', headers=auth(member)).status_code == 403
    assert client.post(base, headers=auth(member), json={'kind': 'room', 'label': 'X', 'order': 0}).status_code == 403


def test_all_routes_require_ready_session_and_server_scope(server):
    app, client, settings, _ = server; public, base = paths(app)
    initial = login(client, 'admin', bootstrap_password(settings)).json()
    for headers, expected in [({}, 401), (auth(initial), 403)]:
        assert client.get(public, headers=headers).status_code == expected
        assert client.post(base, headers=headers, json={'kind': 'room', 'label': 'X', 'order': 0}).status_code == expected
    admin = ready(server)
    for field in ('coreId', 'homeId'):
        other = base.replace(getattr(app.state.core.context, field), 'f' * 32)
        assert client.post(other, headers=auth(admin), json={'kind': 'room', 'label': 'X', 'order': 0}).status_code == 404
        assert client.get(other.replace('/admin', ''), headers=auth(admin)).status_code == 404
    schema = client.get('/api/v1/openapi.json', headers=auth(admin)).json()
    assert '/api/v1/home-resources/{core_id}/{home_id}' in schema['paths']
    assert not any('command' in p for p in schema['paths'] if 'home-resources' in p)


@pytest.mark.parametrize('change', ['logout', 'disabled', 'demoted', 'reset_password'])
@pytest.mark.parametrize('operation', ['list', 'get', 'create', 'update', 'delete', 'grant', 'grants'])
def test_old_principals_are_rechecked_in_real_registry_transaction(server, change, operation):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    user = create_user(client, admin, 'delegate', 'admin'); pair = activate(client, 'delegate')
    actor = app.state.core.auth.authenticate(pair['accessToken']); record = create(client, admin, base)
    registry = app.state.core.home_resources; ref = record['ref']; scope = app.state.core.context
    if change == 'logout':
        assert client.post('/api/v1/auth/logout', headers=auth(pair)).status_code == 204
    elif change == 'reset_password':
        assert client.post('/api/v1/admin/users/' + user['id'] + '/password', headers=auth(admin),
                           json={'expectedRevision': 2, 'temporaryPassword': 'Reset synthetic password'}).status_code == 200
    else:
        payload = {'expectedRevision': 2, **({'disabled': True} if change == 'disabled' else {'role': 'member'})}
        assert client.patch('/api/v1/admin/users/' + user['id'], headers=auth(admin), json=payload).status_code == 200
    from larenor_server.home_resources.api_models import CreateRecordRequest, UpdateRecordRequest, SetGrantRequest
    args = (actor, scope.coreId, scope.homeId)
    actions = {
        'list': lambda: registry.list(*args), 'get': lambda: registry.get(*args, ref['id']),
        'create': lambda: registry.create(*args, CreateRecordRequest(kind='room', label='X', order=0)),
        'update': lambda: registry.update(*args, ref['id'], UpdateRecordRequest(expectedRevision=1, expectedAclRevision=1, label='X', order=0)),
        'delete': lambda: registry.delete(*args, ref['id'], 1, 1),
        'grant': lambda: registry.set_grant(*args, ref['id'], user['id'], SetGrantRequest(expectedAclRevision=1, permissions={'read': True, 'write': False})),
        'grants': lambda: registry.grants(*args, ref['id']),
    }
    with pytest.raises(ApiError, match='invalid_session'):
        actions[operation]()
    assert client.get(public, headers=auth(pair)).status_code == 401
    assert client.get(public, headers=auth(admin)).json()['entries'] == [record]


def test_acl_revision_race_has_one_winner_and_metadata_does_not_erase_grants(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member'); record = create(client, admin, base)
    actor = app.state.core.auth.authenticate(admin['accessToken']); c = app.state.core.context
    from larenor_server.home_resources.api_models import SetGrantRequest
    barrier = Barrier(2)
    def write(enabled):
        barrier.wait()
        try:
            return app.state.core.home_resources.set_grant(actor, c.coreId, c.homeId, record['ref']['id'], member['user']['id'],
                SetGrantRequest(expectedAclRevision=1, permissions={'read': True, 'write': enabled}))
        except ApiError as e:
            return e.code
    with ThreadPoolExecutor(max_workers=2) as pool:
        result = list(pool.map(write, [True, False]))
    assert sum(isinstance(v, dict) for v in result) == 1 and 'revision_conflict' in result
    assert client.get(public, headers=auth(member)).json()['entries'][0]['aclRevision'] == 2


def test_member_pagination_is_bounded_and_rejects_context_or_acl_changes(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member')
    for i in range(3):
        r = create(client, admin, base, label=f'Room {i}'); grant(client, admin, base, r, member['user']['id'])
    page = client.get(public + '?limit=1', headers=auth(member)).json()
    assert len(page['entries']) == 1 and page['nextAfter']
    query = {'limit': 1, 'after': page['nextAfter'], 'expectedSnapshot': page['snapshot']}
    assert len(client.get(public, headers=auth(member), params=query).json()['entries']) == 1
    grant(client, admin, base, r, member['user']['id'], revision=2, read=False)
    assert client.get(public, headers=auth(member), params=query).status_code == 409
    assert client.get(public, headers=auth(member), params={'after': page['nextAfter']}).status_code == 400
    assert client.get(public + '?limit=101', headers=auth(member)).status_code == 400


def test_current_context_restore_mismatch_is_not_accepted(server):
    app, client, settings, _ = server; admin = ready(server); public, base = paths(app)
    create(client, admin, base)
    with app.state.core.db.transaction() as c:
        c.execute("UPDATE core_context SET home_id=?", ('f' * 32,))
    assert client.get(public, headers=auth(admin)).status_code == 503
    with pytest.raises(StartupError):
        create_app(settings)


def test_schema_and_row_tampering_fail_closed_on_restart(server):
    app, client, settings, _ = server; admin = ready(server); public, base = paths(app)
    record = create(client, admin, base)
    with app.state.core.db.transaction() as c:
        c.execute('UPDATE home_resource_records SET acl_revision=acl_revision+1 WHERE id=?', (record['ref']['id'],))
    assert client.get(public, headers=auth(admin)).status_code == 503
    with pytest.raises(StartupError, match='home_resource_storage_invalid'):
        create_app(settings)
