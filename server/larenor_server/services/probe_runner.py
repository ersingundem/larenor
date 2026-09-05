"""Bounded admin checks; observations never authorize device operations."""

from threading import Lock

from ..errors import ApiError
from .service import ServiceManagement


def _probe_connection(connection):
    # Keep service storage usable independently from the packaged adapters.
    from .probe import probe_connection
    return probe_connection(connection)


class ServiceProbeRunner:
    def __init__(self, services: ServiceManagement, *, probe=None):
        self.services = services
        self._probe = probe or _probe_connection
        self._lock = Lock()
        self._active: set[str] = set()

    def check(self, actor, service_id: str, expected_revision: int) -> dict:
        connection = self.services.connection(actor, service_id, expected_revision)
        with self._lock:
            if service_id in self._active or len(self._active) >= 4:
                raise ApiError("rate_limited", 429)
            self._active.add(service_id)
        try:
            try:
                result = self._probe(connection)
            except Exception:
                # Never propagate a provider's body, URL, or credentials into
                # the HTTP boundary or an unhandled-exception traceback.
                raise ApiError("server_unavailable", 503) from None
            # Recheck both current admin authority and configuration revision
            # after network I/O, without holding a database transaction open.
            return self.services.record_verification(
                actor, service_id, expected_revision, state=result.state, version=result.version)
        finally:
            with self._lock:
                self._active.discard(service_id)
