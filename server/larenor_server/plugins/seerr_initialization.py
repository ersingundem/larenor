"""Finish Seerr setup over one already proved private connection.

The caller owns target selection and endpoint proof. This adapter performs one
official initialize mutation at most, requires authenticated readback, never
retries an uncertain effect, and does not expose the API key in its result.
"""

from dataclasses import dataclass
import json
import math
import re
import socket
import time

from ..services.transport import (
    ProbeTransportError,
    _Deadline,
    _remaining,
    _request_bytes,
)
from .jellyfin_startup import _ConnectionLost, _StartupReader, _response
from .seerr_initial_admin import _is_generated_key


_CODES = frozenset(
    {
        "invalid_seerr_initialization",
        "seerr_initialization_state_conflict",
        "seerr_initialization_protocol",
        "seerr_initialization_unavailable",
        "seerr_initialization_timeout",
    }
)
_PUBLIC_FIELDS = frozenset(
    {
        "initialized",
        "applicationTitle",
        "applicationUrl",
        "hideAvailable",
        "hideBlocklisted",
        "localLogin",
        "mediaServerLogin",
        "movie4kEnabled",
        "series4kEnabled",
        "discoverRegion",
        "streamingRegion",
        "originalLanguage",
        "mediaServerType",
        "jellyfinExternalHost",
        "jellyfinForgotPasswordUrl",
        "jellyfinServerName",
        "partialRequestsEnabled",
        "enableSpecialEpisodes",
        "cacheImages",
        "vapidPublic",
        "enablePushRegistration",
        "locale",
        "emailEnabled",
        "userEmailRequired",
        "newPlexLogin",
        "youtubeUrl",
        "versionCheck",
        "plexClientIdentifier",
    }
)
_CLIENT_ID = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z"
)
_STEPS = (
    "uninitialized_verified",
    "initialize_sent",
    "initialized_verified",
)


class SeerrInitializationError(Exception):
    def __init__(
        self,
        code="seerr_initialization_unavailable",
        *,
        completed_steps=(),
        uncertain_effect=False,
    ):
        self.code = code if code in _CODES else "seerr_initialization_unavailable"
        try:
            steps = tuple(completed_steps)
        except (TypeError, RecursionError):
            steps = ()
        self.completed_steps = steps if steps == _STEPS[: len(steps)] else ()
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (
            f"SeerrInitializationError({self.code!r}, "
            f"completed_steps={len(self.completed_steps)}, "
            f"uncertain_effect={self.uncertain_effect!r})"
        )


@dataclass(frozen=True)
class SeerrInitializationResult:
    state: str
    changed: bool
    completed_steps: tuple[str, ...]

    def __post_init__(self):
        expected = _STEPS if self.changed is True else (_STEPS[-1],)
        if (
            self.state != "verified"
            or type(self.changed) is not bool
            or self.completed_steps != expected
        ):
            raise SeerrInitializationError("invalid_seerr_initialization")


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _json(raw):
    try:
        return json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
    except (UnicodeError, json.JSONDecodeError, ValueError, TypeError):
        raise SeerrInitializationError("seerr_initialization_protocol") from None


def _public(value):
    if (
        type(value) is not dict
        or not {"initialized", "plexClientIdentifier"} <= set(value)
        or not set(value) <= _PUBLIC_FIELDS
        or type(value["initialized"]) is not bool
        or type(value["plexClientIdentifier"]) is not str
        or _CLIENT_ID.fullmatch(value["plexClientIdentifier"]) is None
        or "applicationTitle" in value
        and value["applicationTitle"] != "Seerr"
    ):
        raise SeerrInitializationError("seerr_initialization_state_conflict")
    return value["initialized"], value["plexClientIdentifier"]


class SeerrInitialization:
    @staticmethod
    def _exchange(connection, deadline, api_key, method, path):
        connection.settimeout(_remaining(deadline))
        connection.sendall(
            _request_bytes(
                method,
                path,
                "seerr",
                {"Accept": "application/json", "X-Api-Key": api_key},
                None,
            )
        )
        status, body, closed = _response(
            _StartupReader(connection, deadline),
            524288,
            content_type="application/json",
            error_content_type="application/json",
        )
        return status, _json(body), closed

    def complete(
        self,
        connection,
        *,
        seerr_api_key,
        total_seconds=30.0,
        close_connection=True,
    ):
        if (
            not _is_generated_key(seerr_api_key)
            or type(total_seconds) not in (int, float)
            or not math.isfinite(total_seconds)
            or not 0 < total_seconds <= 120
            or type(close_connection) is not bool
            or any(
                not callable(getattr(connection, name, None))
                for name in ("sendall", "recv", "settimeout", "shutdown", "close")
            )
        ):
            raise SeerrInitializationError("invalid_seerr_initialization")
        deadline = time.monotonic() + total_seconds
        scope = None
        steps = []
        mutation_sent = False
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            status, public, closed = self._exchange(
                connection,
                deadline,
                seerr_api_key,
                "GET",
                "/api/v1/settings/public",
            )
            if status in {401, 403}:
                raise SeerrInitializationError("seerr_initialization_unavailable")
            if status != 200:
                raise SeerrInitializationError("seerr_initialization_protocol")
            initialized, client_id = _public(public)
            if initialized:
                return SeerrInitializationResult(
                    "verified", False, ("initialized_verified",)
                )
            if closed:
                raise SeerrInitializationError("seerr_initialization_protocol")
            steps.append("uninitialized_verified")

            mutation_sent = True
            status, changed, closed = self._exchange(
                connection,
                deadline,
                seerr_api_key,
                "POST",
                "/api/v1/settings/initialize",
            )
            if status != 200:
                raise SeerrInitializationError("seerr_initialization_protocol")
            changed_initialized, changed_client_id = _public(changed)
            if not changed_initialized or changed_client_id != client_id:
                raise SeerrInitializationError(
                    "seerr_initialization_state_conflict"
                )
            steps.append("initialize_sent")
            if closed:
                raise SeerrInitializationError("seerr_initialization_protocol")

            status, observed, _closed = self._exchange(
                connection,
                deadline,
                seerr_api_key,
                "GET",
                "/api/v1/settings/public",
            )
            if status != 200:
                raise SeerrInitializationError("seerr_initialization_protocol")
            observed_initialized, observed_client_id = _public(observed)
            if not observed_initialized or observed_client_id != client_id:
                raise SeerrInitializationError(
                    "seerr_initialization_state_conflict"
                )
            steps.append("initialized_verified")
            return SeerrInitializationResult("verified", True, tuple(steps))
        except SeerrInitializationError as error:
            if error.completed_steps or error.uncertain_effect:
                raise
            raise SeerrInitializationError(
                error.code,
                completed_steps=steps,
                uncertain_effect=mutation_sent,
            ) from None
        except (socket.timeout, TimeoutError):
            raise SeerrInitializationError(
                "seerr_initialization_timeout",
                completed_steps=steps,
                uncertain_effect=mutation_sent,
            ) from None
        except _ConnectionLost:
            raise SeerrInitializationError(
                "seerr_initialization_unavailable",
                completed_steps=steps,
                uncertain_effect=mutation_sent,
            ) from None
        except (ProbeTransportError, ValueError, TypeError, AttributeError, OSError):
            code = (
                "seerr_initialization_timeout"
                if time.monotonic() >= deadline
                else "seerr_initialization_unavailable"
            )
            raise SeerrInitializationError(
                code,
                completed_steps=steps,
                uncertain_effect=mutation_sent,
            ) from None
        finally:
            if scope is not None:
                if not close_connection:
                    scope.timer.cancel()
                    with scope.lock:
                        scope.socket = None
                scope.finish()
