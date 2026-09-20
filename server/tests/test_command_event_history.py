"""Monotonic, resource-authorized Home Assistant command event history."""
from fastapi.testclient import TestClient

from conftest import auth
from test_admin import activate, create as create_user
from test_home_assistant_adapter import ha
from test_home_assistant_commands import command_body
from test_command_history_safety import command_fixture, grant
from larenor_server.app import create_app


def test_events_preserve_pending_and_final_writes_with_stable_forward_cursor(server, ha):
    app, client, actor, record, _, binding, public = command_fixture(server, ha)
    body = command_body(record, binding, actor)
    sent = client.post(public + '/commands', headers=auth(actor), json=body)
    assert sent.status_code == 202, sent.text

    first = client.get(public + '/history/events?limit=1', headers=auth(actor))
    assert first.status_code == 200, first.text
    page = first.json()
    assert page['schemaVersion'] == 1 and page['ref'] == record['ref']
    assert len(page['chainId']) == 32 and page['verified'] is True
    assert page['headSequence'] == 2 and page['nextAfter'] == 1
    assert page['events'][0]['sequence'] == 1
    assert page['events'][0]['kind'] == 'command_write'
    assert page['events'][0]['receipt']['requestId'] == body['requestId']
    assert page['events'][0]['receipt']['dispatchState'] == 'pending'

    second = client.get(public + '/history/events?after=1&limit=1', headers=auth(actor))
    assert second.status_code == 200, second.text
    last = second.json()
    assert last['chainId'] == page['chainId'] and last['headSequence'] == 2
    assert last['nextAfter'] is None
    assert last['events'][0]['sequence'] == 2
    assert last['events'][0]['receipt'] == sent.json()['receipt']
    assert last['events'][0]['attribution']['correlationId'] == body['requestId']

    # An idempotent command read cannot fabricate another event.
    assert client.post(public + '/commands', headers=auth(actor), json=body).json() == sent.json()
    unchanged = client.get(public + '/history/events', headers=auth(actor)).json()
    assert unchanged['headSequence'] == 2 and len(unchanged['events']) == 2


def test_events_survive_restart_without_provider_io_or_replay(server, ha):
    app, client, actor, record, _, binding, public = command_fixture(server, ha)
    body = command_body(record, binding, actor)
    assert client.post(public + '/commands', headers=auth(actor), json=body).status_code == 202
    expected = client.get(public + '/history/events', headers=auth(actor)).json()
    counts = ha.calls, ha.command_calls

    with TestClient(create_app(server[2])) as restarted:
        response = restarted.get(public + '/history/events', headers=auth(actor))
        assert response.status_code == 200 and response.json() == expected
    assert (ha.calls, ha.command_calls) == counts


def test_events_reject_hidden_or_invalid_cursors_without_provider_io(server, ha):
    _, client, actor, record, _, binding, public = command_fixture(server, ha)
    body = command_body(record, binding, actor)
    assert client.post(public + '/commands', headers=auth(actor), json=body).status_code == 202
    counts = ha.calls, ha.command_calls

    assert client.get(public + '/history/events?after=3', headers=auth(actor)).status_code == 404
    for query in ('after=0', 'after=-1', 'after=true', 'after=01', 'after=1&after=2',
                  'limit=0', 'limit=51', 'before=' + 'f' * 32):
        response = client.get(public + '/history/events?' + query, headers=auth(actor))
        assert response.status_code == 400, (query, response.text)
    assert (ha.calls, ha.command_calls) == counts


def test_member_event_view_hides_admin_events_and_global_cursor(server, ha):
    _, client, admin, record, _, binding, public = command_fixture(server, ha)
    admin_body = command_body(record, binding, admin)
    assert client.post(public + '/commands', headers=auth(admin), json=admin_body).status_code == 202
    create_user(client, admin)
    member = activate(client, 'member')
    grant(client, admin, record['ref'], member, 1)
    member_body = command_body(record, binding, member, request_id='8' * 32)
    member_body['expectedAclRevision'] = 2
    assert client.post(public + '/commands', headers=auth(member), json=member_body).status_code == 202

    page = client.get(public + '/history/events', headers=auth(member))
    assert page.status_code == 200, page.text
    assert [event['sequence'] for event in page.json()['events']] == [1, 2]
    assert {event['receipt']['actorId'] for event in page.json()['events']} == {member['user']['id']}
    assert page.json()['headSequence'] == 2
    assert page.json()['chainId'] != client.get(
        public + '/history/events', headers=auth(admin)).json()['chainId']
    assert client.get(public + '/history/events?after=3', headers=auth(member)).status_code == 404
