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
