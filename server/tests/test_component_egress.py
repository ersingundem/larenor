"""F13 runtime contract; all endpoints and addresses are synthetic."""
from types import SimpleNamespace

from conftest import auth, ready
from test_services import BASE, create


def policy_url(record):
    return BASE + '/' + record['id'] + '/outbound-policy'


def check_url(record):
    return BASE + '/' + record['id'] + '/check'


def grant_body(*, expected=0, service_revision=1, address='10.20.30.40', host='ha.example.test'):
    return {'expectedRevision': expected, 'expectedServiceRevision': service_revision,
            'grants': [{'scheme': 'https', 'host': host, 'port': 443,
                        'addresses': [{'address': address, 'network': 'lan'}]}]}


def test_existing_ha_check_denied_without_grant_and_without_probe(server):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair, baseUrl='https://ha.example.test')
    calls = []
    app.state.core.service_probe._probe = lambda connection: (calls.append(connection), SimpleNamespace(state='authenticated', version='2026.9.0'))[1]
    response = client.post(check_url(record), headers=auth(pair), json={'expectedRevision': 1})
    assert response.status_code == 403, response.text
    assert response.json()['error']['code'] == 'outbound_denied'
    assert calls == []
    assert client.get(BASE, headers=auth(pair)).json()['services'][0]['verification']['state'] == 'never'


def test_admin_can_read_and_replace_exact_revision_bound_policy(server):
    app, client, _, _ = server
    pair = ready(server)
    record = create(client, pair, baseUrl='https://ha.example.test')
    response = client.get(policy_url(record), headers=auth(pair))
    assert response.status_code == 200, response.text
    assert response.json()['policy']['grants'] == []
    changed = client.put(policy_url(record), headers=auth(pair), json=grant_body())
    assert changed.status_code == 200, changed.text
    assert changed.json()['policy']['revision'] == 1
    assert changed.json()['policy']['component'] == 'home_assistant_probe'
    assert changed.json()['policy']['grants'] == grant_body()['grants']
    assert 'token' not in changed.text
    assert client.put(policy_url(record), headers=auth(pair), json=grant_body()).status_code == 409


def test_loopback_metadata_and_implicit_private_grants_are_rejected(server):
    _, client, _, _ = server
    pair = ready(server)
    record = create(client, pair, baseUrl='https://ha.example.test')
    for address in ('127.0.0.1', '169.254.169.254', '::1', '100.100.100.200'):
        response = client.put(policy_url(record), headers=auth(pair), json=grant_body(address=address))
        assert response.status_code == 400, response.text
    body = grant_body()
    body['grants'][0]['addresses'][0]['network'] = 'public'
    assert client.put(policy_url(record), headers=auth(pair), json=body).status_code == 400
