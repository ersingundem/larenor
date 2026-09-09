"""Bounded first-run Jellyfin setup over an already verified connection."""

import inspect
import json
import socket
import time

import pytest

from larenor_server.plugins.jellyfin_startup import (
    JellyfinStartupConfigurator, JellyfinStartupError, JellyfinStartupLimits,
)
from larenor_server.plugins.media_service_bootstrap_models import PrivateMediaServiceBootstrap


SECRET = 'Synthetic-private-bootstrap-secret-0123456789'


def response(status=204, body=b'', *, content_type=None, extra=b''):
    reason = b'OK' if status == 200 else b'No Content'
    headers = b'' if content_type is None else b'Content-Type: ' + content_type + b'\r\n'
    return (b'HTTP/1.1 ' + str(status).encode() + b' ' + reason + b'\r\n'
            + headers + b'Content-Length: ' + str(len(body)).encode() + b'\r\n'
            + extra + b'\r\n' + body)


def happy_responses(first_user=None):
    raw = json.dumps(first_user if first_user is not None else {
        'Name': 'jellyfin', 'Password': None,
    }, separators=(',', ':')).encode()
    return [response(200, raw, content_type=b'application/json'),
            response(), response(), response(), response()]


def chunked(body):
    return (b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
            b'Transfer-Encoding: chunked\r\n\r\n'
            + f'{len(body):x}\r\n'.encode() + body + b'\r\n0\r\n\r\n')


class Connection:
    def __init__(self, replies):
        self.replies = bytearray(b''.join(replies))
        self.requests = []
        self.closed = False
        self.timeouts = []

    def sendall(self, value):
        assert not self.closed
        self.requests.append(bytes(value))

    def recv(self, count):
        if not self.replies:
            return b''
        value = bytes(self.replies[:count])
        del self.replies[:count]
        return value

    def settimeout(self, value):
        self.timeouts.append(value)

    def shutdown(self, _how):
        self.closed = True

    def close(self):
        self.closed = True


def private(**changes):
    values = dict(credential=SECRET)
    values.update(changes)
    return PrivateMediaServiceBootstrap(**values)


def split_request(raw):
    head, body = raw.split(b'\r\n\r\n', 1)
    return head.split(b'\r\n'), body


def test_exact_official_startup_sequence_uses_one_preconnected_stream(monkeypatch):
    connection = Connection(happy_responses())
    monkeypatch.setattr(socket, 'socket', lambda *_a, **_k: (_ for _ in ()).throw(
        AssertionError('startup adapter must not select or open a network target')))

    result = JellyfinStartupConfigurator().configure(connection, private())

    assert result.state == 'succeeded'
    assert result.completed_steps == ('observed_unconfigured', 'configuration_updated',
                                      'user_updated', 'remote_access_updated', 'wizard_completed')
    assert len(connection.requests) == 5 and connection.closed
    expected = [
        ('GET /Startup/User HTTP/1.1', None),
        ('POST /Startup/Configuration HTTP/1.1', {
            'UICulture': 'tr-TR', 'MetadataCountryCode': 'TR',
            'PreferredMetadataLanguage': 'tr',
        }),
        ('POST /Startup/User HTTP/1.1', {
            'Name': 'larenor-system', 'Password': SECRET,
        }),
        ('POST /Startup/RemoteAccess HTTP/1.1', {
            'EnableRemoteAccess': False,
            'EnableAutomaticPortMapping': False,
        }),
        ('POST /Startup/Complete HTTP/1.1', None),
    ]
    for index, (line, value) in enumerate(expected):
        head, body = split_request(connection.requests[index])
        assert head[0] == line.encode()
        assert b'Host: jellyfin' in head and b'Accept-Encoding: identity' in head
        assert (b'Connection: close' in head) is (index == 4)
        assert (b'Connection: keep-alive' in head) is (index < 4)
        if value is None:
            assert body == b''
        else:
            assert json.loads(body) == value


@pytest.mark.parametrize('first_user', [
    {'Name': None, 'Password': 'configured'},
    {'Name': ' bad\nname ', 'Password': None},
    {'Name': '', 'Password': '', 'Unexpected': True}, [], 'invalid-json',
])
def test_only_a_strict_unconfigured_first_user_can_trigger_writes(first_user):
    raw = (first_user.encode() if isinstance(first_user, str)
           else json.dumps(first_user, separators=(',', ':')).encode())
    connection = Connection([response(200, raw, content_type=b'application/json')])
    with pytest.raises(JellyfinStartupError) as raised:
        JellyfinStartupConfigurator().configure(connection, private())
    expected = ('jellyfin_already_configured' if isinstance(first_user, dict)
                and first_user.get('Password') else 'jellyfin_startup_protocol')
    assert raised.value.code == expected
    assert raised.value.completed_steps == () and not raised.value.uncertain_effect
    assert len(connection.requests) == 1


def test_duplicate_first_user_json_is_rejected_before_any_write():
    body = b'{"Name":null,"Name":"other","Password":null}'
    connection = Connection([response(200, body, content_type=b'application/json')])
    with pytest.raises(JellyfinStartupError, match='^jellyfin_startup_protocol$') as raised:
        JellyfinStartupConfigurator().configure(connection, private())
    assert raised.value.completed_steps == () and len(connection.requests) == 1


def test_first_time_policy_rejection_is_reported_as_already_configured():
    connection = Connection([response(401, b'{}', content_type=b'application/json')])
    with pytest.raises(JellyfinStartupError, match='^jellyfin_already_configured$') as raised:
        JellyfinStartupConfigurator().configure(connection, private())
    assert raised.value.completed_steps == () and not raised.value.uncertain_effect
    assert len(connection.requests) == 1


def test_bounded_chunked_first_user_response_is_supported():
    connection = Connection([
        chunked(b'{"Name":null,"Password":null}'),
        response(), response(), response(), response(),
    ])
    assert JellyfinStartupConfigurator().configure(connection, private()).state == 'succeeded'
    assert len(connection.requests) == 5


@pytest.mark.parametrize('reply', [
    response(302, extra=b'Location: http://private.invalid/\r\n'),
    response(500, b'private daemon error', content_type=b'application/json'),
    b'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n',
])
def test_mutation_failure_is_static_partial_and_never_retried_or_redirected(reply):
    connection = Connection([happy_responses()[0], reply])
    with pytest.raises(JellyfinStartupError) as raised:
        JellyfinStartupConfigurator().configure(connection, private())
    assert raised.value.code == 'jellyfin_startup_protocol'
    assert raised.value.completed_steps == ('observed_unconfigured',)
    assert raised.value.uncertain_effect
    assert len(connection.requests) == 2
    assert SECRET not in str(raised.value) + repr(raised.value)


def test_response_body_and_header_framing_are_bounded():
    huge = b'x' * 4097
    cases = [
        response(200, huge, content_type=b'application/json'),
        b'HTTP/1.1 200 OK\r\nX-Huge: ' + b'x' * 33000 + b'\r\n\r\n',
        b'HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}',
    ]
    for reply in cases:
        connection = Connection([reply])
        with pytest.raises(JellyfinStartupError, match='^jellyfin_startup_protocol$') as raised:
            JellyfinStartupConfigurator().configure(connection, private())
        assert raised.value.completed_steps == () and len(connection.requests) == 1


def test_connection_loss_after_write_is_an_uncertain_static_failure():
    connection = Connection([happy_responses()[0]])
    with pytest.raises(JellyfinStartupError, match='^jellyfin_startup_unavailable$') as raised:
        JellyfinStartupConfigurator().configure(connection, private())
    assert raised.value.completed_steps == ('observed_unconfigured',)
    assert raised.value.uncertain_effect and len(connection.requests) == 2
    assert SECRET not in str(raised.value) + repr(raised.value)


def test_total_deadline_closes_a_stalled_preconnected_stream():
    class Stalled(Connection):
        def recv(self, _count):
            time.sleep(0.015)
            raise socket.timeout()

    connection = Stalled([])
    with pytest.raises(JellyfinStartupError, match='^jellyfin_startup_timeout$') as raised:
        JellyfinStartupConfigurator().configure(
            connection, private(),
            limits=JellyfinStartupLimits(total_seconds=0.01, max_response_bytes=4096))
    assert raised.value.completed_steps == () and not raised.value.uncertain_effect
    assert connection.closed and len(connection.requests) == 1


@pytest.mark.parametrize('payload,limits', [
    ('private', JellyfinStartupLimits()),
    (private(), 'limits'),
    (private(), JellyfinStartupLimits(total_seconds=0.01, max_response_bytes=4096)),
])
def test_closed_input_surface_has_no_url_retry_or_ambient_auth(payload, limits):
    connection = Connection(happy_responses())
    if payload == 'private':
        expected = 'invalid_jellyfin_startup_request'
    elif limits == 'limits':
        expected = 'invalid_jellyfin_startup_limits'
    else:
        object.__setattr__(payload, 'credential', 'changed after validation')
        expected = 'invalid_jellyfin_startup_request'
    with pytest.raises(JellyfinStartupError, match='^' + expected + '$'):
        JellyfinStartupConfigurator().configure(connection, payload, limits=limits)
    assert connection.requests == []
    parameters = inspect.signature(JellyfinStartupConfigurator.configure).parameters
    assert not {'url', 'host', 'port', 'resolver', 'proxy', 'headers', 'token'} & set(parameters)


def test_private_values_are_hidden_from_models_and_errors():
    payload = private()
    error = JellyfinStartupError('jellyfin_startup_unavailable',
                                  completed_steps=('observed_unconfigured',),
                                  uncertain_effect=True)
    assert SECRET not in repr(payload) + str(error) + repr(error)
    assert error.code == 'jellyfin_startup_unavailable'
