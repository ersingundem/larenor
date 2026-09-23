import json
import time

import pytest

from larenor_server.plugins.jellyfin_playback_runtime import (
    JellyfinPlaybackProtocol,
    JellyfinPlaybackRuntimeError,
)
from larenor_server.plugins.media_playback_models import (
    PrivateMediaPlaybackAction,
)


TOKEN = 'k' * 32
INSTALLATION = 'a' * 32
ITEM = 'b' * 32


class Connection:
    def __init__(self, response):
        self.response = bytearray(response)
        self.sent = bytearray()
        self.closed = False

    def settimeout(self, _value):
        pass

    def sendall(self, value):
        self.sent.extend(value)

    def recv(self, count):
        value = bytes(self.response[:count])
        del self.response[:count]
        return value

    def close(self):
        self.closed = True


def response(status, body=b'', content_type=True):
    headers = [f'HTTP/1.1 {status}\r\n'.encode(), b'Connection: close\r\n']
    if content_type:
        headers.append(b'Content-Type: application/json\r\n')
    if status != '204 No Content':
        headers.append(f'Content-Length: {len(body)}\r\n'.encode())
    return b''.join(headers) + b'\r\n' + body


def sessions(*, item=None, position=0, available=True):
    body = [{
        'Id': 'c' * 32,
        'DeviceName': 'Living Room TV',
        'SupportsMediaControl': available,
        'SupportedCommands': ['Play', 'PlayState'],
        'NowPlayingItem': None if item is None else {'Id': item},
        'PlayState': {'PositionTicks': position * 10_000_000},
    }]
    return json.dumps(body, separators=(',', ':')).encode()


def action(**changes):
    values = {
        'requestId': 'd' * 32,
        'intentId': 'e' * 32,
        'installationId': INSTALLATION,
        'installationRevision': 4,
        'snapshotRevision': 8,
        'jellyfinServiceRevision': 6,
        'itemId': ITEM,
        'mediaKey': 'movie:tmdb:603',
        'expectedPlaybackRevision': 100,
        'targetId': 'c' * 32,
        'expectedTargetRevision': 100,
        'startSeconds': 12,
    }
    return PrivateMediaPlaybackAction(**(values | changes))


def test_reads_only_controllable_sessions_over_exact_authenticated_route():
    connection = Connection(response('200 OK', sessions()))
    runtime = JellyfinPlaybackProtocol(revision_seed=100)

    result = runtime.read(
        connection, api_key=TOKEN, installation_id=INSTALLATION,
        deadline=time.monotonic() + 1,
    )

    assert result.model_dump() == {
        'playbackRevision': 100,
        'targets': [{
            'targetId': 'c' * 32, 'targetRevision': 100,
            'name': 'Living Room TV', 'available': True,
            'currentItemId': None, 'positionSeconds': 0,
        }],
    }
    wire = bytes(connection.sent)
    assert wire.startswith(b'GET /Sessions HTTP/1.1\r\n')
    assert b'Host: jellyfin\r\n' in wire
    assert b'Authorization: MediaBrowser Client="Larenor%20Core"' in wire
    assert (b'DeviceId="' + INSTALLATION.encode() + b'"') in wire
    assert TOKEN.encode() in wire and wire.endswith(b'\r\n\r\n')
    assert connection.closed
    assert TOKEN not in repr(result) + repr(runtime)


def test_readback_floors_valid_subsecond_jellyfin_ticks():
    body = json.loads(sessions())
    body[0]['PlayState']['PositionTicks'] = 125_000_000
    runtime = JellyfinPlaybackProtocol(revision_seed=100)

    result = runtime.read(
        Connection(response('200 OK', json.dumps(body).encode())),
        api_key=TOKEN, installation_id=INSTALLATION,
        deadline=time.monotonic() + 1)

    assert result.targets[0].positionSeconds == 12


def test_play_now_is_one_post_between_matching_before_and_authenticated_after_readback():
    runtime = JellyfinPlaybackProtocol(revision_seed=100)
    runtime.read(
        Connection(response('200 OK', sessions())), api_key=TOKEN,
        installation_id=INSTALLATION, deadline=time.monotonic() + 1,
    )
    before = Connection(response('200 OK', sessions()))
    effect = Connection(response('204 No Content', content_type=False))
    after = Connection(response('200 OK', sessions(item=ITEM, position=12)))

    result = runtime.execute(
        (before, effect, after), action(), api_key=TOKEN,
        deadline=time.monotonic() + 1,
    )

    assert result.state == 'succeeded'
    assert result.playbackRevision == 101
    assert result.target.targetRevision == 101
    assert result.target.currentItemId == ITEM
    assert result.target.positionSeconds == 12
    wire = bytes(effect.sent)
    assert wire.count(b'POST ') == 1
    assert wire.startswith(
        b'POST /Sessions/' + b'c' * 32 +
        b'/Playing?itemIds=' + ITEM.encode() +
        b'&playCommand=PlayNow&startPositionTicks=120000000 HTTP/1.1\r\n')
    assert all(connection.closed for connection in (before, effect, after))


def test_pre_effect_gate_and_deadline_expiry_never_write_playback(
        monkeypatch):
    now = [100.0]
    monkeypatch.setattr(
        'larenor_server.plugins.jellyfin_playback_runtime.time.monotonic',
        lambda: now[0])
    runtime = JellyfinPlaybackProtocol(revision_seed=100)
    runtime.read(
        Connection(response('200 OK', sessions())), api_key=TOKEN,
        installation_id=INSTALLATION, deadline=101.0)
    before = Connection(response('200 OK', sessions()))
    effect = Connection(response('204 No Content', content_type=False))
    after = Connection(response('200 OK', sessions(item=ITEM, position=12)))

    def gate():
        now[0] = 101.0
        return True

    with pytest.raises(JellyfinPlaybackRuntimeError,
                       match='^jellyfin_playback_authority_changed$'):
        runtime.execute(
            (before, effect, after), action(), api_key=TOKEN,
            deadline=101.0, gate=gate)

    assert effect.sent == b''
    assert all(connection.closed for connection in (before, effect, after))


@pytest.mark.parametrize('damage', [
    'float_ticks', 'negative_ticks', 'duplicate_session', 'wrong_target',
    'no_state_change', 'trailing_204', 'wrong_status', 'bad_json',
])
def test_changed_or_ambiguous_effect_never_returns_success(damage):
    runtime = JellyfinPlaybackProtocol(revision_seed=100)
    runtime.read(
        Connection(response('200 OK', sessions())), api_key=TOKEN,
        installation_id=INSTALLATION, deadline=time.monotonic() + 1,
    )
    before_body = sessions()
    effect_raw = response('204 No Content', content_type=False)
    after_body = sessions(item=ITEM, position=12)
    selected_action = action()
    if damage == 'float_ticks':
        parsed = json.loads(after_body)
        parsed[0]['PlayState']['PositionTicks'] = 120000000.0
        after_body = json.dumps(parsed).encode()
    elif damage == 'negative_ticks':
        parsed = json.loads(after_body)
        parsed[0]['PlayState']['PositionTicks'] = -1
        after_body = json.dumps(parsed).encode()
    elif damage == 'duplicate_session':
        after_body = json.dumps(json.loads(after_body) * 2).encode()
    elif damage == 'wrong_target':
        selected_action = action(targetId='f' * 32)
    elif damage == 'no_state_change':
        after_body = sessions()
    elif damage == 'trailing_204':
        effect_raw += b'x'
    elif damage == 'wrong_status':
        effect_raw = response('200 OK', b'{}')
    elif damage == 'bad_json':
        after_body = b'{'
    connections = (
        Connection(response('200 OK', before_body)),
        Connection(effect_raw),
        Connection(response('200 OK', after_body)),
    )

    with pytest.raises(JellyfinPlaybackRuntimeError):
        runtime.execute(
            connections, selected_action, api_key=TOKEN,
            deadline=time.monotonic() + 1,
        )


@pytest.mark.parametrize('token', ['', 'x' * 31, 'x' * 129, True, None])
def test_invalid_private_auth_never_writes(token):
    connection = Connection(response('200 OK', sessions()))
    runtime = JellyfinPlaybackProtocol(revision_seed=100)
    with pytest.raises(JellyfinPlaybackRuntimeError):
        runtime.read(
            connection, api_key=token, installation_id=INSTALLATION,
            deadline=time.monotonic() + 1,
        )
    assert connection.sent == b''
