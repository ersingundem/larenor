"""Owned AF_UNIX fixture lifecycle; no Docker daemon or production changes."""
import socket

import pytest

from test_engine_http import response
from test_volume_effects import engine_server


def read_response(connection):
    """Consume the exact bounded version reply before waiting for fixture EOF."""
    header = bytearray()
    while not header.endswith(b'\r\n\r\n'):
        part = connection.recv(1)
        assert part, 'incomplete synthetic response header'
        header.extend(part)
        assert len(header) <= 16384
    length = next(int(line.split(b':', 1)[1]) for line in header.split(b'\r\n')
                  if line.lower().startswith(b'content-length:'))
    assert 0 <= length <= 4096
    content = bytearray()
    while len(content) < length:
        part = connection.recv(length - len(content))
        assert part, 'incomplete synthetic response body'
        content.extend(part)
    return bytes(content)


@pytest.mark.parametrize('optional_bytes', [
    b'',
    b'POST /v1.47/volumes/create HTTP/1.1\r\n',
    b'POST /v1.47/volumes/create HTTP/1.1\r\nContent-Length: 2\r\n\r\n{',
])
def test_optional_second_request_idle_timeout_is_no_dispatch_and_clean_exit(optional_bytes):
    replies = []
    with engine_server(lambda request, calls: replies.append(request) or response()) as (endpoint, calls):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(endpoint.path)
            client.sendall(b'GET /version HTTP/1.1\r\n\r\n')
            assert read_response(client)
            if optional_bytes:
                client.sendall(optional_bytes)
            # The existing two-second fixture timeout must close this owned
            # stream. A half request is never recorded or passed to reply().
            assert client.recv(1) == b''
            assert calls == [('GET /version HTTP/1.1', b'')]
            assert replies == []


def test_optional_timeout_keeps_listener_for_an_independent_complete_request():
    from pathlib import Path

    replies = []
    with engine_server(lambda request, calls: replies.append(request) or response()) as (endpoint, calls):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as first:
            first.settimeout(3)
            first.connect(endpoint.path)
            first.sendall(b'GET /version HTTP/1.1\r\n\r\n')
            read_response(first)
            assert first.recv(1) == b''
        assert calls == [('GET /version HTTP/1.1', b'')]
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as second:
            second.settimeout(3)
            second.connect(endpoint.path)
            second.sendall(b'GET /version HTTP/1.1\r\n\r\n')
            read_response(second)
            second.sendall(b'POST /v1.47/volumes/create HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}')
            read_response(second)
        assert calls == [('GET /version HTTP/1.1', b''), ('GET /version HTTP/1.1', b''),
                         ('POST /v1.47/volumes/create HTTP/1.1', b'{}')]
        assert replies == [calls[-1]]
    assert not Path(endpoint.path).exists()


@pytest.mark.parametrize('bad', [
    'first_method', 'first_body', 'first_timeout', 'version_hook_timeout',
    'oversize_header', 'oversize_body', 'malformed_length',
    'reply_timeout', 'reply_exception',
])
def test_only_optional_read_timeout_is_lifecycle_other_failures_stay_visible(monkeypatch, bad):
    import threading

    threads = []
    original = threading.Thread

    def owned_thread(*args, **kwargs):
        thread = original(*args, **kwargs)
        threads.append(thread)
        return thread

    monkeypatch.setattr(threading, 'Thread', owned_thread)
    replies = []

    def hook():
        if bad == 'version_hook_timeout':
            raise socket.timeout('synthetic version-hook failure')

    def reply(request, calls):
        replies.append(request)
        if bad == 'reply_timeout':
            raise socket.timeout('synthetic callback failure')
        raise ValueError('synthetic callback failure')

    with pytest.raises(AssertionError) as caught:
        with engine_server(reply, version_hook=hook) as (endpoint, calls):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(3)
                client.connect(endpoint.path)
                if bad == 'first_method':
                    client.sendall(b'POST /version HTTP/1.1\r\n\r\n')
                elif bad == 'first_body':
                    client.sendall(b'GET /version HTTP/1.1\r\nContent-Length: 1\r\n\r\nx')
                elif bad != 'first_timeout':
                    client.sendall(b'GET /version HTTP/1.1\r\n\r\n')
                    if bad != 'version_hook_timeout':
                        read_response(client)
                        request = {
                            'oversize_header': b'POST /v1.47/volumes/create HTTP/1.1\r\nX: ' + b'x' * 16384,
                            'oversize_body': b'POST /v1.47/volumes/create HTTP/1.1\r\nContent-Length: 4097\r\n\r\n',
                            'malformed_length': b'POST /v1.47/volumes/create HTTP/1.1\r\nContent-Length: wrong\r\n\r\n',
                        }.get(bad, b'POST /v1.47/volumes/create HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}')
                        client.sendall(request)
                try:
                    assert client.recv(1) == b''
                except ConnectionResetError:
                    # A close with unread malformed bytes may reset the peer.
                    pass
            # Join before owner stop: otherwise the fixture intentionally ignores
            # shutdown-time errors and this negative oracle would be a race.
            assert len(threads) == 1
            threads[0].join(8)
            assert not threads[0].is_alive()
    expected = ('TimeoutError' if bad.endswith('timeout') else
                'ValueError' if bad in {'malformed_length', 'reply_exception'} else
                'AssertionError')
    assert expected in str(caught.value)
    assert len(threads) == 1 and not threads[0].is_alive()
    assert len(replies) == (1 if bad.startswith('reply_') else 0)
    if bad in {'oversize_header', 'oversize_body', 'malformed_length'}:
        assert calls == [('GET /version HTTP/1.1', b'')]
