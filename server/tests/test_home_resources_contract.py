"""Shared Client fixtures are actual authenticated HTTP, including opaque HMACs."""

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from uuid import UUID

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from test_admin import activate, create as create_user
from test_home_resource_registry import create, grant, paths
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.files import private_create


FIXTURE = Path(__file__).resolve().parents[2] / 'contracts/home-resources.v1.json'


def actual_journey(root, *, core_id='a' * 32, home_id='b' * 32):
    """Only generated identities and a synthetic test key are deterministic.

    Auth, password change, encryption, ACL, pagination and snapshot generation
    all use production code. Credentials and encrypted rows never enter JSON.
    """
    clock = Clock()
    settings = Settings(root / 'data', root / 'secrets/vault.key', clock=clock)
    private_create(settings.key_file, bytes(range(32)))  # Public fixture-only key.
    contexts = iter((core_id, home_id))
    core_ids = iter(('0' * 32, 'f' * 32))  # Initial temporary DB, admin account.
    with patch('larenor_server.context.secrets',
               SimpleNamespace(token_hex=lambda _: next(contexts))), \
         patch('larenor_server.core.uuid',
               SimpleNamespace(uuid4=lambda: UUID(hex=next(core_ids)))):
        app = create_app(settings)
    with TestClient(app) as client:
        admin = ready((app, client, settings, clock))
        with patch('larenor_server.admin.service.uuid',
                   SimpleNamespace(uuid4=lambda: UUID(hex='e' * 32))):
            create_user(client, admin)
        member = activate(client, 'member')
        public, base = paths(app)

        def get(path, pair, **params):
            response = client.get(path, headers=auth(pair), params=params)
            assert response.status_code == 200, response.text
            return response.json()

        result = {'context': get('/api/v1/context', admin)}
        records = []
        record_ids = iter(str(i) * 32 for i in range(1, 5))
        with patch('larenor_server.home_resources.service.uuid',
                   SimpleNamespace(uuid4=lambda: UUID(hex=next(record_ids)))):
            for kind, label, order in [('room', 'Salon', 1),
                                       ('room', 'Mutfak', 0),
                                       ('resource', 'Okuma lambası', 2),
                                       ('resource', '🌿' * 80, 10000)]:
                records.append(create(client, admin, base,
                                      kind=kind, label=label, order=order))
        result['emptyList'] = get(public, member)
        for index in (0, 2):
            grant(client, admin, base, records[index], member['user']['id'])
        result['adminList'] = get(public, admin)
        result['memberList'] = get(public, member)
        result['firstPage'] = get(public, member, limit=1)
        result['secondPage'] = get(public, member, limit=1,
                                  after=result['firstPage']['nextAfter'],
                                  expectedSnapshot=result['firstPage']['snapshot'])
        result['record'] = get(public + '/' + records[0]['ref']['id'], member)
        result['unicodeRecord'] = get(public + '/' + records[3]['ref']['id'], admin)
        grant(client, admin, base, records[0], member['user']['id'], revision=2, read=False)
        result['revokedList'] = get(public, member)
        stale = client.get(public, headers=auth(member), params={
            'limit': 1, 'after': result['firstPage']['nextAfter'],
            'expectedSnapshot': result['firstPage']['snapshot']})
        assert stale.status_code == 409
        result['stalePageError'] = stale.json()
        return result


def actual_contract(root):
    result = actual_journey(root / 'first')
    result['otherContextList'] = actual_journey(
        root / 'other', core_id='c' * 32, home_id='d' * 32)['memberList']
    return result


def test_shared_contract_matches_actual_authenticated_http(tmp_path):
    expected = json.loads(FIXTURE.read_text())
    assert actual_contract(tmp_path.resolve()) == expected


def test_shared_contract_preserves_visible_acl_and_pagination():
    fixture = json.loads(FIXTURE.read_text())
    first, second = fixture['firstPage'], fixture['secondPage']
    assert first['snapshot'] == second['snapshot'] == fixture['memberList']['snapshot']
    assert first['entries'] + second['entries'] == fixture['memberList']['entries']
    assert first['nextAfter'] == first['entries'][-1]['ref']['id']
    assert second['nextAfter'] is None
    assert all(r['permissions'] == {'read': True, 'write': False}
               for r in fixture['memberList']['entries'])
    assert fixture['emptyList']['entries'] == []
    assert fixture['emptyList']['snapshot'] != fixture['memberList']['snapshot']
    assert fixture['revokedList']['entries'] == second['entries']
    assert fixture['revokedList']['snapshot'] != first['snapshot']
    assert fixture['adminList']['snapshot'] != fixture['memberList']['snapshot']
    assert fixture['otherContextList']['scope'] != first['scope']
    assert len(fixture['unicodeRecord']['record']['label']) == 80


def test_other_core_labels_make_wrong_scope_rendering_observable():
    fixture = json.loads(FIXTURE.read_text())
    original = fixture['memberList']['entries']
    other = fixture['otherContextList']['entries']
    # Identical resource IDs are intentional: Core/home is part of identity.
    assert [r['ref']['id'] for r in original] == [r['ref']['id'] for r in other]
    assert {r['label'] for r in original}.isdisjoint(r['label'] for r in other)
