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
        lease = None
        if connection.kind == "home_assistant":
            policy = getattr(self.services, "component_egress", None)
            if policy is None:
                raise ApiError("outbound_denied", 403)
            lease = policy.begin(actor, connection)
        with self._lock:
            if service_id in self._active or len(self._active) >= 4:
                raise ApiError("rate_limited", 429)
            self._active.add(service_id)
        try:
            try:
                if lease is not None and self._probe is _probe_connection:
                    from .probe import probe_connection
                    result = probe_connection(connection, transport_factory=lease.transport)
                else:
                    result = self._probe(connection)
                if lease is not None:
                    lease.check()
            except ApiError:
                if lease is not None:
                    lease.failed()
                raise
            except Exception:
                # Never propagate a provider's body, URL, or credentials into
                # the HTTP boundary or an unhandled-exception traceback.
                raise ApiError("server_unavailable", 503) from None
            # Recheck both current admin authority and configuration revision
            # after network I/O, without holding a database transaction open.
            return self.services.record_verification(
                actor, service_id, expected_revision, state=result.state, version=result.version,
                before_save=None if lease is None else lease.complete)
        finally:
            with self._lock:
                self._active.discard(service_id)
