import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from test_admin import activate, create as create_user
from test_home_resource_registry import create, grant, paths
from larenor_server.app import create_app
from larenor_server.config import Settings


def test_member_empty_snapshot_does_not_reveal_hidden_changes(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member')
    before = client.get(public, headers=auth(member)).json()
    hidden = create(client, admin, base)
    assert client.patch(base + '/' + hidden['ref']['id'], headers=auth(admin), json={
        'expectedRevision': 1, 'expectedAclRevision': 1, 'label': 'Private change', 'order': 2}).status_code == 200
    after = client.get(public, headers=auth(member)).json()
    assert 'registryRevision' not in before
    assert before == after
    assert len(before['snapshot']) == 64 and before['entries'] == []


def test_hidden_mutation_keeps_pagination_but_visible_change_conflicts(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member')
    visible = [create(client, admin, base, label=f'Visible {i}') for i in range(3)]
    for record in visible: grant(client, admin, base, record, member['user']['id'])
    hidden = create(client, admin, base, label='Invisible')
    first = client.get(public, headers=auth(member), params={'limit': 1}).json()
    query = {'limit': 1, 'after': first['nextAfter'], 'expectedSnapshot': first['snapshot']}
    original_second = client.get(public, headers=auth(member), params=query).json()
    assert client.patch(base + '/' + hidden['ref']['id'], headers=auth(admin), json={
        'expectedRevision': 1, 'expectedAclRevision': 1, 'label': 'Hidden update', 'order': 2}).status_code == 200
    assert client.get(public, headers=auth(member), params=query).json() == original_second
    assert client.get(public, headers=auth(member), params={'limit': 100}).json()['snapshot'] == first['snapshot']
    last = sorted(visible, key=lambda r: r['ref']['id'])[-1]
    assert client.patch(base + '/' + last['ref']['id'], headers=auth(admin), json={
        'expectedRevision': 1, 'expectedAclRevision': 2, 'label': 'Visible tail changed', 'order': 3}).status_code == 200
    assert client.get(public, headers=auth(member), params=query).status_code == 409


def test_same_visible_records_have_distinct_actor_bound_snapshots(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); first = activate(client, 'member')
    create_user(client, admin, 'second'); second = activate(client, 'second')
    record = create(client, admin, base)
    grant(client, admin, base, record, first['user']['id'])
    grant(client, admin, base, record, second['user']['id'], revision=2)
    one = client.get(public, headers=auth(first)).json(); two = client.get(public, headers=auth(second)).json()
    assert one['entries'] == two['entries'] and one['snapshot'] != two['snapshot']
    assert client.get(public, headers=auth(second), params={'expectedSnapshot': one['snapshot']}).status_code == 409


def test_new_user_revision_rejects_old_snapshot_without_losing_grant(server):
    app, client, _, _ = server; admin = ready(server); public, _ = paths(app)
    old = client.get(public, headers=auth(admin)).json()['snapshot']
    changed = client.post('/api/v1/auth/password', headers=auth(admin), json={
        'currentPassword': 'Synthetic new password 2026', 'newPassword': 'Synthetic replacement password 2026'})
    assert changed.status_code == 200
    current = changed.json()
    assert client.get(public, headers=auth(current), params={'expectedSnapshot': old}).status_code == 409
    assert client.get(public, headers=auth(current)).json()['snapshot'] != old


def test_scope_binding_holds_even_with_same_key_user_id_revision_and_empty_data(server, tmp_path):
    app, client, settings, clock = server; admin = ready(server); public, _ = paths(app)
    old = client.get(public, headers=auth(admin)).json()['snapshot']
    other_settings = Settings(tmp_path / 'snapshot-other', settings.key_file, clock=clock)
    other_app = create_app(other_settings)
    with other_app.state.core.db.transaction() as c:
        c.execute('UPDATE users SET id=?', (admin['user']['id'],))
    with TestClient(other_app) as other:
        pair = ready((other_app, other, other_settings, clock)); other_path, _ = paths(other_app)
        assert pair['user']['id'] == admin['user']['id']
        assert other.get(other_path, headers=auth(pair), params={'expectedSnapshot': old}).status_code == 409
        assert other.get(other_path, headers=auth(pair)).json()['snapshot'] != old


def test_snapshot_survives_refresh_restart_and_hidden_acl_changes(server):
    app, client, settings, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member')
    create_user(client, admin, 'second'); second = activate(client, 'second')
    record = create(client, admin, base); hidden = create(client, admin, base)
    grant(client, admin, base, record, member['user']['id'])
    initial = client.get(public, headers=auth(member)).json()
    grant(client, admin, base, hidden, second['user']['id'])
    refreshed = client.post('/api/v1/auth/refresh', json={'refreshToken': member['refreshToken']})
    assert refreshed.status_code == 200
    member = refreshed.json()
    assert client.get(public, headers=auth(member)).json() == initial
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(public, headers=auth(member)).json() == initial
    grant(client, admin, base, record, member['user']['id'], revision=2, write=True)
    assert client.get(public, headers=auth(member), params={'expectedSnapshot': initial['snapshot']}).status_code == 409
    current = client.get(public, headers=auth(member)).json()
    assert current['entries'][0]['permissions'] == {'read': True, 'write': True}


@pytest.mark.parametrize('token', ['', 'a' * 63, 'a' * 65, 'A' * 64, 'x' * 64, 'true'])
def test_http_snapshot_token_has_a_closed_canonical_shape(server, token):
    app, client, _, _ = server; admin = ready(server); public, _ = paths(app)
    assert client.get(public, headers=auth(admin), params={'expectedSnapshot': token}).status_code == 400


def test_missing_and_hidden_cursor_are_indistinguishable_with_current_snapshot(server):
    app, client, _, _ = server; admin = ready(server); public, base = paths(app)
    create_user(client, admin); member = activate(client, 'member'); hidden = create(client, admin, base)
    snapshot = client.get(public, headers=auth(member)).json()['snapshot']
    responses = [client.get(public, headers=auth(member), params={
        'after': identity, 'expectedSnapshot': snapshot}) for identity in [hidden['ref']['id'], 'f' * 32]]
    assert responses[0].status_code == responses[1].status_code == 404
    assert responses[0].json() == responses[1].json()
