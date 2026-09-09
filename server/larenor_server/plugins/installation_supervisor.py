"""Native-thread lifetime guard for the closed installation backend.

The guard owns one authenticated Docker Unix connection plus the socket-peer
pidfd/proc evidence captured from it.  It does not expose a Docker operation,
host path or authority token.  Every effect remains the responsibility of the
closed backend and is bracketed by fresh evidence checks on the same native
thread.

This proves continuity of the selected daemon incarnation, socket inode,
mount/network/process-root context and observed user namespace mappings.  It
does not by itself prove an initial host namespace or a remap-disabled daemon
startup, so it must not enable installation availability.
"""

import math
import os
import socket
import threading
import time

from .daemon_context import DaemonContext, capture_daemon_context
from .daemon_security import attest_daemon_security
from .docker_probe import DockerEndpoint, _identity, _linux_peer_uid


class InstallationSupervisorError(Exception):
    """One static boundary error; kernel and policy details stay private."""

    def __init__(self):
        super().__init__('supervisor_unavailable')


def _valid_deadline(deadline):
    return (type(deadline) in (int, float) and math.isfinite(deadline)
            and time.monotonic() < deadline)


def _map_rows(value):
    try:
        rows = tuple(
            (item.inside_first, item.outside_first, item.length)
            if all(hasattr(item, name) for name in ('inside_first', 'outside_first', 'length'))
            else tuple(item)
            for item in value
        )
        if (not rows or any(len(item) != 3 or any(type(part) is not int for part in item)
                            for item in rows)):
            raise ValueError()
        return rows
    except (TypeError, ValueError, AttributeError):
        raise InstallationSupervisorError() from None


def _same_observed_user_context(peer, worker):
    """Require one reader/target user namespace and equal nonempty maps.

    Equal maps are continuity evidence only.  They are deliberately not
    interpreted as proof that either process is in the initial user namespace.
    """
    try:
        namespaces = (
            peer.target_user_namespace,
            peer.opener_user_namespace,
            worker.target_user_namespace,
            worker.opener_user_namespace,
        )
        return (all(value == namespaces[0] for value in namespaces[1:])
                and _map_rows(peer.uid_map) == _map_rows(worker.uid_map)
                and _map_rows(peer.gid_map) == _map_rows(worker.gid_map))
    except (TypeError, AttributeError, InstallationSupervisorError):
        return False


class RetainedDaemonPeerVerifier:
    """Authenticate every operation connection against one retained pidfd."""

    def __init__(self, endpoint):
        if type(endpoint) is not DockerEndpoint:
            raise InstallationSupervisorError()
        self._endpoint = endpoint
        self._owner = None
        self._lease = None
        self._active_deadline = None
        self._failed = False

    def __repr__(self):
        return 'RetainedDaemonPeerVerifier(<private>)'

    def bind(self, lease, deadline):
        if (self._owner is not None or self._failed or not _valid_deadline(deadline)
                or not callable(getattr(lease, 'matches_connection', None))
                or not lease.revalidate(deadline)):
            raise InstallationSupervisorError()
        self._owner = os.getpid(), threading.get_native_id()
        self._lease = lease

    def check(self, deadline):
        if (self._failed or self._lease is None or not _valid_deadline(deadline)
                or self._owner != (os.getpid(), threading.get_native_id())
                or not self._lease.revalidate(deadline)):
            raise InstallationSupervisorError()

    def activate(self, deadline):
        self.check(deadline)
        if self._active_deadline is not None:
            self._failed = True
            raise InstallationSupervisorError()
        self._active_deadline = deadline

    def deactivate(self):
        self._active_deadline = None

    def __call__(self, connection):
        try:
            deadline = self._active_deadline
            self.check(deadline)
            if not self._lease.matches_connection(
                    connection, self._endpoint.owner_uid, deadline):
                raise InstallationSupervisorError()
            self.check(deadline)
            return self._endpoint.owner_uid
        except Exception:
            self._failed = True
            raise InstallationSupervisorError() from None

    def close(self):
        self._failed = True
        self._active_deadline = None
        self._lease = None


class SupervisedInstallationBackend:
    """Keep daemon evidence on the one native thread executing effects."""

    def __init__(self, endpoint, backend, *, platform, socket_factory=None, peer_verifier=None,
                 security_attestor=None):
        if (type(endpoint) is not DockerEndpoint
                or platform not in {'linux/amd64', 'linux/arm64'}
                or not callable(getattr(backend, 'apply', None))
                or not callable(getattr(backend, 'reconcile', None))
                or socket_factory is not None and not callable(socket_factory)
                or peer_verifier is not None
                and type(peer_verifier) is not RetainedDaemonPeerVerifier
                or security_attestor is not None and not callable(security_attestor)):
            raise InstallationSupervisorError()
        self._endpoint = endpoint
        self._platform = platform
        self.backend = backend
        self._socket_factory = socket.socket if socket_factory is None else socket_factory
        self._peer_verifier = (RetainedDaemonPeerVerifier(endpoint)
                               if peer_verifier is None else peer_verifier)
        self._security_attestor = (attest_daemon_security if security_attestor is None
                                   else security_attestor)
        self._owner = None
        self._connection = None
        self._lease = None
        self._identities = None
        self._security = None
        self._endpoint_identity = None
        self._closed = False

    def __repr__(self):
        return 'SupervisedInstallationBackend(<private>)'

    def _invalidate(self):
        self._closed = True
        security, self._security = self._security, None
        identities, self._identities = self._identities, None
        lease, self._lease = self._lease, None
        connection, self._connection = self._connection, None
        for value in (self._peer_verifier, security, identities, lease, connection):
            if value is not None:
                try:
                    value.close()
                except Exception:
                    pass

    def _check(self, deadline):
        try:
            if (not _valid_deadline(deadline) or self._closed
                    or self._owner != (os.getpid(), threading.get_native_id())
                    or self._connection is None or self._lease is None
                    or self._identities is None or self._security is None
                    or _identity(self._endpoint) != self._endpoint_identity
                    or not self._lease.revalidate(deadline)):
                raise ValueError()
            self._peer_verifier.check(deadline)
            self._security.check(deadline)
            self._identities.check(deadline)
            if (_identity(self._endpoint) != self._endpoint_identity
                    or not self._lease.revalidate(deadline)
                    or not _valid_deadline(deadline)):
                raise ValueError()
        except Exception:
            self._invalidate()
            raise InstallationSupervisorError() from None

    def open(self, deadline):
        if not _valid_deadline(deadline) or self._owner is not None or self._closed:
            raise InstallationSupervisorError()
        self._owner = os.getpid(), threading.get_native_id()
        try:
            before = _identity(self._endpoint)
            connection = self._socket_factory(socket.AF_UNIX, socket.SOCK_STREAM)
            self._connection = connection
            connection.settimeout(max(0.001, deadline - time.monotonic()))
            connection.connect(self._endpoint.path)
            if (_identity(self._endpoint) != before
                    or _linux_peer_uid(connection) != self._endpoint.owner_uid):
                raise ValueError()
            lease = capture_daemon_context(
                connection,
                self._endpoint.owner_uid,
                self._endpoint.daemon_executable,
                deadline,
            )
            self._lease = lease
            if (lease is None or lease.context != DaemonContext(True, True, True)):
                raise ValueError()
            identities = lease.capture_identities(deadline)
            self._identities = identities
            if not _same_observed_user_context(identities.peer, identities.worker):
                raise ValueError()
            startup = lease.capture_startup(deadline)
            self._security = self._security_attestor(
                connection,
                startup,
                identities.peer,
                identities.worker,
                daemon_executable=self._endpoint.daemon_executable,
                platform=self._platform,
                deadline=deadline,
            )
            self._endpoint_identity = before
            self._peer_verifier.bind(lease, deadline)
            self._check(deadline)
        except BaseException as error:
            self._invalidate()
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            raise InstallationSupervisorError() from None

    def _call(self, operation, step, plan, deadline):
        self._check(deadline)
        self._peer_verifier.activate(deadline)
        try:
            try:
                result = getattr(self.backend, operation)(step, plan)
                self._check(deadline)
                return result
            except BaseException:
                # Even a backend failure must release a changed daemon context.
                # The original static backend error remains useful when the
                # retained evidence still holds.
                try:
                    self._check(deadline)
                except InstallationSupervisorError:
                    raise
                raise
        finally:
            self._peer_verifier.deactivate()

    def apply_with_deadline(self, step, plan, deadline):
        return self._call('apply', step, plan, deadline)

    def reconcile_with_deadline(self, step, plan, deadline):
        return self._call('reconcile', step, plan, deadline)

    def bootstrap_with_deadline(self, job, plan, private, deadline):
        self._check(deadline)
        self._peer_verifier.activate(deadline)

        def gate():
            self._check(deadline)
            return True

        try:
            try:
                result = self.backend.bootstrap(
                    job, plan, private, deadline=deadline, gate=gate)
                self._check(deadline)
                return result
            except BaseException:
                try:
                    self._check(deadline)
                except InstallationSupervisorError:
                    raise
                raise
        finally:
            self._peer_verifier.deactivate()

    def close(self):
        if self._closed:
            return
        if self._owner != (os.getpid(), threading.get_native_id()):
            self._invalidate()
            raise InstallationSupervisorError()
        self._invalidate()
