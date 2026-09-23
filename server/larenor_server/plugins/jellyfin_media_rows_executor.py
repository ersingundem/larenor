"""Endpoint authority around account-specific Jellyfin media rows."""

import math
import re
import time

from .catalog import load_catalog
from .jellyfin_endpoint import (
    JellyfinEndpointError,
    open_jellyfin_endpoint,
    prove_jellyfin_endpoint,
)
from .jellyfin_media_rows_runtime import (
    JellyfinMediaRowsProtocol,
    JellyfinMediaRowsRuntimeError,
)
from .managed_container import (
    JournaledManagedContainerOperations,
    ManagedContainerBinding,
)
from .media_rows_models import (
    MediaRowsReadback,
    PrivateJellyfinMediaRowsAuthority,
)
from .stack_plan import verify_media_stack_plan
from .worker import StepReceipt


class JellyfinMediaRowsExecutionError(Exception):
    """Static worker error without account identity or upstream details."""

    _CODES = frozenset({
        "invalid_jellyfin_media_rows_execution",
        "jellyfin_media_rows_authority_changed",
        "jellyfin_media_rows_endpoint_changed",
        "jellyfin_media_rows_resources_unavailable",
    })

    def __init__(self, code="jellyfin_media_rows_resources_unavailable"):
        self.code = (
            code if code in self._CODES else "jellyfin_media_rows_resources_unavailable"
        )
        super().__init__(self.code)

    def __repr__(self):
        return f"JellyfinMediaRowsExecutionError({self.code!r})"


class JellyfinMediaRowsExecutor:
    def __init__(self, operations, binding_builder, protocol=None):
        if (
            type(operations) is not JournaledManagedContainerOperations
            or not callable(binding_builder)
        ):
            raise JellyfinMediaRowsExecutionError(
                "invalid_jellyfin_media_rows_execution"
            )
        self.operations = operations
        self.binding_builder = binding_builder
        self.protocol = protocol or JellyfinMediaRowsProtocol()
        if type(self.protocol) is not JellyfinMediaRowsProtocol:
            raise JellyfinMediaRowsExecutionError(
                "invalid_jellyfin_media_rows_execution"
            )

    @staticmethod
    def _gate(gate):
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise JellyfinMediaRowsExecutionError(
                "jellyfin_media_rows_authority_changed"
            ) from None

    @staticmethod
    def _deadline(deadline):
        if (
            type(deadline) not in (int, float)
            or type(deadline) is bool
            or not math.isfinite(deadline)
            or not time.monotonic() < deadline <= time.monotonic() + 10
        ):
            raise JellyfinMediaRowsExecutionError(
                "invalid_jellyfin_media_rows_execution"
            )

    def _context(self, private, deadline, gate):
        if type(private) is not PrivateJellyfinMediaRowsAuthority:
            raise JellyfinMediaRowsExecutionError(
                "invalid_jellyfin_media_rows_execution"
            )
        self._deadline(deadline)
        self._gate(gate)
        try:
            plan = verify_media_stack_plan(private.plan, load_catalog())
            if re.fullmatch(r"[0-9a-f]{32}", private.installationId) is None:
                raise ValueError()
            binding = self.binding_builder(plan)
            if type(binding) is not ManagedContainerBinding:
                raise ValueError()
            receipt = self.operations.reconcile(
                private.installationId, "start_container", binding
            )
            if (
                type(receipt) is not StepReceipt
                or receipt.job_id != private.installationId
                or receipt.step != "start_container"
                or receipt.state != "succeeded"
                or receipt.code != "container_started"
                or type(receipt.container_id) is not str
                or re.fullmatch(r"[0-9a-f]{64}", receipt.container_id) is None
            ):
                raise ValueError()
            return plan, binding, receipt.container_id
        except JellyfinMediaRowsExecutionError:
            raise
        except Exception:
            raise JellyfinMediaRowsExecutionError() from None

    def _open(self, plan, binding, container_id, deadline):
        opened = None
        try:
            observed = self.operations.engine.inspect_container(binding.name)
            proof = prove_jellyfin_endpoint(observed, binding, plan, container_id)
            opened = open_jellyfin_endpoint(
                observed,
                binding,
                plan,
                container_id,
                timeout=min(5.0, max(0.001, deadline - time.monotonic())),
            )
            if opened.proof != proof:
                raise JellyfinMediaRowsExecutionError(
                    "jellyfin_media_rows_endpoint_changed"
                )
            return opened.connection, proof
        except JellyfinMediaRowsExecutionError:
            if opened is not None:
                try:
                    opened.connection.close()
                except Exception:
                    pass
            raise
        except Exception:
            if opened is not None:
                try:
                    opened.connection.close()
                except Exception:
                    pass
            raise JellyfinMediaRowsExecutionError() from None

    def _final(self, plan, binding, container_id, proof, gate):
        self._gate(gate)
        try:
            observed = self.operations.engine.inspect_container(binding.name)
            if prove_jellyfin_endpoint(observed, binding, plan, container_id) != proof:
                raise ValueError()
        except JellyfinMediaRowsExecutionError:
            raise
        except (JellyfinEndpointError, ValueError, TypeError):
            raise JellyfinMediaRowsExecutionError(
                "jellyfin_media_rows_endpoint_changed"
            ) from None

    @staticmethod
    def _close(opened):
        for connection, _proof in opened:
            try:
                connection.close()
            except Exception:
                pass

    def read(self, private, *, deadline, gate):
        plan, binding, container_id = self._context(private, deadline, gate)
        opened = []
        try:
            for _ in range(2):
                self._gate(gate)
                connection, proof = self._open(
                    plan, binding, container_id, deadline
                )
                opened.append((connection, proof))
                if len(opened) > 1 and proof != opened[0][1]:
                    raise JellyfinMediaRowsExecutionError(
                        "jellyfin_media_rows_endpoint_changed"
                    )
            result = self.protocol.read(
                tuple(item[0] for item in opened),
                api_key=private.apiKey,
                user_id=private.userId,
                installation_id=private.installationId,
                deadline=deadline,
            )
            self._final(
                plan, binding, container_id, opened[0][1], gate
            )
        except JellyfinMediaRowsExecutionError:
            self._close(opened)
            raise
        except JellyfinMediaRowsRuntimeError:
            self._close(opened)
            raise JellyfinMediaRowsExecutionError() from None
        except Exception:
            self._close(opened)
            raise JellyfinMediaRowsExecutionError() from None
        if type(result) is not MediaRowsReadback:
            raise JellyfinMediaRowsExecutionError()
        return result
