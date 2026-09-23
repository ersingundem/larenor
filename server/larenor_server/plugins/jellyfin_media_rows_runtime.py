"""Bounded account-specific Jellyfin latest and resume projections."""

from datetime import datetime, timezone
import hashlib
import json
import math
import re
import socket
import time
from urllib.parse import urlencode

from pydantic import ValidationError

from ..services.transport import ProbeTransportError, _request_bytes
from .jellyfin_startup import JellyfinStartupError, _StartupReader, _json, _response
from .media_rows_models import MediaRowItem, MediaRowsReadback


_ID = re.compile(r"[0-9a-f]{32}\Z")
_TOKEN = re.compile(r"[A-Za-z0-9_-]{32,128}\Z")
_DATE = re.compile(
    r"[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T"
    r"(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,7})?Z\Z"
)
_BASE_AUTH = (
    'MediaBrowser Client="Larenor%20Core", Device="Larenor%20Core", '
    'DeviceId="{device}", Version="0.1.0", Token={token}'
)


class JellyfinMediaRowsRuntimeError(Exception):
    """Static, secret-free runtime failure."""

    _CODES = frozenset({
        "invalid_jellyfin_media_rows_request",
        "jellyfin_media_rows_readback_changed",
        "jellyfin_media_rows_unavailable",
    })

    def __init__(self, code="jellyfin_media_rows_unavailable"):
        self.code = code if code in self._CODES else "jellyfin_media_rows_unavailable"
        super().__init__(self.code)

    def __repr__(self):
        return f"JellyfinMediaRowsRuntimeError({self.code!r})"


class JellyfinMediaRowsProtocol:
    """Read two fixed Jellyfin endpoints without exposing a general proxy."""

    def __init__(self, *, revision_seed=None):
        if revision_seed is None:
            revision_seed = int.from_bytes(
                __import__("secrets").token_bytes(6), "big"
            ) << 10
        if (
            type(revision_seed) is not int
            or not 1 <= revision_seed < 2**63 - 65_536
        ):
            raise JellyfinMediaRowsRuntimeError(
                "invalid_jellyfin_media_rows_request"
            )
        self._seed = revision_seed
        self._states = {}

    def __repr__(self):
        return "JellyfinMediaRowsProtocol(<private>)"

    @staticmethod
    def _inputs(connections, api_key, user_id, installation_id, deadline):
        methods = ("sendall", "recv", "settimeout", "close")
        if (
            type(connections) not in (tuple, list)
            or len(connections) != 2
            or any(
                not all(callable(getattr(connection, name, None)) for name in methods)
                for connection in connections
            )
            or type(api_key) is not str
            or _TOKEN.fullmatch(api_key) is None
            or type(user_id) is not str
            or _ID.fullmatch(user_id) is None
            or type(installation_id) is not str
            or _ID.fullmatch(installation_id) is None
            or type(deadline) not in (int, float)
            or type(deadline) is bool
            or not math.isfinite(deadline)
            or time.monotonic() >= deadline
        ):
            raise JellyfinMediaRowsRuntimeError(
                "invalid_jellyfin_media_rows_request"
            )

    @staticmethod
    def _close(connections):
        for connection in connections:
            try:
                connection.close()
            except Exception:
                pass

    @staticmethod
    def _request(connection, path, authorization, deadline):
        reader = _StartupReader(connection, deadline)
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError()
            connection.settimeout(remaining)
            connection.sendall(
                _request_bytes(
                    "GET",
                    path,
                    "jellyfin",
                    {"Accept": "application/json", "Authorization": authorization},
                    None,
                )
            )
            status, body, closed = _response(reader, 262_144)
            if status != 200 or closed is not True or reader.receive(1) != b"":
                raise ValueError()
            return _json(body)
        except (
            OSError,
            ValueError,
            TypeError,
            ProbeTransportError,
            JellyfinStartupError,
            socket.timeout,
        ):
            raise JellyfinMediaRowsRuntimeError() from None
        finally:
            try:
                connection.close()
            except Exception:
                pass

    @staticmethod
    def _timestamp(value):
        if type(value) is not str or _DATE.fullmatch(value) is None:
            raise ValueError()
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
        if parsed.tzinfo != timezone.utc:
            raise ValueError()
        timestamp = int(parsed.timestamp())
        if not 1 <= timestamp <= 253402300799:
            raise ValueError()
        return timestamp

    @classmethod
    def _item(cls, value, *, resume):
        if type(value) is not dict:
            raise ValueError()
        kind = {"Movie": "movie", "Episode": "episode"}.get(value.get("Type"))
        ticks = value.get("RunTimeTicks")
        user_data = value.get("UserData")
        if (
            kind is None
            or type(ticks) is not int
            or not 10_000_000 <= ticks <= 6_048_000_000_000
            or type(user_data) is not dict
        ):
            raise ValueError()
        position = user_data.get("PlaybackPositionTicks")
        if type(position) is not int or position < 0:
            raise ValueError()
        runtime_seconds = ticks // 10_000_000
        position_seconds = position // 10_000_000 if resume else 0
        return MediaRowItem(
            itemId=value.get("Id"),
            title=value.get("Name"),
            mediaKind=kind,
            addedAt=cls._timestamp(value.get("DateCreated")),
            runtimeSeconds=runtime_seconds,
            positionSeconds=position_seconds,
        )

    @classmethod
    def _recent(cls, value):
        if type(value) is not list or len(value) > 24:
            raise ValueError()
        return [cls._item(item, resume=False) for item in value]

    @classmethod
    def _resume(cls, value):
        if (
            type(value) is not dict
            or set(value) != {"Items", "TotalRecordCount", "StartIndex"}
            or type(value["Items"]) is not list
            or len(value["Items"]) > 24
            or type(value["TotalRecordCount"]) is not int
            or not len(value["Items"]) <= value["TotalRecordCount"] <= 4096
            or value["StartIndex"] != 0
        ):
            raise ValueError()
        return [cls._item(item, resume=True) for item in value["Items"]]

    @staticmethod
    def _digest(recent, resume):
        payload = {
            "recent": [item.model_dump(mode="json") for item in recent],
            "resume": [item.model_dump(mode="json") for item in resume],
        }
        return hashlib.sha256(
            json.dumps(
                payload,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
        ).hexdigest()

    def _revision(self, installation_id, user_id, recent, resume):
        key = (installation_id, user_id)
        fingerprint = self._digest(recent, resume)
        state = self._states.get(key)
        if state is None:
            state = [self._seed, fingerprint]
            self._states[key] = state
        elif state[1] != fingerprint:
            state[0] += 1
            state[1] = fingerprint
        return state[0]

    def read(
        self,
        connections,
        *,
        api_key,
        user_id,
        installation_id,
        deadline,
    ):
        self._inputs(connections, api_key, user_id, installation_id, deadline)
        authorization = _BASE_AUTH.format(device=installation_id, token=api_key)
        recent_query = urlencode(
            sorted({
                "enableImages": "false",
                "enableUserData": "true",
                "fields": "DateCreated,RunTimeTicks",
                "includeItemTypes": "Movie,Episode",
                "limit": "24",
                "userId": user_id,
            }.items())
        )
        resume_query = urlencode(
            sorted({
                "fields": "DateCreated,RunTimeTicks",
                "limit": "24",
                "mediaTypes": "Video",
            }.items())
        )
        try:
            recent_raw = self._request(
                connections[0], f"/Items/Latest?{recent_query}", authorization, deadline
            )
            resume_raw = self._request(
                connections[1],
                f"/Users/{user_id}/Items/Resume?{resume_query}",
                authorization,
                deadline,
            )
            recent = self._recent(recent_raw)
            resume = self._resume(resume_raw)
            return MediaRowsReadback(
                revision=self._revision(
                    installation_id, user_id, recent, resume
                ),
                recent=recent,
                resume=resume,
            )
        except JellyfinMediaRowsRuntimeError:
            self._close(connections)
            raise
        except (ValidationError, ValueError, TypeError, OverflowError):
            self._close(connections)
            raise JellyfinMediaRowsRuntimeError(
                "jellyfin_media_rows_readback_changed"
            ) from None
