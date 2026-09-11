"""Worker-private Seerr startup and initial administrator orchestration."""

from dataclasses import dataclass, field
import math
import re
import time

from pydantic import ValidationError

from .catalog import load_catalog
from .jellyfin_endpoint import JellyfinEndpointError, prove_jellyfin_endpoint
from .managed_container import (
    JournaledManagedContainerOperations,
    ManagedContainerBinding,
    ManagedContainerError,
)
from .seerr_bootstrap_models import PrivateSeerrBootstrap
from .seerr_arr_wiring import (
    SeerrArrService,
    SeerrArrWiring,
    SeerrArrWiringError,
    SeerrArrWiringResult,
)
from .seerr_endpoint import (
    SeerrEndpointError,
    open_seerr_endpoint,
    prove_seerr_endpoint,
)
from .seerr_initial_admin import (
    SeerrInitialAdmin,
    SeerrInitialAdminError,
    SeerrInitialAdminLimits,
    SeerrInitialAdminResult,
    _is_generated_key,
)
from .seerr_initialization import (
    SeerrInitialization,
    SeerrInitializationError,
    SeerrInitializationResult,
)
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .worker import DockerWorkerError, StepReceipt


_JOB = re.compile(r"[0-9a-f]{32}\Z")
_CONTAINER = re.compile(r"[0-9a-f]{64}\Z")
_CODES = frozenset(
    {
        "invalid_seerr_bootstrap_execution",
        "seerr_bootstrap_authority_changed",
        "seerr_bootstrap_resources_unavailable",
        "seerr_bootstrap_endpoint_unavailable",
        "seerr_bootstrap_endpoint_changed",
        "seerr_bootstrap_peer_changed",
        "seerr_bootstrap_initial_admin_failed",
        "seerr_bootstrap_arr_wiring_failed",
        "seerr_bootstrap_initialization_failed",
        "seerr_bootstrap_timeout",
    }
)
_CAUSE_CODES = frozenset(
    {
        "invalid_seerr_initial_admin",
        "seerr_initial_state_conflict",
        "seerr_initial_admin_conflict",
        "seerr_jellyfin_authentication_failed",
        "seerr_session_protocol",
        "seerr_api_key_protocol",
        "seerr_initial_admin_protocol",
        "seerr_initial_admin_unavailable",
        "seerr_initial_admin_timeout",
        "invalid_seerr_arr_wiring",
        "invalid_seerr_arr_service",
        "seerr_arr_conflict",
        "seerr_arr_selection_changed",
        "seerr_arr_protocol",
        "seerr_arr_unavailable",
        "seerr_arr_timeout",
        "invalid_seerr_initialization",
        "seerr_initialization_state_conflict",
        "seerr_initialization_protocol",
        "seerr_initialization_unavailable",
        "seerr_initialization_timeout",
    }
)


class SeerrBootstrapExecutionError(Exception):
    def __init__(
        self,
        code="seerr_bootstrap_resources_unavailable",
        *,
        completed_steps=(),
        uncertain_effect=False,
        cause_code=None,
        api_key=None,
        arr_wiring=None,
    ):
        self.code = code if code in _CODES else "seerr_bootstrap_resources_unavailable"
        try:
            steps = tuple(completed_steps)
        except (TypeError, RecursionError):
            steps = ()
        allowed = (
            "uninitialized_verified",
            "admin_created",
            "api_key_verified",
            "session_destroyed",
            "arr_wiring_verified",
            "initialization_verified",
        )
        self.completed_steps = steps if steps == allowed[: len(steps)] else ()
        self.uncertain_effect = uncertain_effect is True
        self.cause_code = cause_code if cause_code in _CAUSE_CODES else None
        self.api_key = api_key if _is_generated_key(api_key) else None
        self.arr_wiring = (
            arr_wiring if type(arr_wiring) is SeerrArrWiringResult else None
        )
        super().__init__(self.code)

    def __repr__(self):
        return (
            f"SeerrBootstrapExecutionError({self.code!r}, "
            f"completed_steps={len(self.completed_steps)}, "
            f"uncertain_effect={self.uncertain_effect!r}, "
            f"cause_code={self.cause_code!r})"
        )


@dataclass(frozen=True, repr=False)
class SeerrBootstrapExecutionResult:
    state: str
    api_key: str = field(repr=False)
    completed_steps: tuple[str, ...]
    arr_wiring: SeerrArrWiringResult | None = field(default=None, repr=False)
    initialization: SeerrInitializationResult | None = field(default=None, repr=False)

    def __post_init__(self):
        try:
            verified = SeerrInitialAdminResult(
                self.state, self.api_key, self.completed_steps[:4]
            )
        except (SeerrInitialAdminError, ValueError, TypeError, AttributeError):
            raise SeerrBootstrapExecutionError(
                "invalid_seerr_bootstrap_execution"
            ) from None
        if verified.state != "verified":
            raise SeerrBootstrapExecutionError("invalid_seerr_bootstrap_execution")
        if self.arr_wiring is None and self.completed_steps != (
            "uninitialized_verified",
            "admin_created",
            "api_key_verified",
            "session_destroyed",
        ):
            raise SeerrBootstrapExecutionError("invalid_seerr_bootstrap_execution")
        if self.arr_wiring is not None and (
            type(self.arr_wiring) is not SeerrArrWiringResult
            or self.arr_wiring.state != "verified"
            or self.completed_steps[-1:]
            not in (("arr_wiring_verified",), ("initialization_verified",))
        ):
            raise SeerrBootstrapExecutionError("invalid_seerr_bootstrap_execution")
        if self.initialization is None and self.completed_steps[-1:] == (
            "initialization_verified",
        ):
            raise SeerrBootstrapExecutionError("invalid_seerr_bootstrap_execution")
        if self.initialization is not None and (
            type(self.initialization) is not SeerrInitializationResult
            or self.initialization.state != "verified"
            or self.completed_steps[-1:] != ("initialization_verified",)
        ):
            raise SeerrBootstrapExecutionError("invalid_seerr_bootstrap_execution")

    def __repr__(self):
        return (
            f"SeerrBootstrapExecutionResult(state={self.state!r}, "
            f"completed_steps={len(self.completed_steps)})"
        )


def _remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise SeerrBootstrapExecutionError("seerr_bootstrap_timeout")
    return value


class SeerrBootstrapExecutor:
    """Bootstrap Seerr only while its managed Jellyfin peer remains exact."""

    def __init__(
        self,
        operations,
        binding_builder,
        initial_admin,
        arr_wiring=None,
        initialization=None,
    ):
        if (
            type(operations) is not JournaledManagedContainerOperations
            or not callable(binding_builder)
            or type(initial_admin) is not SeerrInitialAdmin
            or arr_wiring is not None and type(arr_wiring) is not SeerrArrWiring
            or initialization is not None
            and type(initialization) is not SeerrInitialization
            or initialization is not None
            and arr_wiring is None
        ):
            raise SeerrBootstrapExecutionError("invalid_seerr_bootstrap_execution")
        self.operations = operations
        self.binding_builder = binding_builder
        self.initial_admin = initial_admin
        self.arr_wiring = arr_wiring
        self.initialization = initialization

    @staticmethod
    def _gate(gate, uncertain=False):
        try:
            if gate() is not True:
                raise ValueError()
        except Exception:
            raise SeerrBootstrapExecutionError(
                "seerr_bootstrap_authority_changed", uncertain_effect=uncertain
            ) from None

    @staticmethod
    def _inputs(job, stack, private, deadline, gate):
        now = time.monotonic()
        if (
            type(job) is not str
            or _JOB.fullmatch(job) is None
            or type(stack) is not MediaStackPlan
            or type(private) is not PrivateSeerrBootstrap
            or type(deadline) not in (int, float)
            or not math.isfinite(deadline)
            or not now < deadline <= now + 120
            or not callable(gate)
        ):
            raise SeerrBootstrapExecutionError("invalid_seerr_bootstrap_execution")
        try:
            trusted = verify_media_stack_plan(stack, load_catalog())
            secret = PrivateSeerrBootstrap.model_validate(
                private.model_dump(mode="python")
            )
            if secret.sourceBootstrapId == job:
                raise ValueError()
            return trusted, secret
        except (ValidationError, ValueError, TypeError, AttributeError, OSError):
            raise SeerrBootstrapExecutionError(
                "invalid_seerr_bootstrap_execution"
            ) from None

    @staticmethod
    def _running_jellyfin(
        observed, binding, stack, *, completed_steps=(), uncertain_effect=False
    ):
        try:
            identity = observed.get("Id")
            if type(identity) is not str or _CONTAINER.fullmatch(identity) is None:
                raise ValueError()
            return prove_jellyfin_endpoint(observed, binding, stack, identity)
        except (JellyfinEndpointError, ValueError, TypeError, AttributeError):
            raise SeerrBootstrapExecutionError(
                "seerr_bootstrap_peer_changed",
                completed_steps=completed_steps,
                uncertain_effect=uncertain_effect,
            ) from None

    def execute(self, job, stack, private, *, deadline, gate):
        trusted, secret = self._inputs(job, stack, private, deadline, gate)
        opened = None
        called = False
        completed = ()
        self._gate(gate)
        try:
            seerr = self.binding_builder(trusted, "seerr")
            jellyfin = self.binding_builder(trusted, "jellyfin")
            if (
                type(seerr) is not ManagedContainerBinding
                or type(jellyfin) is not ManagedContainerBinding
                or seerr.name == jellyfin.name
                or seerr.network_id != jellyfin.network_id
            ):
                raise SeerrBootstrapExecutionError("seerr_bootstrap_peer_changed")
            receipt = self.operations.reconcile(job, "start_container", seerr)
            if (
                type(receipt) is not StepReceipt
                or receipt.job_id != job
                or receipt.step != "start_container"
                or receipt.state != "succeeded"
                or receipt.code != "container_started"
                or type(receipt.container_id) is not str
                or _CONTAINER.fullmatch(receipt.container_id) is None
            ):
                raise ValueError()
            seerr_observed = self.operations.engine.inspect_container(seerr.name)
            seerr_proof = prove_seerr_endpoint(
                seerr_observed, seerr, trusted, receipt.container_id
            )
            jellyfin_observed = self.operations.engine.inspect_container(jellyfin.name)
            jellyfin_proof = self._running_jellyfin(
                jellyfin_observed, jellyfin, trusted
            )
            if seerr_proof.network_id != jellyfin_proof.network_id:
                raise SeerrBootstrapExecutionError("seerr_bootstrap_peer_changed")
            self._gate(gate)
            opened = open_seerr_endpoint(
                seerr_observed,
                seerr,
                trusted,
                receipt.container_id,
                timeout=min(10.0, _remaining(deadline)),
            )
            seerr_current = self.operations.engine.inspect_container(seerr.name)
            jellyfin_current = self.operations.engine.inspect_container(jellyfin.name)
            if (
                opened.proof != seerr_proof
                or prove_seerr_endpoint(
                    seerr_current, seerr, trusted, receipt.container_id
                )
                != seerr_proof
                or self._running_jellyfin(jellyfin_current, jellyfin, trusted)
                != jellyfin_proof
            ):
                raise SeerrBootstrapExecutionError("seerr_bootstrap_peer_changed")
            self._gate(gate)
            called = True
            result = self.initial_admin.create(
                opened.connection,
                username=secret.username,
                credential=secret.credential,
                jellyfin_hostname=jellyfin.name,
                limits=SeerrInitialAdminLimits(
                    total_seconds=min(45.0, _remaining(deadline))
                ),
                close_connection=self.arr_wiring is None,
            )
            if type(result) is not SeerrInitialAdminResult:
                raise SeerrBootstrapExecutionError(
                    "seerr_bootstrap_initial_admin_failed",
                    uncertain_effect=True,
                )
            try:
                result = SeerrInitialAdminResult(
                    result.state, result.api_key, result.completed_steps
                )
            except (SeerrInitialAdminError, ValueError, TypeError, AttributeError):
                raise SeerrBootstrapExecutionError(
                    "seerr_bootstrap_initial_admin_failed",
                    uncertain_effect=True,
                ) from None
            completed = result.completed_steps
            wiring = None
            initialized = None
            if self.arr_wiring is not None:
                if len(secret.arrBindings) != 2:
                    raise SeerrBootstrapExecutionError(
                        "invalid_seerr_bootstrap_execution",
                        completed_steps=completed,
                        uncertain_effect=True,
                        api_key=result.api_key,
                    )
                services = tuple(
                    SeerrArrService(
                        item.serviceId,
                        item.hostname,
                        7878 if item.serviceId == "radarr" else 8989,
                        item.apiKey,
                        item.profileId,
                        item.profileName,
                        item.rootPath,
                    )
                    for item in secret.arrBindings
                )
                self._gate(gate, True)
                wiring = self.arr_wiring.configure(
                    opened.connection,
                    seerr_api_key=result.api_key,
                    services=services,
                    total_seconds=min(45.0, _remaining(deadline)),
                    close_connection=False,
                )
                completed = completed + ("arr_wiring_verified",)
                if self.initialization is not None:
                    self._gate(gate, True)
                    initialized = self.initialization.complete(
                        opened.connection,
                        seerr_api_key=result.api_key,
                        total_seconds=min(30.0, _remaining(deadline)),
                    )
                    completed = completed + ("initialization_verified",)
                else:
                    initialized = None
            seerr_after = self.operations.engine.inspect_container(seerr.name)
            jellyfin_after = self.operations.engine.inspect_container(jellyfin.name)
            if (
                prove_seerr_endpoint(seerr_after, seerr, trusted, receipt.container_id)
                != seerr_proof
                or self._running_jellyfin(
                    jellyfin_after,
                    jellyfin,
                    trusted,
                    completed_steps=completed,
                    uncertain_effect=True,
                )
                != jellyfin_proof
            ):
                raise SeerrBootstrapExecutionError(
                    "seerr_bootstrap_peer_changed",
                    completed_steps=completed,
                    uncertain_effect=True,
                )
            self._gate(gate, True)
            _remaining(deadline)
            return SeerrBootstrapExecutionResult(
                result.state, result.api_key, completed, wiring, initialized
            )
        except SeerrBootstrapExecutionError:
            raise
        except SeerrInitialAdminError as error:
            raise SeerrBootstrapExecutionError(
                "seerr_bootstrap_initial_admin_failed",
                completed_steps=error.completed_steps,
                uncertain_effect=error.uncertain_effect,
                cause_code=error.code,
            ) from None
        except SeerrArrWiringError as error:
            raise SeerrBootstrapExecutionError(
                "seerr_bootstrap_arr_wiring_failed",
                completed_steps=completed,
                uncertain_effect=error.uncertain_effect or bool(completed),
                cause_code=error.code,
                api_key=result.api_key,
            ) from None
        except SeerrInitializationError as error:
            raise SeerrBootstrapExecutionError(
                "seerr_bootstrap_initialization_failed",
                completed_steps=completed,
                uncertain_effect=error.uncertain_effect or bool(completed),
                cause_code=error.code,
                api_key=result.api_key,
                arr_wiring=wiring,
            ) from None
        except SeerrEndpointError as error:
            code = (
                "seerr_bootstrap_timeout"
                if time.monotonic() >= deadline
                else "seerr_bootstrap_endpoint_unavailable"
                if error.code == "seerr_endpoint_unavailable"
                else "seerr_bootstrap_endpoint_changed"
            )
            raise SeerrBootstrapExecutionError(
                code,
                completed_steps=completed,
                uncertain_effect=bool(completed),
            ) from None
        except ManagedContainerError:
            raise SeerrBootstrapExecutionError(
                "seerr_bootstrap_resources_unavailable",
                completed_steps=completed,
                uncertain_effect=bool(completed),
            ) from None
        except (DockerWorkerError, ValueError, TypeError, AttributeError, RuntimeError):
            code = (
                "seerr_bootstrap_timeout"
                if time.monotonic() >= deadline
                else "seerr_bootstrap_resources_unavailable"
            )
            raise SeerrBootstrapExecutionError(
                code,
                completed_steps=completed,
                uncertain_effect=bool(completed),
            ) from None
        finally:
            if opened is not None:
                try:
                    opened.connection.close()
                except OSError:
                    pass
