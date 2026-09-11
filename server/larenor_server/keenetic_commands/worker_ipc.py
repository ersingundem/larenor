"""UID-private, single-dispatch Unix IPC for Keenetic command effects."""

import math
from pathlib import Path
import socket
import stat
import time
import uuid

from pydantic import ValidationError

from ..plugins.preflight_ipc import (
    PreflightIPCError,
    PreflightWorkerServer,
    _peer_uid,
    read_packet,
    write_packet,
)
from ..plugins.worker import DockerWorkerError, _safe_path
from .service import KeeneticEffectError
from .worker_models import KeeneticWorkerCommand, KeeneticWorkerResult


MAX_SEALED_REQUESTS = 1024


class UnavailableKeeneticCommandHandler:
    """Safe worker default with no DNS, socket, router or transport behavior."""

    def execute(self, _command, *, deadline, cancelled):
        raise KeeneticEffectError("keenetic_effect_unavailable")


class KeeneticCommandWorkerClient:
    def __init__(self, path, *, owner_uid=0, peer_uid=None, timeout=5):
        if (
            type(owner_uid) is not int
            or owner_uid < 0
            or type(timeout) not in (int, float)
            or not math.isfinite(timeout)
            or not 0 < timeout <= 10
        ):
            raise KeeneticEffectError("keenetic_effect_unavailable")
        self.path = Path(path).absolute()
        self.owner_uid = owner_uid
        self.peer_uid = peer_uid or _peer_uid
        self.timeout = timeout

    def __call__(self, request, guard):
        timeout_ms = max(50, min(10000, int(self.timeout * 1000)))
        return self.execute(
            KeeneticWorkerCommand.from_request(request, timeout_ms=timeout_ms),
            guard=guard,
        )

    def execute(self, command, *, guard, cancelled=lambda: False):
        try:
            command = KeeneticWorkerCommand.model_validate(command)
        except ValidationError:
            raise KeeneticEffectError("keenetic_effect_rejected") from None
        if not callable(guard) or not callable(cancelled):
            raise KeeneticEffectError("keenetic_effect_rejected")
        if cancelled():
            raise KeeneticEffectError("keenetic_effect_cancelled")
        guard()
        sent = False
        try:
            _safe_path(self.path, uid=self.owner_uid, kind=stat.S_ISSOCK)
            timeout = min(self.timeout, command.timeoutMs / 1000)
            deadline = time.monotonic() + timeout
            packet_id = uuid.uuid4().hex
            request = {
                "protocol": 1,
                "requestId": packet_id,
                "operation": "keenetic_command_execute",
                "command": command.model_dump(mode="json"),
            }
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(timeout)
                connection.connect(str(self.path))
                if self.peer_uid(connection) != self.owner_uid:
                    raise KeeneticEffectError("keenetic_effect_unavailable")
                if cancelled():
                    raise KeeneticEffectError("keenetic_effect_cancelled")
                sent = True
                write_packet(connection, request, deadline)
                response = read_packet(connection, deadline)
            if (
                set(response) != {"protocol", "requestId", "result"}
                or response["requestId"] != packet_id
            ):
                raise KeeneticEffectError(
                    "keenetic_result_unknown", uncertain=True
                )
            result = KeeneticWorkerResult.for_command(command, response["result"])
        except KeeneticEffectError as error:
            if sent and not error.uncertain:
                raise KeeneticEffectError(
                    "keenetic_effect_unknown", uncertain=True
                ) from None
            raise
        except (OSError, ValueError, TypeError, DockerWorkerError, PreflightIPCError):
            raise KeeneticEffectError(
                "keenetic_effect_unknown" if sent else "keenetic_effect_unavailable",
                uncertain=sent,
            ) from None
        if cancelled():
            raise KeeneticEffectError("keenetic_effect_unknown", uncertain=True)
        if result.status != "succeeded":
            raise KeeneticEffectError(
                result.code, uncertain=result.status == "unknown"
            )
        return result.observedState


class LeasedKeeneticCommandWorkerClient:
    """Issue one encrypted service lease only after Core's actor guard passes."""

    def __init__(
        self, client, issuer, *, worker_id, ttl_seconds=10, egress=None
    ):
        if (
            not isinstance(client, KeeneticCommandWorkerClient)
            or not isinstance(worker_id, str)
            or len(worker_id) != 32
            or any(char not in "0123456789abcdef" for char in worker_id)
            or type(ttl_seconds) is not int
            or not 1 <= ttl_seconds <= 30
        ):
            raise KeeneticEffectError("keenetic_effect_unavailable")
        self._client = client
        self._issuer = issuer
        self._worker_id = worker_id
        self._ttl = ttl_seconds
        self._egress = egress

    def __repr__(self):
        return "LeasedKeeneticCommandWorkerClient(<private>)"

    def execute_for_actor(self, actor, request, guard):
        guard()
        if not callable(self._egress):
            raise KeeneticEffectError("keenetic_effect_unavailable")
        addresses = self._egress(actor, request.target)
        lease = self._issuer.issue(
            actor,
            request.target,
            worker_id=self._worker_id,
            ttl_seconds=self._ttl,
            allowed_addresses=addresses,
        )
        command = KeeneticWorkerCommand.from_request(
            request,
            timeout_ms=max(50, min(10000, int(self._client.timeout * 1000))),
            credential_lease=lease,
        )
        return self._client.execute(command, guard=guard)


class KeeneticCommandWorkerServer(PreflightWorkerServer):
    """Owned Unix fixture/runtime boundary; it contains no router transport."""

    def __init__(self, path, handler=None, *, allowed_uid, socket_gid=None,
                 peer_uid=None, timeout=5):
        self.handler = handler or UnavailableKeeneticCommandHandler()
        self._seen_packet_ids = set()
        self._seen_command_ids = set()
        super().__init__(
            path,
            self.handler,
            platform="linux/amd64",
            allowed_uid=allowed_uid,
            socket_gid=socket_gid,
            peer_uid=peer_uid,
            timeout=timeout,
        )

    def _answer(self, request, *, deadline=None):
        deadline = time.monotonic() + self.timeout if deadline is None else deadline
        if (
            set(request) != {
                "protocol", "requestId", "operation", "command"
            }
            or request["operation"] != "keenetic_command_execute"
        ):
            raise PreflightIPCError("invalid_request")
        try:
            command = KeeneticWorkerCommand.model_validate(request["command"])
            packet_id = request["requestId"]
            if (packet_id in self._seen_packet_ids
                    or command.requestId in self._seen_command_ids
                    or len(self._seen_packet_ids) >= MAX_SEALED_REQUESTS):
                raise PreflightIPCError("invalid_request")
            # Seal both identities before dispatch. A lost response can never
            # make the same Core command executable again in this worker.
            self._seen_packet_ids.add(packet_id)
            self._seen_command_ids.add(command.requestId)
            command_deadline = min(
                deadline, time.monotonic() + command.timeoutMs / 1000
            )
            try:
                result = self.handler.execute(
                    command,
                    deadline=command_deadline,
                    cancelled=self._stopped.is_set,
                )
            except KeeneticEffectError as error:
                code = error.code
                allowed = {
                    "keenetic_effect_unavailable",
                    "keenetic_effect_rejected",
                    "keenetic_effect_cancelled",
                    "keenetic_effect_timeout",
                    "keenetic_effect_unknown",
                    "keenetic_worker_restarted",
                    "keenetic_result_unknown",
                }
                if code not in allowed:
                    code = "keenetic_effect_unknown"
                result = KeeneticWorkerResult.error_for_command(
                    command, code, uncertain=error.uncertain
                )
            return KeeneticWorkerResult.for_command(
                command, result
            ).model_dump(mode="json")
        except (PreflightIPCError, ValidationError, ValueError, TypeError):
            raise PreflightIPCError("invalid_request") from None

    @property
    def is_alive(self):
        """Expose only liveness; no thread, path or transport details escape."""
        return self._thread is not None and self._thread.is_alive()
