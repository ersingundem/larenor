"""Bounded read lease over an already authorized Frigate camera source."""

from types import MappingProxyType
import re
import time

from ..errors import ApiError

_REVIEW_ID = re.compile(r"[A-Za-z0-9_.:-]{1,128}\Z")


class FrigateAuthorizedRead:
    """No service, URL or credential is exposed through this object."""

    def __init__(self, runtime, *, source_revision, authority, camera_mapping,
                 service, token, guard):
        self._runtime = runtime
        self._service, self._token, self._guard = service, token, guard
        self._deadline = time.monotonic() + 20
        self.source_revision = source_revision
        self.authority = authority
        self.camera_mapping = MappingProxyType(dict(camera_mapping))

    def assert_current(self):
        if time.monotonic() > self._deadline:
            raise ApiError("revision_conflict", 409)
        self._guard()

    def _query(self, path, query):
        if path in {"/api/profile", "/api/config"}:
            if query is not None:
                raise ApiError("invalid_request")
            return None
        if path == "/api/review":
            if (type(query) is not dict
                    or set(query) != {"cameras", "after", "before", "limit"}
                    or any(not isinstance(value, str) for value in query.values())):
                raise ApiError("invalid_request")
            camera = query["cameras"]
            if camera not in self.camera_mapping.values() or "," in camera:
                raise ApiError("forbidden", 403)
            try:
                after, before, limit = (
                    int(query["after"]), int(query["before"]), int(query["limit"])
                )
            except ValueError:
                raise ApiError("invalid_request") from None
            if (str(after) != query["after"] or str(before) != query["before"]
                    or str(limit) != query["limit"]
                    or not 0 <= after <= before <= 2**63 - 1
                    or not 1 <= limit <= 64
                    or before - after > 7 * 24 * 60 * 60 + 1):
                raise ApiError("invalid_request")
            return dict(query)
        prefix = "/api/review/"
        if path.startswith(prefix) and _REVIEW_ID.fullmatch(path.removeprefix(prefix)):
            if query is not None:
                raise ApiError("invalid_request")
            return None
        raise ApiError("forbidden", 403)

    def get_json(self, path, *, query=None):
        checked = self._query(path, query)
        self.assert_current()
        with self._runtime._budget():
            value = self._runtime._get(
                self._service, path, self.assert_current, self._token, query=checked
            )
        self.assert_current()
        if path == "/api/review" and (
            type(value) is not list or len(value) > int(checked["limit"])
        ):
            raise ApiError("camera_search_source_unavailable", 503)
        return value

    def get_version(self):
        self.assert_current()
        with self._runtime._budget():
            response = self._runtime._request(
                self._service, "GET", "/api/version", self.assert_current,
                token=self._token, max_bytes=256,
            )
        self.assert_current()
        content_types = [
            value.split(";", 1)[0].strip().lower()
            for name, value in response.headers if name.lower() == "content-type"
        ]
        try:
            value = response.body.decode("ascii")
        except UnicodeDecodeError:
            raise ApiError("camera_search_source_unavailable", 503) from None
        if content_types != ["text/plain"] or not 1 <= len(value) <= 128 or any(
                ord(char) < 32 or ord(char) == 127 for char in value):
            raise ApiError("camera_search_source_unavailable", 503)
        return value
