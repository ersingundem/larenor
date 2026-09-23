"""F13 explicit DNS review contract; all names and addresses are synthetic."""

import json
import socket
import threading

import pytest

from conftest import auth, ready
from test_admin import activate, create as create_user
from test_services import BASE, create


def url(record):
    return f"{BASE}/{record['id']}/outbound-policy/resolve"


def answer(address, port=443):
    family = socket.AF_INET6 if ':' in address else socket.AF_INET
    sockaddr = (address, port, 0, 0) if family == socket.AF_INET6 else (address, port)
    return family, socket.SOCK_STREAM, socket.IPPROTO_TCP, '', sockaddr


def setup(server, *, base_url='https://ha.example.test'):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair, baseUrl=base_url)
    return app, client, pair, record


def test_admin_reviews_all_bounded_canonical_answers_without_connection_or_write(server):
    app, client, pair, record = setup(server)
    calls = []
    app.state.core.component_egress.resolver = lambda host, port: (
        calls.append((host, port)),
        [answer('192.168.1.150'), answer('8.8.8.8'), answer('192.168.1.150')],
    )[1]

    response = client.post(url(record), headers=auth(pair), json={'expectedServiceRevision': 1})

    assert response.status_code == 200, response.text
    assert response.json() == {
        'schemaVersion': 1,
        'serviceId': record['id'],
        'serviceRevision': 1,
        'component': 'home_assistant_probe',
        'grant': {
            'scheme': 'https',
            'host': 'ha.example.test',
            'port': 443,
            'addresses': [
                {'address': '192.168.1.150', 'network': 'lan'},
                {'address': '8.8.8.8', 'network': 'public'},
            ],
        },
    }
    assert calls == [('ha.example.test', 443)]
    assert client.get(f"{BASE}/{record['id']}/outbound-policy", headers=auth(pair)).json()['policy']['grants'] == []
    with app.state.core.db.connection() as connection:
        dump = '\n'.join(connection.iterdump())
    assert '192.168.1.150' not in dump and '8.8.8.8' not in dump


def test_literal_host_never_calls_dns_and_uses_the_exact_address_class(server):
    app, client, pair, record = setup(server, base_url='http://10.20.30.40:8123')
    app.state.core.component_egress.resolver = lambda *_: pytest.fail('DNS used for literal')
    response = client.post(url(record), headers=auth(pair), json={'expectedServiceRevision': 1})
    assert response.status_code == 200, response.text
    assert response.json()['grant'] == {
        'scheme': 'http',
        'host': '10.20.30.40',
        'port': 8123,
        'addresses': [{'address': '10.20.30.40', 'network': 'lan'}],
    }


@pytest.mark.parametrize('mode', ['blocked', 'too_many', 'malformed'])
def test_resolution_fails_closed_without_partial_pins(server, mode):
    app, client, pair, record = setup(server)
    answers = {
        'blocked': [answer('169.254.169.254')],
        'too_many': [answer(f'10.20.30.{index}') for index in range(1, 10)],
        'malformed': [(socket.AF_INET, socket.SOCK_DGRAM, 0, '', ('10.20.30.40', 443))],
    }[mode]
    app.state.core.component_egress.resolver = lambda *_: answers
    response = client.post(url(record), headers=auth(pair), json={'expectedServiceRevision': 1})
    assert response.status_code == 503, response.text
    assert response.json()['error']['code'] == 'resolution_unavailable'
    assert '169.254' not in response.text and '10.20.30' not in response.text


def test_revision_change_during_dns_discards_every_answer(server):
    app, client, pair, record = setup(server)

    def resolver(_host, _port):
        changed = client.patch(
            f"{BASE}/{record['id']}",
            headers=auth(pair),
            json={
                'expectedRevision': 1,
                'name': 'Changed while resolving',
                'baseUrl': record['baseUrl'],
                'credentials': {},
            },
        )
        assert changed.status_code == 200, changed.text
        return [answer('192.168.1.150')]

    app.state.core.component_egress.resolver = resolver
    response = client.post(url(record), headers=auth(pair), json={'expectedServiceRevision': 1})
    assert response.status_code == 409, response.text
    assert response.json()['error']['code'] == 'revision_conflict'
    assert '192.168.1.150' not in response.text


def test_timeout_is_bounded_and_closed_request_never_starts_extra_dns(server):
    app, client, pair, record = setup(server)
    release = threading.Event()
    calls = []

    def resolver(*_):
        calls.append('dns')
        release.wait(1)
        return [answer('192.168.1.150')]

    app.state.core.component_egress.resolver = resolver
    app.state.core.component_egress.resolve_timeout = 0.01
    response = client.post(url(record), headers=auth(pair), json={'expectedServiceRevision': 1})
    assert response.status_code == 503
    assert response.json()['error']['code'] == 'resolution_unavailable'
    for bad_url, body in [
        (url(record) + '?retry=1', {'expectedServiceRevision': 1}),
        (url(record), {'expectedServiceRevision': True}),
        (url(record), {'expectedServiceRevision': 1, 'host': 'other.test'}),
    ]:
        assert client.post(bad_url, headers=auth(pair), json=body).status_code == 400
    release.set()
    assert calls == ['dns']


def test_admin_only_and_supported_service_only(server):
    app, client, pair, record = setup(server)
    app.state.core.component_egress.resolver = lambda *_: [answer('192.168.1.150')]
    create_user(client, pair)
    member = activate(client, 'member')
    assert client.post(url(record), headers=auth(member), json={'expectedServiceRevision': 1}).status_code == 403
    other = create(client, pair, kind='jellyfin')
    assert client.post(url(other), headers=auth(pair), json={'expectedServiceRevision': 1}).status_code == 404
    assert 'synthetic' not in json.dumps(client.post(url(record), headers=auth(pair), json={'expectedServiceRevision': 1}).json())
