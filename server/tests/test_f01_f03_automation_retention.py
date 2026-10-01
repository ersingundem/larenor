"""Authenticated history retention through normal Core HTTP and restart.

The owned HA TCP fixture is never commanded by drafts or simulation history.
Small-cap boundary cases complement the actual 256/128 production limits.
"""
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from conftest import auth, login, ready
from larenor_server.app import create_app
from larenor_server.automation_drafts import service as drafts_module
from larenor_server.automation_trials import service as trials_module
from test_f01_f03_automation_final import _draft_body, _event_body, _trial_body
from test_home_assistant_adapter import bind, ha, setup

WINDOW = 86400


def _new_headers(client, *, same_family=False):
    response = (
        client.post('/api/v1/auth/refresh', json={'refreshToken': client._retention_pair['refreshToken']})
        if same_family else login(client, 'admin', 'Synthetic new password 2026')
    )
    assert response.status_code == 200
    client._retention_pair = response.json()
    return auth(response.json())


def _drafts(server, ha):
    app, client, admin, record, _, base, _, binding_body = setup(server, ha)
    _, binding = bind(client, admin, base, binding_body)
    scope = app.state.core.context
    return app, client, auth(admin), f'/api/v1/automation-drafts/{scope.coreId}/{scope.homeId}', record, binding


def _trials(server):
    app, client, _, _ = server
    scope = app.state.core.context
    client._retention_pair = ready(server)
    return app, client, auth(client._retention_pair), f'/api/v1/automation-trials/{scope.coreId}/{scope.homeId}'


def _create_draft(client, root, headers, record, binding, index):
    return client.post(root, headers=headers, json=_draft_body(record, binding, request_key=f'draft-retain-{index:06d}'))


def _create_trial(client, root, headers, index, *, active=False):
    body = _trial_body(request_key=f'trial-retain-{index:06d}')
    if active:
        body['localStartDate'] = '2026-09-05'
    return client.post(root, headers=headers, json=body)


def _counts(app):
    with app.state.core.db.connection() as connection:
        return tuple(connection.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0] for table in ('automation_drafts', 'automation_trials', 'automation_trial_events'))


def test_f01_default_capacity_recovers_after_restart_without_device_write(server, ha):
    app, client, headers, root, record, binding = _drafts(server, ha)
    _, _, settings, clock = server
    for index in range(drafts_module.MAX_DRAFTS):
        response = _create_draft(client, root, headers, record, binding, index)
        assert response.status_code == 201, response.json()
        clock.now += 1
    assert _counts(app)[0] == 256
    clock.now += drafts_module.DRAFT_TTL_SECONDS + WINDOW + 1
    with TestClient(create_app(settings)) as restarted:
        response = _create_draft(restarted, root, _new_headers(restarted), record, binding, 256)
        assert response.status_code == 201, response.json()
    assert _counts(app)[0] == 1
    assert ha.command_calls == 0


def test_f02_default_capacity_recovers_after_restart(server):
    app, client, headers, root = _trials(server)
    _, _, settings, clock = server
    for index in range(trials_module.MAX_TRIALS):
        response = _create_trial(client, root, headers, index)
        assert response.status_code == 201
    assert _counts(app)[1] == 128
    clock.now += WINDOW + 1
    with TestClient(create_app(settings)) as restarted:
        response = _create_trial(restarted, root, _new_headers(restarted), 128)
        assert response.status_code == 201, response.json()
        assert response.json()['trial']['simulationOnly'] is True
        assert response.json()['trial']['adapterWriteCount'] == 0
    assert _counts(app)[1:] == (1, 0)


def test_f01_inclusive_replay_protection_and_activated_rule_survives_pruning(server, ha, monkeypatch):
    monkeypatch.setattr(drafts_module, 'MAX_DRAFTS', 2)
    app, client, headers, root, record, binding = _drafts(server, ha)
    _, _, _, clock = server
    first = _create_draft(client, root, headers, record, binding, 0).json()['draft']
    activation = {'schemaVersion': 1, 'requestKey': 'retain-activation', 'expectedDraftRevision': 1, 'confirmed': True}
    activated = client.post(f"{root}/{first['id']}/activation", headers=headers, json=activation)
    assert activated.status_code == 200
    rule_id = activated.json()['draft']['rule']['id']
    assert _create_draft(client, root, headers, record, binding, 1).status_code == 201
    clock.now += drafts_module.DRAFT_TTL_SECONDS + WINDOW
    headers = _new_headers(client)
    assert _create_draft(client, root, headers, record, binding, 2).status_code == 429
    assert _counts(app)[0] == 2
    clock.now += 0.001
    assert _create_draft(client, root, headers, record, binding, 2).status_code == 201
    assert _counts(app)[0] == 1
    with app.state.core.db.connection() as connection:
        assert connection.execute('SELECT COUNT(*) FROM automation_rule_records WHERE rule_id=?', (rule_id,)).fetchone()[0] == 1
    assert client.post(f"{root}/{first['id']}/activation", headers=headers, json=activation).status_code == 404
    assert ha.command_calls == 0


def test_f01_live_and_recent_duplicate_request_are_preserved(server, ha, monkeypatch):
    monkeypatch.setattr(drafts_module, 'MAX_DRAFTS', 2)
    app, client, headers, root, record, binding = _drafts(server, ha)
    first = _create_draft(client, root, headers, record, binding, 0)
    assert first.status_code == 201
    assert _create_draft(client, root, headers, record, binding, 1).status_code == 201
    assert _create_draft(client, root, headers, record, binding, 0).json() == first.json()
    assert _create_draft(client, root, headers, record, binding, 2).status_code == 429
    assert _counts(app)[0] == 2


def test_f01_tampered_expired_history_is_not_erased(server, ha, monkeypatch):
    monkeypatch.setattr(drafts_module, 'MAX_DRAFTS', 2)
    app, client, headers, root, record, binding = _drafts(server, ha)
    clock = server[3]
    for index in range(2):
        assert _create_draft(client, root, headers, record, binding, index).status_code == 201
    clock.now += drafts_module.DRAFT_TTL_SECONDS + WINDOW + 1
    headers = _new_headers(client)
    with app.state.core.db.transaction() as connection:
        connection.execute('UPDATE automation_drafts SET expires_at=0 WHERE request_key=?', ('draft-retain-000000',))
    assert _create_draft(client, root, headers, record, binding, 2).status_code == 503
    assert _counts(app)[0] == 2


def _event(client, root, headers, trial, index):
    return client.post(f"{root}/{trial['id']}/events", headers=headers, json=_event_body(datetime(2025, 10, 26, 12, tzinfo=timezone.utc), request_key=f'retain-event-{index:06d}', source='synthetic'))


def test_f03_expired_child_events_prune_together_and_current_trial_is_protected(server, monkeypatch):
    monkeypatch.setattr(trials_module, 'MAX_EVENTS', 2)
    app, client, headers, root = _trials(server)
    clock = server[3]
    old = _create_trial(client, root, headers, 0).json()['trial']
    assert _event(client, root, headers, old, 0).status_code == 201
    assert _event(client, root, headers, old, 1).status_code == 201
    clock.now += WINDOW + 1
    headers = _new_headers(client)
    current = _create_trial(client, root, headers, 1).json()['trial']
    appended = _event(client, root, headers, current, 2)
    assert appended.status_code == 201, appended.json()
    assert appended.json()['trial']['eventCount'] == 1
    assert _counts(app)[1:] == (1, 1)
    assert client.get(root, headers=headers).json()['trials'][0]['id'] == current['id']
    assert _event(client, root, headers, old, 0).status_code == 404


def test_f03_current_closed_trial_and_recent_event_replay_survive_capacity(server, monkeypatch):
    monkeypatch.setattr(trials_module, 'MAX_EVENTS', 2)
    app, client, headers, root = _trials(server)
    clock = server[3]
    old = _create_trial(client, root, headers, 0).json()['trial']
    assert _event(client, root, headers, old, 0).status_code == 201
    clock.now += WINDOW + 1
    headers = _new_headers(client, same_family=True)
    assert _event(client, root, headers, old, 1).status_code == 201
    duplicate = _event(client, root, headers, old, 1)
    assert duplicate.status_code == 201
    assert duplicate.json()['trial']['eventCount'] == 2
    assert _event(client, root, headers, old, 2).status_code == 429
    assert _counts(app)[1:] == (1, 2)


def test_f02_active_and_recent_trials_refuse_capacity_without_eviction(server, monkeypatch):
    monkeypatch.setattr(trials_module, 'MAX_TRIALS', 2)
    app, client, headers, root = _trials(server)
    clock = server[3]
    old = _create_trial(client, root, headers, 0).json()['trial']
    active = _create_trial(client, root, headers, 1, active=True).json()['trial']
    assert _create_trial(client, root, headers, 2).status_code == 429
    assert _create_trial(client, root, headers, 0).json()['trial']['id'] == old['id']
    clock.now += WINDOW + 1
    headers = _new_headers(client)
    assert _create_trial(client, root, headers, 2).status_code == 201
    with app.state.core.db.connection() as connection:
        assert connection.execute('SELECT COUNT(*) FROM automation_trials WHERE id=?', (active['id'],)).fetchone()[0] == 1
    assert _counts(app)[1] == 2


@pytest.mark.parametrize('table', ['automation_trials', 'automation_trial_events'])
def test_f03_tampered_history_fails_before_pruning(server, monkeypatch, table):
    monkeypatch.setattr(trials_module, 'MAX_TRIALS', 2)
    app, client, headers, root = _trials(server)
    clock = server[3]
    old = _create_trial(client, root, headers, 0).json()['trial']
    assert _event(client, root, headers, old, 0).status_code == 201
    assert _create_trial(client, root, headers, 1).status_code == 201
    clock.now += WINDOW + 1
    headers = _new_headers(client)
    with app.state.core.db.transaction() as connection:
        connection.execute('UPDATE ' + table + ' SET record_tag=?', ('0' * 64,))
    assert _create_trial(client, root, headers, 2).status_code == 503
    assert _counts(app)[1:] == (2, 1)


def test_clock_rollback_does_not_reclaim_authenticated_future_history(server, monkeypatch):
    monkeypatch.setattr(trials_module, 'MAX_TRIALS', 2)
    app, client, headers, root = _trials(server)
    clock = server[3]
    assert _create_trial(client, root, headers, 0).status_code == 201
    clock.now -= 1
    failed = _create_trial(client, root, headers, 1)
    assert failed.status_code == 503
    assert failed.json()['error']['code'] == 'server_unavailable'
    assert _counts(app)[1:] == (1, 0)


def test_f03_default_4096_event_history_recovers_after_normal_core_restart(server):
    app, client, headers, root = _trials(server)
    _, _, settings, clock = server
    service = app.state.core.automation_trials
    for index in range(8):
        trial = _create_trial(client, root, headers, index).json()['trial']
        assert _event(client, root, headers, trial, index * 512).status_code == 201
        with app.state.core.db.transaction() as connection:
            original = dict(connection.execute('SELECT * FROM automation_trial_events WHERE trial_id=?', (trial['id'],)).fetchone())
            # Bounded signed historical fixture copies the genuine evaluated
            # result; only IDs/request keys vary. No provider is substituted.
            for offset in range(1, 512):
                row = original | {'id': f'{index * 512 + offset:032x}', 'request_key': f'retain-event-{index * 512 + offset:06d}'}
                row['record_tag'] = service._event_tag(row)
                names = tuple(row)
                connection.execute('INSERT INTO automation_trial_events (' + ','.join(names) + ') VALUES (' + ','.join('?' for _ in names) + ')', tuple(row.values()))
    assert _counts(app)[1:] == (8, 4096)
    clock.now += WINDOW + 1
    with TestClient(create_app(settings)) as restarted:
        headers = _new_headers(restarted)
        current = _create_trial(restarted, root, headers, 8).json()['trial']
        response = _event(restarted, root, headers, current, 4096)
        assert response.status_code == 201, response.json()
        assert response.json()['trial']['eventCount'] == 1
    assert _counts(app)[1:] == (1, 1)


def test_f03_failed_current_trial_append_rolls_back_other_pruning(server, monkeypatch):
    monkeypatch.setattr(trials_module, 'MAX_EVENTS', 2)
    monkeypatch.setattr(trials_module, 'MAX_EVENTS_PER_TRIAL', 1)
    app, client, headers, root = _trials(server)
    clock = server[3]
    old = _create_trial(client, root, headers, 0).json()['trial']
    assert _event(client, root, headers, old, 0).status_code == 201
    current = _create_trial(client, root, headers, 1).json()['trial']
    assert _event(client, root, headers, current, 1).status_code == 201
    clock.now += WINDOW + 1
    headers = _new_headers(client, same_family=True)
    failed = _event(client, root, headers, current, 2)
    assert failed.status_code == 429
    assert _counts(app)[1:] == (2, 2)


def test_f03_signed_mismatched_child_authority_fails_before_pruning(server, monkeypatch):
    monkeypatch.setattr(trials_module, 'MAX_EVENTS', 1)
    app, client, headers, root = _trials(server)
    clock = server[3]
    old = _create_trial(client, root, headers, 0).json()['trial']
    assert _event(client, root, headers, old, 0).status_code == 201
    clock.now += WINDOW + 1
    headers = _new_headers(client)
    current = _create_trial(client, root, headers, 1).json()['trial']
    with app.state.core.db.transaction() as connection:
        row = dict(connection.execute('SELECT * FROM automation_trial_events').fetchone())
        row['family_id'] = 'f' * 32
        row['record_tag'] = app.state.core.automation_trials._event_tag(row)
        connection.execute('UPDATE automation_trial_events SET family_id=?,record_tag=?', (row['family_id'], row['record_tag']))
    assert _event(client, root, headers, current, 1).status_code == 503
    assert _counts(app)[1:] == (2, 1)
