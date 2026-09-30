"""Owned read-only HTTP fixtures for the F21 media authority acceptance.

The paths and response shapes are the exact subset consumed by
``MediaArchiveReadCollector``.  Each service listens on the packaged loopback
port, accepts only its production authentication header, and rejects mutation.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading

from test_media_archive_read_collector import routes


_PORTS = {
    8096: "jellyfin",
    8989: "sonarr",
    7878: "radarr",
    8080: "qbittorrent",
}


class _Server(ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self, address, handler, owner):
        self.owner = owner
        super().__init__(address, handler)


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        owner = self.server.owner
        service = _PORTS[self.server.server_port]
        owner.calls.append((service, "GET", self.path))
        if not owner.authenticated(service, self.headers):
            return self._reply(401, {})
        for route_service, prefix, value in owner.values:
            if route_service == service and self.path.startswith(prefix):
                if service == "jellyfin" and prefix == "/System/Info":
                    value = {**value, "Id": owner.server_id}
                return self._reply(200, value)
        return self._reply(404, {})

    def do_POST(self):
        self.server.owner.calls.append((
            _PORTS[self.server.server_port], "POST", self.path
        ))
        self._reply(405, {})

    def do_DELETE(self):
        self.server.owner.calls.append((
            _PORTS[self.server.server_port], "DELETE", self.path
        ))
        self._reply(405, {})

    def _reply(self, status, value):
        if isinstance(value, str):
            body = value.encode("ascii")
            content_type = "text/plain"
        else:
            body = json.dumps(value, separators=(",", ":")).encode("utf-8")
            content_type = "application/json"
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class MediaStackFixture:
    """Four bounded loopback services with no writable route."""

    def __init__(self):
        self.values = routes()
        self.calls = []
        self.server_id = None
        self._servers = []
        self._threads = []

    @staticmethod
    def authenticated(service, headers):
        if service == "jellyfin":
            value = headers.get("Authorization", "")
            return value.startswith("MediaBrowser ") and 'Token="' in value
        if service in {"sonarr", "radarr"}:
            return bool(headers.get("X-Api-Key"))
        return headers.get("Authorization", "").startswith("Bearer ")

    def start(self):
        for port in _PORTS:
            server = _Server(("127.0.0.1", port), _Handler, self)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self._servers.append(server)
            self._threads.append(thread)

    def bind_server_id(self, value):
        assert isinstance(value, str) and len(value) == 32
        if self.server_id is not None:
            assert self.server_id == value
        self.server_id = value

    def close(self):
        for server in self._servers:
            server.shutdown()
        for server in self._servers:
            server.server_close()
        for thread in self._threads:
            thread.join(timeout=2)
        self._servers.clear()
        self._threads.clear()

    def assert_one_read_only_collection(self):
        assert self.calls
        assert all(method == "GET" for _service, method, _path in self.calls)
        assert sum(
            service == "jellyfin" and path == "/System/Info"
            for service, _method, path in self.calls
        ) == 1
        assert sum(
            service == "jellyfin" and path.startswith("/Items?")
            for service, _method, path in self.calls
        ) == 1
