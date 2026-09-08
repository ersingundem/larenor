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
