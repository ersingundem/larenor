import json

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_admin import activate, create as create_user


def roots(app):
    context = app.state.core.context
    return (
        f'/api/v1/meal-plans/{context.coreId}/{context.homeId}',
        f'/api/v1/admin/home-people/{context.coreId}/{context.homeId}',
    )


def account_revision(client, admin, user_id):
    users = client.get('/api/v1/admin/users', headers=auth(admin)).json()['users']
    return next(user['revision'] for user in users if user['id'] == user_id)


def create_person(client, admin, people_root, label='Ece'):
    response = client.post(
        people_root,
        headers=auth(admin),
        json={'label': label, 'order': 0},
    )
    assert response.status_code == 201, response.text
    return response.json()['person']


def plan_body(person, account_revision, *, request_id='a' * 32, revision=0):
    return {
        'schemaVersion': 1,
        'requestId': request_id,
        'expectedAccountRevision': account_revision,
        'expectedRevision': revision,
        'weekStart': '2026-09-21',
        'recipes': [{
            'schemaVersion': 1,
            'id': '1' * 32,
            'locale': 'tr',
            'title': 'Mercimek çorbası',
            'baseServings': 2,
            'ingredients': [
                {'schemaVersion': 1, 'quantityMillis': 200000, 'unit': 'g', 'name': 'Mercimek'},
                {'schemaVersion': 1, 'quantityMillis': 1500, 'unit': 'l', 'name': 'Su'},
            ],
        }],
        'entries': [{
            'schemaVersion': 1,
            'id': '2' * 32,
            'date': '2026-09-21',
            'slot': 'dinner',
            'recipeId': '1' * 32,
            'servings': 5,
            'personId': person['ref']['id'],
            'expectedPersonRevision': person['revision'],
            'expectedPersonAclRevision': person['aclRevision'],
        }],
    }


def test_weekly_menu_persists_turkish_recipe_and_exact_idempotent_replay(server):
    app, client, settings, _ = server
    admin = ready(server)
    root, people_root = roots(app)
    person = create_person(client, admin, people_root, 'İpek Şahin')
    revision = account_revision(client, admin, admin['user']['id'])
    body = plan_body(person, revision)

    first = client.put(root, headers=auth(admin), json=body)
    replay = client.put(root, headers=auth(admin), json=body)
    assert first.status_code == replay.status_code == 200
    assert first.json() == replay.json()
    value = first.json()
    assert value['authority'] == {
        'schemaVersion': 1,
        'coreId': app.state.core.context.coreId,
        'homeId': app.state.core.context.homeId,
        'accountId': admin['user']['id'],
        'sessionFamilyId': value['authority']['sessionFamilyId'],
        'accountRevision': revision,
        'planRevision': 1,
    }
    assert value['plan']['weekStart'] == '2026-09-21'
    assert value['plan']['recipes'][0]['title'] == 'Mercimek çorbası'
    assert value['plan']['entries'][0]['personId'] == person['ref']['id']

    changed = client.put(root, headers=auth(admin), json={
        **body,
        'recipes': [{**body['recipes'][0], 'title': 'Değişen tarif'}],
    })
    assert changed.status_code == 409
    assert changed.json()['error']['code'] == 'idempotency_conflict'

    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(root, headers=auth(admin)).json() == value
        durable_replay = restarted.put(root, headers=auth(admin), json=body)
        assert durable_replay.status_code == 200
        assert durable_replay.json() == value


def test_person_grant_and_account_scope_are_rechecked_fail_closed(server):
    app, client, _, _ = server
    admin = ready(server)
    create_user(client, admin)
    member = activate(client, 'member')
    create_user(client, admin, name='other')
    other = activate(client, 'other')
    root, people_root = roots(app)
    person = create_person(client, admin, people_root)
    grant = client.put(
        f"{people_root}/{person['ref']['id']}/grants/{member['user']['id']}",
        headers=auth(admin),
        json={
            'expectedAclRevision': person['aclRevision'],
            'permissions': {'read': True, 'write': True},
        },
    )
    assert grant.status_code == 200, grant.text
    person = client.get(
        f"/api/v1/home-people/{app.state.core.context.coreId}/"
        f"{app.state.core.context.homeId}/{person['ref']['id']}",
        headers=auth(member),
    ).json()['person']
    body = plan_body(
        person,
        account_revision(client, admin, member['user']['id']),
    )
    assert client.put(root, headers=auth(member), json=body).status_code == 200
    assert client.get(root, headers=auth(other)).json()['plan'] is None

    revoked = client.put(
        f"{people_root}/{person['ref']['id']}/grants/{member['user']['id']}",
        headers=auth(admin),
        json={
            'expectedAclRevision': person['aclRevision'],
            'permissions': {'read': False, 'write': False},
        },
    )
    assert revoked.status_code == 200
    hidden = client.get(root, headers=auth(member))
    assert hidden.status_code == 404
    assert hidden.json()['error']['code'] == 'not_found'


def test_stale_malformed_limits_and_tamper_never_change_plan(server):
    app, client, settings, _ = server
    admin = ready(server)
    root, people_root = roots(app)
    person = create_person(client, admin, people_root)
    revision = account_revision(client, admin, admin['user']['id'])
    body = plan_body(person, revision)
    created = client.put(root, headers=auth(admin), json=body).json()

    stale = client.put(root, headers=auth(admin), json={
        **plan_body(person, revision, request_id='b' * 32),
        'expectedRevision': 0,
    })
    assert stale.status_code == 409
    assert client.get(root, headers=auth(admin)).json() == created

    oversized = {
        **plan_body(person, revision, request_id='c' * 32, revision=1),
        'recipes': [
            {**body['recipes'][0], 'id': f'{index:032x}'}
            for index in range(1, 34)
        ],
        'entries': [],
    }
    assert client.put(root, headers=auth(admin), json=oversized).status_code in (400, 413)

    malformed = {
        **plan_body(person, revision, request_id='d' * 32, revision=1),
        'entries': [{**body['entries'][0], 'date': '2026-09-29'}],
    }
    assert client.put(root, headers=auth(admin), json=malformed).status_code == 400
    assert client.get(root, headers=auth(admin)).json() == created

    with app.state.core.db.connection() as connection:
        raw = '\n'.join(connection.iterdump())
    assert 'Mercimek çorbası' not in raw
    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE meal_plan_records SET ciphertext=X'00'")
    with pytest.raises(StartupError, match='meal_plan_storage_invalid'):
        create_app(settings)
