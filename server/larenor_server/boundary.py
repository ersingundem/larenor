"""Bound request work and redact all unhandled errors before ASGI logging."""

import asyncio
import json
import re

from starlette.responses import JSONResponse

from .errors import ApiError, error_body
from .vault import MAX_JSON_BYTES, validate_json_bounds


def _unique_object(pairs):
    value = {}
    for key, child in pairs:
        if key in value:
            raise ValueError("Duplicate object key")
        value[key] = child
    return value


class SafeBoundaryMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        started = False

        async def safe_send(message):
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
                message = dict(message)
                headers = list(message.get("headers", []))
                headers.extend([(b"cache-control", b"no-store"), (b"pragma", b"no-cache"),
                                (b"x-content-type-options", b"nosniff"), (b"x-frame-options", b"DENY")])
                message["headers"] = headers
            await send(message)

        try:
            method = scope["method"]
            # The one binary endpoint authenticates before consuming its own
            # bounded/deadlined stream. Do not buffer an APK as JSON. The exact
            # route remains protected by the release-only publishing credential.
            release_upload = method == "PUT" and re.fullmatch(
                r"/api/v1/client/releases/[1-9][0-9]{0,9}/uploads/"
                r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/apk",
                scope["path"],
            )
            maximum = MAX_JSON_BYTES if scope["path"] == "/api/v1/vault" else 8192
            if method == "PUT" and re.fullmatch(r"/api/v1/client/releases/[1-9][0-9]{0,9}", scope["path"]):
                maximum = 65536
            if release_upload:
                maximum = 512 * 1024 * 1024
            if method in ("GET", "HEAD", "OPTIONS"):
                maximum = 0
            headers = scope.get("headers", [])
            lengths = [value for key, value in headers if key.lower() == b"content-length"]
            if len(lengths) > 1:
                raise ApiError("invalid_request")
            if lengths:
                try:
                    declared = int(lengths[0])
                except ValueError:
                    raise ApiError("invalid_request") from None
                if declared < 0:
                    raise ApiError("invalid_request")
                if declared > maximum:
                    raise ApiError("payload_too_large", 413)
            if release_upload:
                await self.app(scope, receive, safe_send)
                return
            body = bytearray()
            async with asyncio.timeout(10):
                while True:
                    message = await receive()
                    if message["type"] == "http.disconnect":
                        return
                    chunk = message.get("body", b"")
                    if len(body) + len(chunk) > maximum:
                        raise ApiError("payload_too_large", 413)
                    body.extend(chunk)
                    if not message.get("more_body", False):
                        break
            if body:
                content_type = next((value for key, value in headers if key.lower() == b"content-type"), b"")
                if content_type.split(b";", 1)[0].strip().lower() != b"application/json":
                    raise ApiError("invalid_request")
                try:
                    decoded = json.loads(body, object_pairs_hook=_unique_object,
                                         parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
                    validate_json_bounds(decoded)
                except (ValueError, UnicodeError, RecursionError):
                    raise ApiError("invalid_request") from None
            delivered = False

            async def buffered_receive():
                nonlocal delivered
                if not delivered:
                    delivered = True
                    return {"type": "http.request", "body": bytes(body), "more_body": False}
                return await receive()

            await self.app(scope, buffered_receive, safe_send)
        except ApiError as error:
            if not started:
                await JSONResponse(error_body(error.code), status_code=error.status)(scope, receive, safe_send)
        except TimeoutError:
            if not started:
                await JSONResponse(error_body("request_timeout"), status_code=408)(scope, receive, safe_send)
        except Exception:
            # No request body, SQLite statement, token or traceback is logged.
            if not started:
                await JSONResponse(error_body("server_unavailable"), status_code=503)(scope, receive, safe_send)
