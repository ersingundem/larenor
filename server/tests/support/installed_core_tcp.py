"""Bounded stdlib client for an actual installed Core/Uvicorn TCP process."""

import http.client
import json
import socket
import threading
import time

import uvicorn


MAX_RESPONSE = 1024 * 1024


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise RuntimeError("duplicate_response_key")
        result[key] = value
    return result


class InstalledCoreTcp:
    def __init__(self, app):
        self._app = app
        self._socket = None
        self._server = None
        self._thread = None
        self.port = None

    def __enter__(self):
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._socket.bind(("127.0.0.1", 0))
        self.port = self._socket.getsockname()[1]
        self._server = uvicorn.Server(uvicorn.Config(
            self._app,
            host="127.0.0.1",
            port=self.port,
            access_log=False,
            log_config=None,
            lifespan="on",
            timeout_keep_alive=1,
        ))
        self._thread = threading.Thread(
            target=self._server.run,
            kwargs={"sockets": [self._socket]},
            name="installed-core-tcp",
            daemon=True,
        )
        self._thread.start()
        deadline = time.monotonic() + 10
        while not self._server.started and self._thread.is_alive():
            if time.monotonic() >= deadline:
                break
            time.sleep(0.01)
        if not self._server.started:
            self.__exit__(None, None, None)
            raise RuntimeError("installed_core_start_failed")
        status, body = self.json("GET", "/health")
        if status != 200 or body != {"service": "larenor-server", "apiVersion": 1}:
            self.__exit__(None, None, None)
            raise RuntimeError("installed_core_health_failed")
        return self

    def json(self, method, path, *, body=None, token=None):
        if method not in {"GET", "POST"} or not path.startswith("/") or "?" in path:
            raise RuntimeError("invalid_request")
        payload = None if body is None else json.dumps(
            body, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        headers = {"Accept": "application/json"}
        if payload is not None:
            headers["Content-Type"] = "application/json"
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            connection.request(method, path, body=payload, headers=headers)
            response = connection.getresponse()
            if response.length is not None and response.length > MAX_RESPONSE:
                raise RuntimeError("response_too_large")
            raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise RuntimeError("response_too_large")
            value = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs)
            if not isinstance(value, dict):
                raise RuntimeError("invalid_response")
            return response.status, value
        finally:
            connection.close()

    def __exit__(self, _kind, _error, _traceback):
        if self._server is not None:
            self._server.should_exit = True
        if self._thread is not None:
            self._thread.join(timeout=10)
            if self._thread.is_alive():
                raise RuntimeError("installed_core_stop_failed")
        if self._socket is not None:
            self._socket.close()
