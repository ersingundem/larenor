"""Journal and endpoint authority around Jellyfin playback protocol effects."""

import math
import re
import time

from .catalog import load_catalog
from .jellyfin_endpoint import (
    JellyfinEndpointError,
    open_jellyfin_endpoint,
    prove_jellyfin_endpoint,
)
from .jellyfin_playback_runtime import (
    JellyfinPlaybackProtocol,
    JellyfinPlaybackRuntimeError,
)
from .managed_container import (
    JournaledManagedContainerOperations,
    ManagedContainerBinding,
)
from .media_playback_models import (
    MediaPlaybackReadback,
    MediaPlaybackWorkerResult,
    PrivateJellyfinPlaybackAction,
    PrivateJellyfinPlaybackAuthority,
)
from .stack_plan import verify_media_stack_plan
from .worker import StepReceipt


class JellyfinPlaybackExecutionError(Exception):
    """Secret-free failure for a closed worker-side execution."""

    def __init__(self, code='jellyfin_playback_resources_unavailable', *,
                 uncertain_effect=False):
        self.code = code
        self.uncertain_effect = uncertain_effect is True
        super().__init__(code)

    def __repr__(self):
        return (f'JellyfinPlaybackExecutionError({self.code!r}, '
                f'uncertain_effect={self.uncertain_effect!r})')


class JellyfinPlaybackExecutor:
    def __init__(self, operations, binding_builder, protocol=None):
        if (type(operations) is not JournaledManagedContainerOperations
                or not callable(binding_builder)):
            raise JellyfinPlaybackExecutionError(
                'invalid_jellyfin_playback_execution')
        self.operations = operations
        self.binding_builder = binding_builder
        self.protocol = protocol or JellyfinPlaybackProtocol()
        if type(self.protocol) is not JellyfinPlaybackProtocol:
            raise JellyfinPlaybackExecutionError(
                'invalid_jellyfin_playback_execution')

    @staticmethod
    def _gate(gate):
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise JellyfinPlaybackExecutionError(
                'jellyfin_playback_authority_changed') from None

    @staticmethod
    def _deadline(deadline):
        if (type(deadline) not in (int, float) or type(deadline) is bool
                or not math.isfinite(deadline)
                or not time.monotonic() < deadline <= time.monotonic() + 10):
            raise JellyfinPlaybackExecutionError(
                'invalid_jellyfin_playback_execution')

    def _context(self, private, deadline, gate):
        self._deadline(deadline)
        self._gate(gate)
        try:
            plan = verify_media_stack_plan(private.plan, load_catalog())
            authority = getattr(private, 'authority', None)
            action = getattr(private, 'action', None)
            installation_id = (authority.installationId if authority is not None
                               else action.installationId)
            if re.fullmatch(r'[0-9a-f]{32}', installation_id) is None:
                raise ValueError()
            binding = self.binding_builder(plan)
            if type(binding) is not ManagedContainerBinding:
                raise ValueError()
            receipt = self.operations.reconcile(
                installation_id, 'start_container', binding)
            if (type(receipt) is not StepReceipt
                    or receipt.job_id != installation_id
                    or receipt.step != 'start_container'
                    or receipt.state != 'succeeded'
                    or receipt.code != 'container_started'
                    or type(receipt.container_id) is not str
                    or re.fullmatch(r'[0-9a-f]{64}', receipt.container_id) is None):
                raise ValueError()
            return plan, binding, receipt.container_id
        except JellyfinPlaybackExecutionError:
            raise
        except Exception:
            raise JellyfinPlaybackExecutionError() from None

    def _open(self, plan, binding, container_id, deadline):
        opened = None
        try:
            observed = self.operations.engine.inspect_container(binding.name)
            proof = prove_jellyfin_endpoint(
                observed, binding, plan, container_id)
            opened = open_jellyfin_endpoint(
                observed, binding, plan, container_id,
                timeout=min(5.0, max(.001, deadline - time.monotonic())))
            if opened.proof != proof:
                raise ValueError()
            return opened.connection, proof
        except Exception:
            if opened is not None:
                try:
                    opened.connection.close()
                except Exception:
                    pass
            raise JellyfinPlaybackExecutionError() from None

    def _final(self, plan, binding, container_id, proof, gate):
        self._gate(gate)
        try:
            observed = self.operations.engine.inspect_container(binding.name)
            if prove_jellyfin_endpoint(
                    observed, binding, plan, container_id) != proof:
                raise ValueError()
        except JellyfinEndpointError:
            raise JellyfinPlaybackExecutionError(
                'jellyfin_playback_endpoint_changed') from None
        except Exception:
            raise JellyfinPlaybackExecutionError(
                'jellyfin_playback_endpoint_changed') from None

    def read(self, private, *, deadline, gate):
        if type(private) is not PrivateJellyfinPlaybackAuthority:
            raise JellyfinPlaybackExecutionError(
                'invalid_jellyfin_playback_execution')
        plan, binding, container_id = self._context(private, deadline, gate)
        connection, proof = self._open(
            plan, binding, container_id, deadline)
        try:
            result = self.protocol.read(
                connection, api_key=private.apiKey,
                installation_id=private.authority.installationId,
                deadline=deadline)
        except JellyfinPlaybackRuntimeError:
            raise JellyfinPlaybackExecutionError() from None
        self._final(plan, binding, container_id, proof, gate)
        if type(result) is not MediaPlaybackReadback:
            raise JellyfinPlaybackExecutionError()
        return result

    def execute(self, private, *, deadline, gate):
        if type(private) is not PrivateJellyfinPlaybackAction:
            raise JellyfinPlaybackExecutionError(
                'invalid_jellyfin_playback_execution')
        plan, binding, container_id = self._context(private, deadline, gate)
        opened = []
        try:
            for _ in range(3):
                connection, proof = self._open(
                    plan, binding, container_id, deadline)
                opened.append((connection, proof))
                if len(opened) > 1 and proof != opened[0][1]:
                    raise JellyfinPlaybackExecutionError(
                        'jellyfin_playback_endpoint_changed')
            result = self.protocol.execute(
                tuple(item[0] for item in opened), private.action,
                api_key=private.apiKey, deadline=deadline, gate=gate)
        except JellyfinPlaybackExecutionError:
            for connection, _proof in opened:
                try:
                    connection.close()
                except Exception:
                    pass
            raise
        except JellyfinPlaybackRuntimeError as error:
            for connection, _proof in opened:
                try:
                    connection.close()
                except Exception:
                    pass
            if error.code == 'jellyfin_playback_authority_changed':
                raise JellyfinPlaybackExecutionError(
                    'jellyfin_playback_authority_changed') from None
            if not error.uncertain_effect:
                raise JellyfinPlaybackExecutionError() from None
            raise JellyfinPlaybackExecutionError(
                'jellyfin_playback_effect_unknown',
                uncertain_effect=True) from None
        try:
            self._final(plan, binding, container_id, opened[0][1], gate)
        except JellyfinPlaybackExecutionError:
            raise JellyfinPlaybackExecutionError(
                'jellyfin_playback_effect_unknown',
                uncertain_effect=True) from None
        if type(result) is not MediaPlaybackWorkerResult:
            raise JellyfinPlaybackExecutionError(
                'jellyfin_playback_effect_unknown', uncertain_effect=True)
        return result
