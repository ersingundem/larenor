"""Actual bounded loopback exchanges; no real media/home service mutation."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import threading
import time

import pytest

from larenor_server.media_archive_actions import http_transport
from larenor_server.media_archive_actions.http_transport import UnmanicLoopbackHttpTransport
from larenor_server.media_archive_actions.unmanic import UnmanicAdapter, UnmanicHttpError, UnmanicRequest
from larenor_server.services.transport import ProbeTransportError


@contextmanager
def endpoint(status=200, *, hang=False, empty=False, duplicate_type=False, oversized=False):
    calls = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            self.respond()

        def do_DELETE(self):
            self.respond()

        def respond(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            calls.append((self.command, self.path, dict(self.headers), raw))
            if hang:
                time.sleep(0.15)
                return
            if empty:
                return
            body = json.dumps({"success": True}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            if duplicate_type:
                self.send_header("Content-Type", "text/html")
            if status == 302:
                self.send_header("Location", "http://untrusted.invalid/admin")
            self.send_header("Content-Length", str(512 * 1024 + 1 if oversized else len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield UnmanicLoopbackHttpTransport(server.server_port), calls
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)


def test_delete_json_body_and_fixed_destination_use_actual_http():
    with endpoint() as (exchange, calls):
        UnmanicAdapter(exchange).delete_pending([31])
        UnmanicAdapter(exchange).terminate_worker("Default-0")
    assert [(method, path) for method, path, _headers, _body in calls] == [
        ("DELETE", "/unmanic/api/v2/pending/tasks"),
        ("DELETE", "/unmanic/api/v2/workers/worker/terminate"),
    ]
    assert json.loads(calls[0][3]) == {"id_list": [31], "selection_mode": "explicit"}
    assert json.loads(calls[1][3]) == {"worker_id": "Default-0"}
    assert all(value[2]["Host"].startswith("127.0.0.1:") for value in calls)


@pytest.mark.parametrize("options", [
    {"status": 302}, {"duplicate_type": True}, {"oversized": True},
])
def test_redirect_ambiguous_headers_and_oversized_response_are_rejected(options):
    with endpoint(**options) as (exchange, calls):
        with pytest.raises(UnmanicHttpError) as raised:
            UnmanicAdapter(exchange).delete_pending([31])
        assert raised.value.code == "unmanic_protocol_changed"
        assert len(calls) == 1


def test_timeout_never_repeats_a_write():
    with endpoint(hang=True) as (exchange, calls):
        with pytest.raises(UnmanicHttpError) as raised:
            UnmanicAdapter(exchange, timeout=0.04).delete_pending([31])
        assert raised.value.code == "unmanic_deadline_exceeded"
        assert len(calls) == 1


def test_eof_before_deadline_remains_protocol_changed():
    with endpoint(empty=True) as (exchange, calls):
        with pytest.raises(UnmanicHttpError) as raised:
            UnmanicAdapter(exchange, timeout=0.5).delete_pending([31])
        assert raised.value.code == "unmanic_protocol_changed"
        assert len(calls) == 1


def test_eof_classification_uses_the_deadline_at_the_error_boundary(monkeypatch):
    original = http_transport._response

    def delayed_error(*args, **kwargs):
        try:
            return original(*args, **kwargs)
        except ProbeTransportError:
            time.sleep(0.06)
            raise

    monkeypatch.setattr(http_transport, "_response", delayed_error)
    with endpoint(empty=True) as (exchange, calls):
        with pytest.raises(UnmanicHttpError) as raised:
            UnmanicAdapter(exchange, timeout=0.04).delete_pending([31])
        assert raised.value.code == "unmanic_deadline_exceeded"
        assert len(calls) == 1


@pytest.mark.parametrize("wire_request", [
    UnmanicRequest("POST", "/arbitrary", (("Accept", "application/json"),), b"{}"),
    UnmanicRequest("GET", "/unmanic/api/v2/workers/status", (("Accept", "application/json"),), b"{}"),
    UnmanicRequest("GET", "/unmanic/api/v2/workers/status", (("Authorization", "Bearer caller"),), b""),
])
def test_unsupported_route_body_or_headers_never_reach_socket(wire_request):
    with endpoint() as (exchange, calls):
        with pytest.raises(UnmanicHttpError) as raised:
            exchange(wire_request, time.monotonic()+1)
        assert raised.value.code == "invalid_unmanic_request"
        assert calls == []
