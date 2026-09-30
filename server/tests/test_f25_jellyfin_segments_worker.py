import json
import time

from larenor_server.plugins.jellyfin_playback_runtime import (
    JellyfinPlaybackProtocol,
)
from test_jellyfin_playback_runtime import Connection, response


TOKEN = 'k' * 32
INSTALLATION = 'a' * 32
ITEM = 'b' * 32


def segment_body(items):
    return json.dumps({
        'Items': items,
        'TotalRecordCount': len(items),
        'StartIndex': 0,
    }, separators=(',', ':')).encode()


def segment(segment_id, kind, start, end):
    return {
        'Id': segment_id,
        'ItemId': ITEM,
        'Type': kind,
        'StartTicks': start * 10_000_000,
        'EndTicks': end * 10_000_000,
    }


def test_worker_reads_exact_authenticated_media_segments_route():
    connection = Connection(response('200 OK', segment_body([
        segment('c' * 32, 'Outro', 7000, 7100),
        segment('d' * 32, 'Intro', 10, 75),
        segment('e' * 32, 'Recap', 0, 9),
    ])))

    result = JellyfinPlaybackProtocol().read_segments(
        connection,
        api_key=TOKEN,
        installation_id=INSTALLATION,
        item_id=ITEM,
        deadline=time.monotonic() + 1,
    )

    assert result.model_dump() == {
        'schemaVersion': 1,
        'supported': True,
        'reason': 'available',
        'segments': [
            {'schemaVersion': 1, 'kind': 'intro',
             'startSeconds': 10, 'endSeconds': 75},
            {'schemaVersion': 1, 'kind': 'outro',
             'startSeconds': 7000, 'endSeconds': 7100},
        ],
    }
    wire = bytes(connection.sent)
    assert wire.startswith(
        f'GET /MediaSegments/{ITEM} HTTP/1.1\r\n'.encode())
    assert b'Authorization: MediaBrowser Client="Larenor%20Core"' in wire
    assert TOKEN.encode() in wire
    assert connection.closed is True
    assert TOKEN not in repr(result)


def test_worker_reports_unsupported_endpoint_without_retry():
    connection = Connection(response('404 Not Found', b'{}'))

    result = JellyfinPlaybackProtocol().read_segments(
        connection,
        api_key=TOKEN,
        installation_id=INSTALLATION,
        item_id=ITEM,
        deadline=time.monotonic() + 1,
    )

    assert result.model_dump() == {
        'schemaVersion': 1,
        'supported': False,
        'reason': 'endpoint_unsupported',
        'segments': [],
    }
    assert bytes(connection.sent).count(b'GET ') == 1


def test_worker_rejects_over_limit_or_overlapping_provider_contract():
    values = [
        segment(f'{index + 1:032x}', 'Intro', index, index + 2)
        for index in range(9)
    ]
    connection = Connection(response('200 OK', segment_body(values)))

    result = JellyfinPlaybackProtocol().read_segments(
        connection,
        api_key=TOKEN,
        installation_id=INSTALLATION,
        item_id=ITEM,
        deadline=time.monotonic() + 1,
    )

    assert result.model_dump() == {
        'schemaVersion': 1,
        'supported': False,
        'reason': 'contract_unsupported',
        'segments': [],
    }
    assert bytes(connection.sent).count(b'GET ') == 1
