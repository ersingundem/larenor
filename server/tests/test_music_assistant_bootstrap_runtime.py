"""Private first-run Music Assistant bootstrap against the pinned engine."""

import json
import threading
import time

import pytest

from larenor_server.plugins.music_assistant_bootstrap_runtime import (
    MusicAssistantBootstrapRuntime,
    MusicAssistantBootstrapRuntimeError,
)


INSTALLATION = 'a' * 32
USERNAME = 'larenor-core'
PASSWORD = 'S' * 48
SHORT_TOKEN = 'short-private-token'
LONG_TOKEN = 'long-private-token'
USER_ID = 'user-fixture'


class Response:
    def __init__(self, value, status=200):
        self.status = status
        self.raw = json.dumps(value, separators=(',', ':')).encode()

    def read(self, _limit):
        return self.raw


class Connection:
    def __init__(self, responses, calls, fail_request=False):
        self.responses, self.calls = responses, calls
        self.fail_request = fail_request

    def request(self, method, path, body, headers):
        self.calls.append((method, path, json.loads(body), headers))
        if self.fail_request:
            raise OSError('private transport detail')

    def getresponse(self):
        return self.responses.pop(0)

    def close(self):
        pass


def rpc(step, result):
    return Response({'message_id': INSTALLATION + '-' + step, 'result': result})


def valid_responses():
    user = {'user_id': USER_ID, 'username': USERNAME, 'role': 'admin'}
    info = {'server_id': 'mass-fixture', 'server_version': '2.10.2',
            'schema_version': 65}
    return [
        Response({'success': True, 'token': SHORT_TOKEN, 'user': user}),
        rpc('long-token', LONG_TOKEN),
        rpc('user', user),
        rpc('info-before', info),
        rpc('onboard', None),
        rpc('logout', None),
        rpc('info-after', info),
    ]


def runtime(responses, calls):
    return MusicAssistantBootstrapRuntime(
        lambda _timeout: Connection(responses, calls))


def test_creates_internal_admin_long_token_and_verified_readback_once():
    calls = []
    result = runtime(valid_responses(), calls).create(
        installation_id=INSTALLATION, username=USERNAME, credential=PASSWORD,
        deadline=time.monotonic() + 2)

    assert result.token == LONG_TOKEN
    assert result.serverId == 'mass-fixture'
    assert result.serverVersion == '2.10.2'
    assert result.schemaVersion == 65
    assert [(call[0], call[1]) for call in calls] == [
        ('POST', '/setup'), ('POST', '/api'), ('POST', '/api'),
        ('POST', '/api'), ('POST', '/api'), ('POST', '/api'),
        ('POST', '/api')]
    assert calls[0][2] == {
        'username': USERNAME, 'password': PASSWORD,
        'device_name': 'Larenor Core'}
    assert [call[2].get('command') for call in calls[1:]] == [
        'auth/token/create', 'auth/me', 'info',
        'config/onboard_complete', 'auth/logout', 'info']
    assert calls[1][2]['args'] == {'name': 'Larenor Core'}
    assert calls[1][3]['Authorization'] == 'Bearer ' + SHORT_TOKEN
    assert calls[2][3]['Authorization'] == 'Bearer ' + LONG_TOKEN
    assert calls[5][3]['Authorization'] == 'Bearer ' + SHORT_TOKEN
    assert PASSWORD not in repr(result)
    assert SHORT_TOKEN not in repr(result)
    assert LONG_TOKEN not in repr(result)


@pytest.mark.parametrize('changed', [
    {'server_id': 'mass-fixture', 'server_version': '2.7.11', 'schema_version': 65},
    {'server_id': 'mass-fixture', 'server_version': '2.10.2', 'schema_version': 64},
    {'server_id': 'other', 'server_version': '2.10.2', 'schema_version': 65},
])
def test_rejects_vulnerable_wrong_schema_or_changed_post_bootstrap_identity(changed):
    responses = valid_responses()
    if changed['server_id'] == 'other':
        responses[-1] = rpc('info-after', changed)
    else:
        responses[3] = rpc('info-before', changed)
    with pytest.raises(
            MusicAssistantBootstrapRuntimeError,
            match='^music_assistant_bootstrap_readback_changed$') as raised:
        runtime(responses, []).create(
            installation_id=INSTALLATION, username=USERNAME,
            credential=PASSWORD, deadline=time.monotonic() + 2)
    assert PASSWORD not in repr(raised.value)


def test_cancel_and_invalid_input_send_nothing():
    for values in [
        {'installation_id': 'short'},
        {'username': 'admin'},
        {'credential': 'short'},
    ]:
        calls = []
        args = {'installation_id': INSTALLATION, 'username': USERNAME,
                'credential': PASSWORD, 'deadline': time.monotonic() + 2}
        args.update(values)
        with pytest.raises(MusicAssistantBootstrapRuntimeError,
                           match='^invalid_music_assistant_bootstrap$'):
            runtime([], calls).create(**args)
        assert calls == []

    calls = []
    cancelled = threading.Event()
    cancelled.set()
    with pytest.raises(MusicAssistantBootstrapRuntimeError,
                       match='^music_assistant_bootstrap_cancelled$'):
        runtime([], calls).create(
            installation_id=INSTALLATION, username=USERNAME,
            credential=PASSWORD, deadline=time.monotonic() + 2,
            cancelled=cancelled)
    assert calls == []


def test_setup_transport_failure_is_uncertain_and_secret_free_without_retry():
    calls = []
    target = MusicAssistantBootstrapRuntime(
        lambda _timeout: Connection([], calls, fail_request=True))
    with pytest.raises(MusicAssistantBootstrapRuntimeError) as raised:
        target.create(
            installation_id=INSTALLATION, username=USERNAME,
            credential=PASSWORD, deadline=time.monotonic() + 2)
    assert str(raised.value) == 'music_assistant_bootstrap_uncertain'
    assert raised.value.uncertain_effect is True
    assert len(calls) == 1
    assert PASSWORD not in str(raised.value) + repr(raised.value)
