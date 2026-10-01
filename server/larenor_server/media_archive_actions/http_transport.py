"""One-attempt Unmanic HTTP exchanges on a fixed private loopback port."""

import math
import socket
import time

from ..services.transport import (
    ProbeTransportError, _Deadline, _Reader, _remaining, _response,
)
from .unmanic import UnmanicHttpError, UnmanicRequest, UnmanicResponse


_ROUTES = frozenset({
    ("POST", "/unmanic/api/v2/pending/test"),
    ("POST", "/unmanic/api/v2/pending/create"),
    ("POST", "/unmanic/api/v2/pending/status/get"),
    ("DELETE", "/unmanic/api/v2/pending/tasks"),
    ("GET", "/unmanic/api/v2/workers/status"),
    ("DELETE", "/unmanic/api/v2/workers/worker/terminate"),
    ("GET", "/unmanic/api/v2/settings/libraries"),
    ("POST", "/unmanic/api/v2/settings/library/read"),
})


class UnmanicLoopbackHttpTransport:
    """No caller URL, DNS, redirects, retries, cookies or ambient proxy/auth.

    The port must be supplied by the trusted worker's managed Unmanic binding.
    Unmanic has no native API authentication; runtime deployment must keep the
    port inside the private worker network and verify the managed service.
    """

    def __init__(self, port):
        if type(port) is not int or not 1024 <= port <= 65535:
            raise UnmanicHttpError("invalid_unmanic_request")
        self._port = port

    def __repr__(self):
        return "UnmanicLoopbackHttpTransport(<private>)"

    def __call__(self, request, deadline):
        now = time.monotonic()
        if (type(request) is not UnmanicRequest
                or type(deadline) not in {int, float} or not math.isfinite(deadline)
                or not now < deadline <= now + 30
                or (request.method, request.path) not in _ROUTES
                or type(request.body) is not bytes or len(request.body) > 32768):
            raise UnmanicHttpError("invalid_unmanic_request")
        expected_headers = (("Accept", "application/json"),)
        if request.method != "GET":
            expected_headers += (("Content-Type", "application/json"),)
        if (request.headers != expected_headers
                or request.method == "GET" and request.body
                or request.method != "GET" and not request.body):
            raise UnmanicHttpError("invalid_unmanic_request")
        wire = (
            f"{request.method} {request.path} HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{self._port}\r\n"
            "Connection: close\r\nAccept-Encoding: identity\r\n"
            + "".join(f"{name}: {value}\r\n" for name, value in expected_headers)
            + (f"Content-Length: {len(request.body)}\r\n" if request.method != "GET" else "")
            + "\r\n"
        ).encode("ascii") + request.body
        stream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        scope = _Deadline(deadline)
        try:
            scope.attach(stream)
            stream.settimeout(_remaining(deadline))
            stream.connect(("127.0.0.1", self._port))
            if stream.getpeername() != ("127.0.0.1", self._port):
                raise UnmanicHttpError("unmanic_transport_unavailable")
            stream.settimeout(_remaining(deadline))
            stream.sendall(wire)
            value = _response(_Reader(stream, deadline), 512 * 1024)
            _remaining(deadline)
            content_types = [item for name, item in value.headers if name == "content-type"]
            if len(content_types) != 1 or 300 <= value.status < 400:
                raise UnmanicHttpError("unmanic_protocol_changed")
            return UnmanicResponse(value.status, content_types[0], value.body)
        except UnmanicHttpError:
            raise
        except (socket.timeout, TimeoutError):
            raise UnmanicHttpError("unmanic_deadline_exceeded") from None
        except ProbeTransportError as error:
            code = ("unmanic_deadline_exceeded"
                    if error.code == "request_timeout" or time.monotonic() >= deadline
                    else "unmanic_protocol_changed")
            raise UnmanicHttpError(code) from None
        except (OSError, ValueError, TypeError):
            raise UnmanicHttpError("unmanic_transport_unavailable") from None
        finally:
            scope.finish()
