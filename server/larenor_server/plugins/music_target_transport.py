"""Bounded HTTP API transport to one pinned Music Assistant peer."""

import http.client
import ipaddress
import json
import socket
from urllib.parse import urlsplit


MAX_MUSIC_ASSISTANT_FRAME = 262144


class MusicTargetTransportError(Exception):
    """Static transport error without upstream or credential detail."""


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise MusicTargetTransportError('music_target_frame_invalid')
        result[key] = value
    return result


def decode_music_assistant_frame(raw):
    try:
        if type(raw) is not bytes or not 1 <= len(raw) <= MAX_MUSIC_ASSISTANT_FRAME:
            raise ValueError()
        value = json.loads(
            raw.decode('utf-8'), object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
        return value
    except MusicTargetTransportError:
        raise
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise MusicTargetTransportError('music_target_frame_invalid') from None


class MusicAssistantHTTPConnection:
    """No-DNS, no-proxy, no-redirect HTTP channel with peer revalidation."""

    def __init__(self, endpoint, pinned_peer, timeout, *, http_factory=None):
        try:
            parsed = urlsplit(endpoint)
            address = ipaddress.ip_address(parsed.hostname or '')
            if (parsed.scheme != 'http' or parsed.port is None
                    or parsed.path not in {'', '/'} or parsed.query or parsed.fragment
                    or parsed.username is not None or parsed.password is not None
                    or str(address) != pinned_peer
                    or not (address.is_private or address.is_loopback)
                    or type(timeout) not in (int, float) or not 0 < timeout <= 5):
                raise ValueError()
        except Exception:
            raise MusicTargetTransportError('music_target_transport_unavailable') from None
        self.host, self.port = str(address), parsed.port
        factory = http.client.HTTPConnection if http_factory is None else http_factory
        self._connection = factory(self.host, self.port, timeout=timeout)
        self._connected = False

    def _verify_peer(self):
        try:
            peer = self._connection.sock.getpeername()
            expected_family = socket.AF_INET6 if ':' in self.host else socket.AF_INET
            if (self._connection.sock.family != expected_family
                    or type(peer) is not tuple or len(peer) < 2
                    or peer[0] != self.host or peer[1] != self.port):
                raise ValueError()
        except Exception:
            raise MusicTargetTransportError('music_target_transport_unavailable') from None

    def request(self, method, path, *, body, headers):
        try:
            if (method != 'POST' or path != '/api' or type(body) is not bytes
                    or not 1 <= len(body) <= MAX_MUSIC_ASSISTANT_FRAME
                    or type(headers) is not dict):
                raise ValueError()
            if not self._connected:
                self._connection.connect()
                self._connected = True
            self._verify_peer()
            self._connection.request(method, path, body=body, headers=headers)
        except MusicTargetTransportError:
            raise
        except Exception:
            raise MusicTargetTransportError('music_target_transport_unavailable') from None

    def getresponse(self):
        try:
            response = self._connection.getresponse()
            self._verify_peer()
            headers = {}
            for key, value in response.getheaders():
                name = key.lower()
                if name in headers:
                    raise ValueError()
                headers[name] = value.strip()
            if (headers.get('content-type', '').lower() not in {
                    'application/json', 'application/json; charset=utf-8'}
                    or 'location' in headers or 'upgrade' in headers
                    or 'content-encoding' in headers):
                raise ValueError()
            length = headers.get('content-length')
            if length is not None and (not length.isdecimal()
                                       or int(length) > MAX_MUSIC_ASSISTANT_FRAME):
                raise ValueError()
            return response
        except MusicTargetTransportError:
            raise
        except Exception:
            raise MusicTargetTransportError('music_target_transport_unavailable') from None

    def close(self):
        try:
            self._connection.close()
        except Exception:
            pass
