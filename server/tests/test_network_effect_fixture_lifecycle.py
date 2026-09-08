"""Owned synthetic peer lifecycle; no real Engine or arbitrary timing sleeps."""
import socket
import threading

import pytest

import test_network_effects as fixture


@pytest.fixture
def watched_peer(monkeypatch):
    original_socket = socket.socket
    accepted = threading.Event()
    reading = threading.Event()
    listener_closed = threading.Event()
    release_accept = threading.Event()
    state = {'timeouts': [], 'shutdowns': [], 'peer_closed': False, 'pause_accept': False}
    class Peer:
        def __init__(self, inner):
            self.inner = inner
        def __getattr__(self, name):
            return getattr(self.inner, name)
        def __enter__(self):
            return self
        def __exit__(self, *_):
            self.inner.close()
            state['peer_closed'] = True
        def recv(self, count):
            reading.set()
            try:
                return self.inner.recv(count)
            except socket.timeout as error:
                state['timeouts'].append(error)
                raise
        def shutdown(self, how):
            state['shutdowns'].append(how)
            return self.inner.shutdown(how)
    class Listener:
        def __init__(self, inner):
            self.inner = inner
        def __getattr__(self, name):
            return getattr(self.inner, name)
        def accept(self):
            peer, address = self.inner.accept()
            accepted.set()
            if state['pause_accept']:
                assert release_accept.wait(3), 'test must release accepted peer after stop'
            return Peer(peer), address
        def close(self):
            self.inner.close()
            listener_closed.set()
    monkeypatch.setattr(fixture.socket, 'socket', lambda *args, **kwargs:
        Listener(original_socket(*args, **kwargs)))
    return original_socket, state, accepted, reading, listener_closed, release_accept


@pytest.mark.parametrize('phase', ['partial_header', 'partial_body', 'next_request'])
def test_owner_stop_closes_waiting_peer_without_socket_timer(watched_peer, phase):
    factory, state, accepted, reading, _, _ = watched_peer
    client = factory(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(3)
    try:
        with fixture.create_server() as (endpoint, calls):
            client.connect(endpoint.path)
            assert accepted.wait(3)
            if phase == 'partial_header':
                client.sendall(b'GET /ver')
            elif phase == 'partial_body':
                client.sendall(b'GET /version HTTP/1.1\r\nContent-Length: 8\r\n\r\n{}')
            else:
                client.sendall(b'GET /version HTTP/1.1\r\nHost: docker\r\n\r\n')
                expected = fixture.response(fixture.VERSION)
                actual = bytearray()
                while len(actual) < len(expected):
                    actual.extend(client.recv(len(expected)-len(actual)))
                assert bytes(actual) == expected
            assert reading.wait(3)
        # Keep the client open through owner teardown; no timeout or client-close
        # is allowed to substitute for the owner's explicit cancellation.
        assert state['timeouts'] == []
        assert state['shutdowns'] == [socket.SHUT_RDWR]
        assert state['peer_closed'] and client.recv(1) == b''
        assert len(calls) <= 1
    finally:
        client.close()


def test_accept_returning_after_owner_stop_cannot_enter_request_reader(watched_peer):
    factory, state, accepted, reading, listener_closed, release_accept = watched_peer
    state['pause_accept'] = True
    client = factory(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(3)
    context = fixture.create_server()
    endpoint, calls = context.__enter__()
    failures = []
    def close():
        try:
            context.__exit__(None,None,None)
        except BaseException as error:
            failures.append(error)
    closer = threading.Thread(target=close)
    try:
        client.connect(endpoint.path)
        assert accepted.wait(3)
        closer.start()
        assert listener_closed.wait(3)
        release_accept.set()
        closer.join(3)
        assert not closer.is_alive() and failures == []
        assert not reading.is_set(), 'retired accepted peer must close before read'
        assert state['peer_closed'] and client.recv(1) == b''
        assert calls == [] and state['timeouts'] == []
    finally:
        release_accept.set()
        client.close()
        if closer.ident is not None:
            closer.join(3)
        else:
            context.__exit__(None,None,None)
