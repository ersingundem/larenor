from contextlib import contextmanager
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from conftest import auth, login, ready
from test_admin import activate, create as create_user
from test_home_resource_registry import create, grant, paths
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import ApiError, StartupError


@pytest.mark.parametrize('target', ['record_id', 'state_revision'])
def test_corrupt_internal_identity_is_static_storage_error_not_client_validation(server, target):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create(client, admin, base)
    with app.state.core.db.transaction() as c:
        if target == 'record_id':
            c.execute("UPDATE home_resource_records SET id='broken-internal-value'")
        else:
            c.execute('UPDATE home_resource_state SET revision=1.5')
    r = client.get(public, headers=auth(admin))
    assert r.status_code == 503
    assert r.json()['error']['code'] == 'server_unavailable'
    assert 'broken-internal-value' not in r.text


@pytest.mark.parametrize('extra', [{'id': 'f' * 32}, {'ownerId': 'f' * 32}, {'grants': {}},
    {'url': 'https://fixture.invalid'}, {'credentials': {'token': 'synthetic-only'}},
    {'kind': 'user'}, {'label': '\nprivate'}, {'order': True}, {'order': 10001}])
def test_http_create_rejects_identity_privilege_and_provider_injection(server, extra):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    r = client.post(base, headers=auth(admin), json={'kind': 'room', 'label': 'Room', 'order': 0, **extra})
    assert r.status_code == 400
    assert client.get(public, headers=auth(admin)).json()['entries'] == []


def test_quota_failures_are_atomic_and_deletion_is_only_local_registry(server, monkeypatch):
    from larenor_server.home_resources import schema
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    monkeypatch.setattr(schema, 'MAX_RECORDS', 1)
    r = create(client, admin, base)
    assert client.post(base, headers=auth(admin), json={'kind': 'resource', 'label': 'Over quota', 'order': 0}).status_code == 409
    create_user(client, admin); member = activate(client, 'member')
    create_user(client, admin, 'second'); second = activate(client, 'second')
    monkeypatch.setattr(schema, 'MAX_GRANTS', 1)
    grant(client, admin, base, r, member['user']['id'])
    other = f"{base}/{r['ref']['id']}/grants/{second['user']['id']}"
    assert client.put(other, headers=auth(admin), json={'expectedAclRevision': 2, 'permissions': {'read': True, 'write': False}}).status_code == 409
    assert client.get(public, headers=auth(member)).json()['entries'][0]['aclRevision'] == 2
    with app.state.core.db.connection() as c:
        assert tuple(c.execute('SELECT record_count,grant_count FROM home_resource_state').fetchone()) == (1, 1)
    sentinel = app.state.core.settings.data_dir / 'synthetic-unrelated-file'; sentinel.write_text('keep')
    assert client.delete(base + '/' + r['ref']['id'] + '?expectedRevision=1&expectedAclRevision=2', headers=auth(admin)).status_code == 204
    assert sentinel.read_text() == 'keep'
    assert client.get('/api/v1/admin/services', headers=auth(admin)).json()['services'] == []


def test_total_grant_cap_and_noop_preserve_revisions(server, monkeypatch):
    from larenor_server.home_resources import schema
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member')
    first, second = create(client, admin, base), create(client, admin, base)
    monkeypatch.setattr(schema, 'MAX_TOTAL_GRANTS', 1)
    grant(client, admin, base, first, member['user']['id'])
    same = grant(client, admin, base, first, member['user']['id'], revision=2)
    assert same['aclRevision'] == 2
    r = client.put(f"{base}/{second['ref']['id']}/grants/{member['user']['id']}", headers=auth(admin),
        json={'expectedAclRevision': 1, 'permissions': {'read': True, 'write': False}})
    assert r.status_code == 409
    assert client.get(public + '/' + second['ref']['id'], headers=auth(member)).status_code == 404
    snapshot = client.get(public, headers=auth(admin)).json()
    patch = client.patch(base + '/' + first['ref']['id'], headers=auth(admin),
        json={'expectedRevision': 1, 'expectedAclRevision': 2, 'label': 'Salon', 'order': 0})
    assert patch.status_code == 200 and patch.json()['record']['revision'] == 1
    assert client.get(public, headers=auth(admin)).json() == snapshot
    grants = client.get(f"{base}/{first['ref']['id']}/grants", headers=auth(admin)).json()
    assert grants['grants'] == [same]


@pytest.mark.parametrize('change', ['logout', 'disable', 'password_reset'])
@pytest.mark.parametrize('endpoint', ['list', 'get'])
def test_member_reads_use_current_actual_http_session(server, change, endpoint):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    user = create_user(client, admin); member = activate(client, 'member'); record = create(client, admin, base)
    grant(client, admin, base, record, member['user']['id'])
    if change == 'logout':
        assert client.post('/api/v1/auth/logout', headers=auth(member)).status_code == 204
    elif change == 'disable':
        assert client.patch('/api/v1/admin/users/' + user['id'], headers=auth(admin),
                            json={'expectedRevision': 2, 'disabled': True}).status_code == 200
    else:
        assert client.post('/api/v1/admin/users/' + user['id'] + '/password', headers=auth(admin),
                           json={'expectedRevision': 2, 'temporaryPassword': 'Synthetic new initial password'}).status_code == 200
    path = public if endpoint == 'list' else public + '/' + record['ref']['id']
    assert client.get(path, headers=auth(member)).status_code == 401


def test_acl_revoked_after_http_authentication_is_rechecked_before_read(server, monkeypatch):
    from larenor_server.home_resources.api_models import SetGrantRequest
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member'); record = create(client, admin, base)
    grant(client, admin, base, record, member['user']['id'])
    core = app.state.core; admin_actor = core.auth.authenticate(admin['accessToken']); original = core.auth.authenticate
    def authenticate(token):
        result = original(token)
        if token == member['accessToken']:
            core.home_resources.set_grant(admin_actor, core.context.coreId, core.context.homeId,
                record['ref']['id'], member['user']['id'], SetGrantRequest(expectedAclRevision=2,
                permissions={'read': False, 'write': False}))
        return result
    monkeypatch.setattr(core.auth, 'authenticate', authenticate)
    assert client.get(public + '/' + record['ref']['id'], headers=auth(member)).status_code == 404


def test_admin_demoted_after_http_dependency_cannot_create(server, monkeypatch):
    from larenor_server.admin.models import UpdateUserRequest
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    user = create_user(client, admin, 'delegate', 'admin'); delegated = activate(client, 'delegate')
    core = app.state.core; owner = core.auth.authenticate(admin['accessToken']); original = core.auth.authenticate
    def authenticate(token):
        result = original(token)
        if token == delegated['accessToken']:
            core.admin.update_user(owner, user['id'], UpdateUserRequest(expectedRevision=2, role='member'))
        return result
    monkeypatch.setattr(core.auth, 'authenticate', authenticate)
    r = client.post(base, headers=auth(delegated), json={'kind': 'room', 'label': 'Late', 'order': 0})
    assert r.status_code == 401
    assert client.get(public, headers=auth(admin)).json()['entries'] == []


def test_inprocess_write_check_cancellation_and_old_revisions_have_no_effect(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member'); record = create(client, admin, base)
    grant(client, admin, base, record, member['user']['id'], write=True)
    core = app.state.core; actor = core.auth.authenticate(member['accessToken'])
    args = (actor, core.context.coreId, core.context.homeId, record['ref']['id'], 'write')
    valid = dict(expected_revision=1, expected_acl_revision=2, expected_user_revision=2)
    assert core.home_resources.authorize(*args, **valid) is None
    for changed in [dict(cancelled=True), dict(expected_revision=2), dict(expected_acl_revision=1), dict(expected_user_revision=1)]:
        with pytest.raises(ApiError):
            core.home_resources.authorize(*args, **{**valid, **changed})
    assert client.get(public, headers=auth(member)).json()['entries'][0]['revision'] == 1
    documented = client.get('/api/v1/openapi.json', headers=auth(admin)).json()['paths']
    assert not any('command' in path for path in documented if 'home-resources' in path)


@pytest.mark.parametrize('tamper', ['marker', 'missing_marker', 'table', 'state_tag', 'missing_record', 'nonce'])
def test_restart_rejects_unknown_schema_missing_and_tampered_storage(server, tamper):
    app, client, settings, _ = server; admin = ready(server); _, base = paths(app); create(client, admin, base)
    with app.state.core.db.transaction() as c:
        if tamper == 'marker': c.execute("UPDATE metadata SET value='99' WHERE key='home_resources_schema'")
        elif tamper == 'missing_marker': c.execute("DELETE FROM metadata WHERE key='home_resources_schema'")
        elif tamper == 'table': c.execute('DROP TABLE home_resource_state')
        elif tamper == 'state_tag': c.execute("UPDATE home_resource_state SET authentication_tag='broken'")
        elif tamper == 'missing_record': c.execute('DELETE FROM home_resource_records')
        else: c.execute("UPDATE home_resource_records SET nonce=x'00'")
    with pytest.raises(StartupError, match='home_resource_storage_invalid'):
        create_app(settings)


def test_ciphertext_transplanted_to_another_core_is_not_a_shared_resource(server, tmp_path):
    app, client, settings, clock = server; admin = ready(server); _, base = paths(app); record = create(client, admin, base)
    with app.state.core.db.connection() as c:
        row = tuple(c.execute('SELECT * FROM home_resource_records').fetchone())
    other_settings = Settings(tmp_path / 'second-data', settings.key_file, clock=clock,
                              login_ip_limit=100, login_account_limit=100, login_global_limit=100)
    other_app = create_app(other_settings)
    with TestClient(other_app) as other:
        other_admin = ready((other_app, other, other_settings, clock)); public, _ = paths(other_app)
        with other_app.state.core.db.transaction() as c:
            c.execute('INSERT INTO home_resource_records VALUES(?,?,?,?,?,?)', row)
        assert other.get(public + '/' + record['ref']['id'], headers=auth(other_admin)).status_code == 503


def test_storage_validation_streams_rows_with_a_hard_scan_limit(server, monkeypatch):
    app, client, _, _ = server; admin = ready(server); _, base = paths(app); create(client, admin, base)
    core = app.state.core; original = core.db.connection; seen = []
    class IterationOnly:
        def __init__(self, cursor): self.cursor = cursor
        def __iter__(self): return iter(self.cursor)
        def fetchall(self): raise AssertionError('encrypted records must not accumulate')
    class Connection:
        def __init__(self, c): self.c = c
        def execute(self, sql, args=()):
            cursor = self.c.execute(sql, args)
            if sql.startswith('SELECT * FROM home_resource_records'):
                seen.append((sql, args)); return IterationOnly(cursor)
            return cursor
    @contextmanager
    def connection():
        with original() as c: yield Connection(c)
    monkeypatch.setattr(core.db, 'connection', connection)
    core.home_resources.validate_storage()
    assert seen == [('SELECT * FROM home_resource_records LIMIT ?', (513,))]
