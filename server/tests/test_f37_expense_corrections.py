"""Immutable F37 corrections, money projection and current authority."""
import pytest
from conftest import auth, ready
from larenor_server.errors import ApiError
from test_admin import activate, create as create_user
from test_f37_shared_expenses_api import _root


def _expense(client, pair, root):
    state = client.get(root, headers=auth(pair)).json()
    assert 1 <= state['authority']['membersRevision'] <= 2**53 - 1
    return {
        'schemaVersion': 1, 'commandId': '1' * 32,
        'expectedLedgerRevision': state['ledgerRevision'],
        'expectedMembersRevision': state['authority']['membersRevision'],
        'title': 'Shared bill', 'currency': 'TRY', 'totalMinor': 1001,
        'payerId': pair['user']['id'],
        'participantIds': [value['id'] for value in state['participants']],
    }


def _correction(original, body):
    return {**body, 'commandId': '2' * 32, 'expectedLedgerRevision': 2,
            'replacesId': original['id'], 'expectedRecordRevision': 1,
            'title': 'Corrected bill', 'totalMinor': 2001}


def test_correction_retains_original_exact_replay_and_terminal_balances(server):
    app, client, settings, clock = server
    admin = ready(server)
    create_user(client, admin)
    activate(client, 'member')
    root = _root(client, admin)
    body = _expense(client, admin, root)
    original = client.post(root + '/commands/create', headers=auth(admin), json=body).json()['record']
    correction = _correction(original, body)
    response = client.post(root + '/commands/correct', headers=auth(admin), json=correction)
    assert response.status_code == 201, response.text
    record = response.json()['record']
    assert record['replacesId'] == original['id']
    assert record['totalMinor'] == 2001
    assert client.post(root + '/commands/correct', headers=auth(admin), json=correction).json() == response.json()
    state = client.get(root, headers=auth(admin)).json()
    assert state['records'][0] == {**original, 'superseded': True}
    assert state['records'][1]['superseded'] is False
    assert state['ledgerRevision'] == 3 and len(state['records']) == 2
    owed = next(share['amountMinor'] for share in record['shares'] if share['accountId'] != admin['user']['id'])
    assert state['settlements'][0]['amountMinor'] == owed
    # A different command cannot branch the same historical record.
    duplicate = {**correction, 'commandId': '3' * 32, 'expectedLedgerRevision': 3}
    assert client.post(root + '/commands/correct', headers=auth(admin), json=duplicate).status_code == 409
    app.state.core.shared_expenses.store.validate_storage(core_id=app.state.core.context.coreId, home_id=app.state.core.context.homeId)
    with app.state.core.db.connection() as connection:
        assert connection.execute('SELECT COUNT(*) FROM shared_expense_records').fetchone()[0] == 2
        ciphertexts = connection.execute('SELECT ciphertext FROM shared_expense_records').fetchall()
        assert all(b'Corrected bill' not in row['ciphertext'] for row in ciphertexts)


def test_correction_denies_member_wrong_currency_stale_and_unknown_fields(server):
    app, client, settings, clock = server
    admin = ready(server)
    create_user(client, admin)
    member = activate(client, 'member')
    root = _root(client, admin)
    body = _expense(client, admin, root)
    original = client.post(root + '/commands/create', headers=auth(admin), json=body).json()['record']
    correction = _correction(original, body)
    assert client.post(root + '/commands/correct', headers=auth(member), json=correction).status_code == 403
    for patch in ({'currency': 'EUR'}, {'expectedRecordRevision': 2}, {'expectedLedgerRevision': 1}):
        assert client.post(root + '/commands/correct', headers=auth(admin), json={**correction, **patch}).status_code == 409
    assert client.post(root + '/commands/correct', headers=auth(admin), json={**correction, 'untrusted': True}).status_code == 400
    assert client.get(root, headers=auth(admin)).json()['ledgerRevision'] == 2


def test_write_guard_checks_current_members_inside_commit_transaction(server, monkeypatch):
    app, client, settings, clock = server
    admin = ready(server)
    root = _root(client, admin)
    body = _expense(client, admin, root)
    actual = app.state.core.shared_expenses.store._write_guard
    def revoked(connection, actor, request):
        connection.execute('UPDATE users SET revision=revision+1 WHERE id=?', (actor.id,))
        actual(connection, actor, request)
    monkeypatch.setattr(app.state.core.shared_expenses.store, '_write_guard', revoked)
    response = client.post(root + '/commands/create', headers=auth(admin), json=body)
    assert response.status_code in {401, 409}
    with app.state.core.db.connection() as connection:
        assert connection.execute('SELECT COUNT(*) FROM shared_expense_records').fetchone()[0] == 0


@pytest.mark.parametrize("path", ["snapshot", "export", "receipt", "missing_receipt"])
@pytest.mark.parametrize("change", ["members", "session"])
def test_reads_recheck_authority_after_ledger_capture(server, monkeypatch, path, change):
    app, client, settings, clock = server
    admin = ready(server)
    create_user(client, admin)
    member = activate(client, 'member')
    root = _root(client, admin)
    body = _expense(client, admin, root)
    assert client.post(root + '/commands/create', headers=auth(admin), json=body).status_code == 201
    store = app.state.core.shared_expenses.store
    method = 'export' if path in {'snapshot', 'export'} else 'receipt'
    original = getattr(store, method)

    def changed(*args, **kwargs):
        result = original(*args, **kwargs)
        with app.state.core.db.transaction() as connection:
            if change == 'members':
                connection.execute('UPDATE users SET disabled=1,revision=revision+1 WHERE id=?',
                                   (member['user']['id'],))
            else:
                connection.execute('UPDATE session_families SET revoked_at=? WHERE user_id=?',
                                   (clock(), admin['user']['id']))
        return result

    monkeypatch.setattr(store, method, changed)
    if path == 'snapshot':
        response = client.get(root, headers=auth(admin))
    elif path == 'export':
        response = client.post(root + '/export', headers=auth(admin),
                               json={'schemaVersion': 1, 'expectedLedgerRevision': 2})
    else:
        command = body['commandId'] if path == 'receipt' else 'f' * 32
        response = client.get(root + '/receipts/' + command, headers=auth(admin))
    assert response.status_code == (409 if change == 'members' else 401)
    assert 'records' not in response.json() and 'record' not in response.json()


def test_filtered_history_marks_superseded_without_exposing_hidden_correction(server):
    app, client, settings, clock = server
    admin = ready(server)
    create_user(client, admin)
    member = activate(client, 'member')
    root = _root(client, admin)
    body = _expense(client, admin, root)
    original = client.post(root + '/commands/create', headers=auth(admin), json=body).json()['record']
    create_user(client, admin, 'newcomer')
    newcomer = activate(client, 'newcomer')
    current = client.get(root, headers=auth(admin)).json()
    correction = {**_correction(original, body),
                  'expectedMembersRevision': current['authority']['membersRevision'],
                  'participantIds': [admin['user']['id'], newcomer['user']['id']]}
    response = client.post(root + '/commands/correct', headers=auth(admin), json=correction)
    assert response.status_code == 201, response.text
    replacement = response.json()['record']
    removed_view = client.get(root, headers=auth(member)).json()
    assert removed_view['records'] == [{**original, 'superseded': True}]
    assert all(value['amountMinor'] == 0 for value in removed_view['balances'])
    assert replacement['id'] not in str(removed_view)
    new_view = client.get(root, headers=auth(newcomer)).json()
    assert new_view['records'] == [replacement]
    assert new_view['records'][0]['replacesId'] == original['id']
    assert original['title'] not in str(new_view)
    receipt = client.get(root + '/receipts/' + body['commandId'], headers=auth(admin)).json()
    assert receipt['record'] == {**original, 'superseded': True}
    export = client.post(root + '/export', headers=auth(member),
                         json={'schemaVersion': 1, 'expectedLedgerRevision': 3})
    assert export.status_code == 200
    assert export.json()['records'] == removed_view['records']
