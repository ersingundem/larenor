"""Private loopback callback receiver with durable admission and signed ACK."""

import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import threading


class UnmanicCallbackServer:
    def __init__(self, store, port):
        if not callable(getattr(store, "ingest", None)) or type(port) is not int or not 1024 <= port <= 65535:
            raise ValueError("archive_callback_unavailable")
        self.store = store
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                try:
                    if self.path != "/larenor/unmanic/terminal":
                        raise ValueError()
                    if self.headers.get_all("Transfer-Encoding") or self.headers.get_all("Content-Encoding"):
                        raise ValueError()
                    lengths = self.headers.get_all("Content-Length", [])
                    types = self.headers.get_all("Content-Type", [])
                    if len(lengths) != 1 or types != ["application/json"]:
                        raise ValueError()
                    size = int(lengths[0])
                    if not 1 <= size <= 64*1024:
                        raise ValueError()
                    names = ("x-larenor-unmanic-timestamp", "x-larenor-unmanic-nonce", "x-larenor-unmanic-signature")
                    headers = {}
                    for name in names:
                        values = self.headers.get_all(name, [])
                        if len(values) != 1:
                            raise ValueError()
                        headers[name] = values[0]
                    raw = self.rfile.read(size)
                    if len(raw) != size:
                        raise ValueError()
                    receipt = owner.store.ingest(headers, raw)
                    nonce, digest = headers[names[1]], receipt.callbackDigest
                    signature = hmac.new(owner.store._key, ("ack-v1\n"+nonce+"\n"+digest).encode(), hashlib.sha256).hexdigest()
                    body = json.dumps({"schemaVersion": 1, "acceptedDigest": digest,
                        "nonce": nonce, "signature": signature}, separators=(",", ":")).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except OSError:
                    self.close_connection = True
                except Exception:
                    self.send_response(400)
                    self.send_header("Content-Length", "0")
                    self.end_headers()

            def log_message(self, *_args):
                pass

        class Server(HTTPServer):
            request_queue_size = 4

            def get_request(self):
                stream, address = super().get_request()
                stream.settimeout(2)
                return stream, address

            def finish_request(self, request, client_address):
                def expire():
                    try:
                        request.shutdown(2)
                    except OSError:
                        pass
                    request.close()
                timer = threading.Timer(2, expire)
                timer.daemon = True
                timer.start()
                try:
                    super().finish_request(request, client_address)
                finally:
                    timer.cancel()

            def handle_error(self, *_args):
                # Default traceback output can contain private callback paths.
                pass

        self._server = Server(("127.0.0.1", port), Handler)
        self._thread = None

    def start(self):
        if self._thread is not None:
            raise ValueError("archive_callback_unavailable")
        self._thread = threading.Thread(target=self._server.serve_forever,
            kwargs={"poll_interval": 0.1}, name="larenor-terminal-callback", daemon=True)
        self._thread.start()
        return self

    def close(self):
        if self._thread is not None:
            self._server.shutdown()
            self._thread.join(timeout=3)
            self._thread = None
        self._server.server_close()

    def __enter__(self):
        return self.start()

    def __exit__(self, *_args):
        self.close()
