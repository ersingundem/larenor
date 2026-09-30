import base64
import time

import pytest

from larenor_server.plugins.jellyfin_playback_runtime import (
    JellyfinPlaybackProtocol,
    JellyfinPlaybackRuntimeError,
)
from test_jellyfin_playback_runtime import Connection


TOKEN = 'k' * 32
INSTALLATION = 'a' * 32
ITEM = 'b' * 32


def partial(content, *, start=4, total=8, content_range=None):
    end = start + len(content) - 1
    range_value = content_range or f'bytes {start}-{end}/{total}'
    return (
        b'HTTP/1.1 206 Partial Content\r\n'
        b'Connection: close\r\n'
        b'Content-Type: video/mp4\r\n'
        + f'Content-Length: {len(content)}\r\n'.encode()
        + f'Content-Range: {range_value}\r\n'.encode()
        + b'\r\n'
        + content
    )


def test_worker_reads_exact_authenticated_jellyfin_range_once():
    connection = Connection(partial(b'5678'))

    result = JellyfinPlaybackProtocol().read_offline_chunk(
        connection,
        api_key=TOKEN,
        installation_id=INSTALLATION,
        item_id=ITEM,
        offset=4,
        length=4,
        deadline=time.monotonic() + 1,
    )

    assert result.model_dump() == {
        'schemaVersion': 1,
        'itemId': ITEM,
        'offset': 4,
        'contentLength': 8,
        'contentType': 'video/mp4',
        'dataBase64': base64.b64encode(b'5678').decode(),
    }
    wire = bytes(connection.sent)
    assert wire.startswith(f'GET /Items/{ITEM}/Download HTTP/1.1\r\n'.encode())
    assert b'Range: bytes=4-7\r\n' in wire
    assert b'Authorization: MediaBrowser Client="Larenor%20Core"' in wire
    assert TOKEN.encode() in wire
    assert wire.count(b'GET ') == 1
    assert connection.closed is True
    assert TOKEN not in repr(result)


def test_worker_rejects_mismatched_content_range_without_retry():
    connection = Connection(partial(
        b'5678', content_range='bytes 0-3/8'))

    with pytest.raises(JellyfinPlaybackRuntimeError):
        JellyfinPlaybackProtocol().read_offline_chunk(
            connection,
            api_key=TOKEN,
            installation_id=INSTALLATION,
            item_id=ITEM,
            offset=4,
            length=4,
            deadline=time.monotonic() + 1,
        )

    assert bytes(connection.sent).count(b'GET ') == 1
    assert connection.closed is True


def test_worker_rejects_chunk_above_protocol_limit_before_network():
    connection = Connection(partial(b'x', start=0, total=1))

    with pytest.raises(
        JellyfinPlaybackRuntimeError,
        match='^invalid_jellyfin_playback_request$',
    ):
        JellyfinPlaybackProtocol().read_offline_chunk(
            connection,
            api_key=TOKEN,
            installation_id=INSTALLATION,
            item_id=ITEM,
            offset=0,
            length=32 * 1024 + 1,
            deadline=time.monotonic() + 1,
        )

    assert connection.sent == bytearray()
