#!/usr/bin/env python3
"""Opt-in native Seerr start, fresh-state and restart acceptance."""

from contextlib import contextmanager
from dataclasses import dataclass, replace
import json
import os
from pathlib import Path
import platform
import re
import secrets
import signal
import sys
import threading
import time
import uuid

from tool import qbittorrent_managed_ci as shared


smoke = shared.smoke
_DIAGNOSTIC_PHASES = {
    "resource_prepare": "seerr_resource_prepare_failed",
    "helper_build": "seerr_helper_build_failed",
    "volume_prepare": "seerr_volume_prepare_failed",
    "native_lifecycle": "seerr_native_lifecycle_failed",
    "native_convergence": "seerr_native_convergence_failed",
    "jellyfin_peer": "seerr_jellyfin_peer_failed",
    "arr_peers": "seerr_arr_peers_failed",
    "bootstrap": "seerr_bootstrap_failed",
    "restart_readback": "seerr_restart_readback_failed",
    "journal_setup": "seerr_journal_setup_failed",
    "runtime_setup": "seerr_runtime_setup_failed",
    "container_create": "seerr_container_create_failed",
    "container_start": "seerr_container_start_failed",
    "fresh_state": "seerr_fresh_state_failed",
    "resource_verify": "seerr_resource_verify_failed",
    "container_restart": "seerr_container_restart_failed",
    "restart_state": "seerr_restart_state_failed",
}
_DIAGNOSTIC_CODES = frozenset(
    {
        "seerr_characterization_evidence_invalid",
        "seerr_characterization_cancelled",
        "seerr_characterization_failed",
        *_DIAGNOSTIC_PHASES.values(),
    }
)
_BOOTSTRAP_CODES = frozenset(
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
_BOOTSTRAP_CAUSES = frozenset(
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


class SeerrManagedCIError(Exception):
    """Closed native evidence failure; private Engine data never escapes."""

    def __init__(
        self,
        code,
        *,
        bootstrap_code=None,
        cause_code=None,
        completed_steps=None,
    ):
        self.bootstrap_code = (
            bootstrap_code if bootstrap_code in _BOOTSTRAP_CODES else None
        )
        self.cause_code = cause_code if cause_code in _BOOTSTRAP_CAUSES else None
        self.completed_steps = (
            completed_steps
            if type(completed_steps) is int and 0 <= completed_steps <= 6
            else None
        )
        if self.bootstrap_code is None:
            self.cause_code = self.completed_steps = None
        super().__init__(code if code in _DIAGNOSTIC_CODES else "seerr_characterization_failed")

    def diagnostic(self):
        code = self.args[0]
        if self.bootstrap_code is None:
            return code
        cause = self.cause_code or "none"
        return (
            f"{code} code={self.bootstrap_code} cause={cause} "
            f"completed={self.completed_steps}"
        )

    def __repr__(self):
        return f"SeerrManagedCIError({self.diagnostic()!r})"


class _Cancelled(BaseException):
    pass


def require(value):
    if not value:
        raise SeerrManagedCIError("seerr_characterization_evidence_invalid")


@contextmanager
def diagnostic_phase(phase):
    code = _DIAGNOSTIC_PHASES.get(phase)
    if code is None:
        raise SeerrManagedCIError("seerr_characterization_evidence_invalid")
    try:
        yield
    except SeerrManagedCIError as error:
        if error.args == ("seerr_characterization_evidence_invalid",):
            raise SeerrManagedCIError(code) from None
        raise
    except smoke.SmokeError:
        raise
    except Exception:
        raise SeerrManagedCIError(code) from None


def validate_launch(environment, system, machine, uid):
    selected = smoke.native_platform(environment, system, machine, uid)
    event = environment.get("GITHUB_EVENT_NAME")
    repository = environment.get("GITHUB_REPOSITORY")
    manual = (
        event == "workflow_dispatch"
        and environment.get("GITHUB_REF") == "refs/heads/main"
        and environment.get("GITHUB_BASE_REF") == ""
        and environment.get("PR_HEAD_REPOSITORY") == ""
    )
    pull_request = (
        event == "pull_request"
        and re.fullmatch(
            r"refs/pull/[1-9][0-9]*/merge", environment.get("GITHUB_REF", "")
        )
        and environment.get("GITHUB_BASE_REF") == "main"
        and environment.get("PR_HEAD_REPOSITORY") == repository
    )
    require(
        (manual or pull_request)
        and repository == "ersingundem/larenor"
        and environment.get("GITHUB_WORKFLOW_SHA") == environment.get("GITHUB_SHA")
        and environment.get("EXPECTED_PLATFORM") == selected
    )
    return selected


def fixture_source(selected_platform):
    """Select only the pinned Seerr image and owned appdata volume."""
    base = smoke.fixture_source(selected_platform)
    image = next(
        item
        for item in base.plan.resources
        if item.kind == "ensure_image" and item.serviceId == "seerr"
    )
    targets = tuple(
        item
        for item in base.volumes.resources
        if item.serviceId == "seerr" and item.kind == "managed_appdata"
    )
    require(
        len(targets) == 1
        and targets[0].target == "/app/config"
        and targets[0].serviceId == "seerr"
    )
    return replace(base, image=image, targets=targets, managed_targets=targets)


def _same(left, right):
    if type(left) is not type(right):
        return False
    if type(right) is dict:
        return left.keys() == right.keys() and all(
            _same(left[key], value) for key, value in right.items()
        )
    if type(right) is list:
        return len(left) == len(right) and all(
            _same(item, value) for item, value in zip(left, right)
        )
    return left == right


def validate_receipt(value, commit, selected):
    require(
        type(commit) is str
        and re.fullmatch(r"[0-9a-f]{40}", commit)
        and selected in {"linux/amd64", "linux/arm64"}
        and type(value) is dict
        and type(value.get("helper")) is dict
    )
    source = fixture_source(selected)
    component = next(
        item.manifest
        for item in source.catalog.entries
        if item.manifest.serviceId == "seerr"
    )
    hashes = smoke.source_hashes()
    helper = value["helper"]
    helper_digest = helper.get("configDigest")
    require(
        type(helper_digest) is str
        and re.fullmatch(r"sha256:[0-9a-f]{64}", helper_digest)
    )
    expected = {
        "schemaVersion": 2,
        "result": "seerr_characterized",
        "serviceVersion": component.version,
        "platform": selected,
        "sourceCommit": commit,
        "catalogDigest": source.catalog.digest,
        "seerrManifestDigest": source.image.image.digest,
        "seerrConfigDigest": source.image.image.configDigest,
        "helper": {
            "configDigest": helper_digest,
            "platform": selected,
            "sourceCommit": commit,
            "publishedManifestDigest": None,
            "helperSourceSha256": hashes["tool/volume_bootstrap_helper.py"],
            "probeSourceSha256": hashes["tool/jellyfin_storage_probe.py"],
            "dockerfileSha256": hashes["server/Dockerfile.volume-bootstrap"],
            "sourceHashes": hashes,
        },
        "imageState": "ready",
        "networkState": "ready",
        "volumeStates": ["observed_requires_bootstrap"],
        "volumeCount": 1,
        "containerMode": "journaled_managed_v2",
        "containerJournalVersion": 2,
        "containerState": "seerr_container_started",
        "freshStateVerified": True,
        "adminState": "verified",
        "adminSessionClosed": True,
        "arrWiringState": "verified",
        "arrServiceIds": ["radarr", "sonarr"],
        "initializationState": "verified",
        "initializationChanged": True,
        "authenticatedReadbackVerified": True,
        "restartCount": 1,
        "freshStatePersistent": True,
        "restartIdempotent": True,
        "installAvailable": False,
    }
    require(_same(value, expected))


def _stack_sources(selected_platform):
    """Project the four real services over one exact stack and policy."""
    base = smoke.fixture_source(selected_platform)

    def selected(service_id, targets):
        image = next(
            item
            for item in base.plan.resources
            if item.kind == "ensure_image" and item.serviceId == service_id
        )
        chosen = tuple(item for item in base.volumes.resources if targets(item))
        return replace(base, image=image, targets=chosen, managed_targets=chosen)

    sources = {
        "jellyfin": replace(
            base,
            targets=base.managed_targets,
            managed_targets=base.managed_targets,
        ),
        "seerr": selected(
            "seerr",
            lambda item: item.serviceId == "seerr"
            and item.kind == "managed_appdata",
        ),
        "radarr": selected(
            "radarr",
            lambda item: (
                item.serviceId == "radarr" and item.kind == "managed_appdata"
            )
            or item.kind == "managed_library",
        ),
        "sonarr": selected(
            "sonarr",
            lambda item: (
                item.serviceId == "sonarr" and item.kind == "managed_appdata"
            )
            or item.kind == "managed_library",
        ),
    }
    require(
        tuple(sources) == ("jellyfin", "seerr", "radarr", "sonarr")
        and len(sources["jellyfin"].targets) == 3
        and len(sources["seerr"].targets) == 1
        and len(sources["radarr"].targets) == 2
        and len(sources["sonarr"].targets) == 2
    )
    return sources


def _unique_targets(sources):
    by_resource = {}
    for source in sources.values():
        for target in source.targets:
            previous = by_resource.setdefault(target.resourceId, target)
            require(previous == target)
    return tuple(by_resource.values())


def _prepare_resources(daemon, sources):
    from larenor_server.plugins.docker_probe import DockerEndpoint
    from larenor_server.plugins.image_preparation import JournaledImageOperations
    from larenor_server.plugins.image_resources import UnixImageEngine
    from larenor_server.plugins.network_effects import UnixNetworkCreator
    from larenor_server.plugins.network_transport import UnixNetworkEngine
    from larenor_server.plugins.resource_journal import ResourceJournal
    from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
    from larenor_server.plugins.volume_effects import UnixVolumeCreator
    from larenor_server.plugins.volume_preparation import JournaledVolumeCreates
    from tool.media_resource_smoke import characterize_resources

    base = sources["jellyfin"]
    endpoint = DockerEndpoint(str(daemon.root / "engine.sock"), owner_uid=0)
    images = UnixImageEngine(endpoint)
    characterize_resources(
        daemon.root,
        base,
        images,
        UnixNetworkEngine(endpoint),
        UnixNetworkCreator(endpoint),
    )
    arguments = {
        "plan": base.plan,
        "stack": base.stack,
        "catalog": base.catalog,
        "policy": base.policy,
    }
    cancelled = threading.Event()
    with ResourceJournal(daemon.root / "resource-journal") as journal:
        operations = JournaledImageOperations(journal, images)
        image_states = ["ready"]
        for service_id in ("seerr", "radarr", "sonarr"):
            receipt = operations.apply(
                **arguments,
                resource_id=sources[service_id].image.resourceId,
                authorize_pull=lambda: True,
                cancelled=cancelled,
            )
            image_states.append(receipt.state)
    creator = UnixVolumeCreator(endpoint)
    with VolumeCreateJournal(
        daemon.root / "volume-journal", initialize=True
    ) as journal:
        operations = JournaledVolumeCreates(journal, creator)
        states = {}
        for target in _unique_targets(sources):
            receipt = operations.apply(
                base.volumes,
                base.stack,
                base.catalog,
                base.policy,
                target.resourceId,
                authorize_create=lambda: True,
                cancelled=cancelled,
            )
            states[target.resourceId] = receipt.state
    require(
        image_states == ["ready"] * 4
        and set(states.values()) == {"observed_requires_bootstrap"}
    )
    seerr_target = sources["seerr"].targets[0]
    return endpoint, [states[seerr_target.resourceId]]


def _prepare_volumes(daemon, sources, helper_id):
    for target in _unique_targets(sources):
        owner = tuple(int(value) for value in target.containerUser.split(":"))
        require(owner in {(0, 0), (1000, 1000)})
        if owner == (1000, 1000):
            require(
                smoke._helper(daemon, helper_id, "writable", target=target)
                == {"writable": False, "uid": 1000, "gid": 1000}
            )
        require(
            smoke._helper(
                daemon, helper_id, "check", target=target, bootstrap=True
            )
            == {"schemaVersion": 1, "state": "empty_uninitialized"}
        )
        require(
            smoke._helper(
                daemon,
                helper_id,
                (
                    "initialize_empty_root_as_root"
                    if owner == (0, 0)
                    else "initialize_empty_root"
                ),
                target=target,
                bootstrap=True,
            )
            == {"schemaVersion": 1, "state": "empty_initialized"}
        )
        require(
            smoke._helper(daemon, helper_id, "writable", target=target)
            == {"writable": True, "uid": owner[0], "gid": owner[1]}
        )
        if target.kind == "managed_library":
            require(
                smoke._helper(
                    daemon,
                    helper_id,
                    "prepare_media_directories",
                    target=target,
                    bootstrap=True,
                )
                == {"schemaVersion": 1, "state": "media_directories_prepared"}
            )


@dataclass(frozen=True)
class _SeerrNativeResult:
    state: str
    fresh: bool
    persistent: bool
    admin_state: str
    admin_session_closed: bool
    arr_service_ids: tuple[str, ...]
    initialization_state: str
    initialization_changed: bool
    authenticated_readback: bool
    restart_idempotent: bool

    def __post_init__(self):
        require(
            self.state == "seerr_container_started"
            and self.fresh is True
            and self.persistent is True
            and self.admin_state == "verified"
            and self.admin_session_closed is True
            and self.arr_service_ids == ("radarr", "sonarr")
            and self.initialization_state == "verified"
            and self.initialization_changed is True
            and self.authenticated_readback is True
            and self.restart_idempotent is True
        )


def _open_seerr(engine, binding, stack, container_id, *, deadline):
    from larenor_server.plugins.seerr_endpoint import (
        SeerrEndpointError,
        open_seerr_endpoint,
    )
    while True:
        observed = engine.inspect_container(binding.name)
        try:
            opened = open_seerr_endpoint(
                observed,
                binding,
                stack,
                container_id,
                timeout=max(0.1, min(10.0, deadline - time.monotonic())),
            )
            break
        except SeerrEndpointError as error:
            if error.code != "seerr_endpoint_unavailable" or time.monotonic() >= deadline:
                raise
            time.sleep(0.2)
    return observed, opened.connection


@dataclass(frozen=True, repr=False)
class _ArrPeer:
    service_id: str
    binding: object
    api_key: str
    configuration: object
    container_id: str

    def __repr__(self):
        return f"_ArrPeer(service_id={self.service_id!r}, <private>)"


def _binding_builder(source, endpoint, helper_id, resources, volumes, containers):
    from larenor_server.plugins.managed_container import (
        JellyfinBindingBuilder,
        JellyfinEngineReaders,
        JellyfinResourceProofBroker,
    )
    from larenor_server.plugins.volume_bootstrap import VolumeBootstrapVerifier

    verifier = VolumeBootstrapVerifier(endpoint, helper_id, source.plan.platform)
    readers = JellyfinEngineReaders(endpoint, verifier)

    def build(stack, service_id="jellyfin"):
        require(service_id in {"jellyfin", "radarr", "sonarr", "seerr"})
        broker = JellyfinResourceProofBroker(
                source.stack,
                source.catalog,
                source.policy,
                resources,
                volumes,
                readers,
                engine_identity=endpoint,
                service_id=service_id,
            )
        return JellyfinBindingBuilder(
            source.catalog,
            source.policy,
            containers.identity,
            broker,
            service_id=service_id,
        )(stack)

    return build


def _install_arr(daemon, source, endpoint, helper_id, service_id):
    from larenor_server.plugins.arr_config_models import PrivateArrConfiguration
    from larenor_server.plugins.managed_container import (
        JournaledManagedContainerOperations,
        ManagedWorkerJournal,
        managed_container_matches,
    )
    from larenor_server.plugins.resource_journal import ResourceJournal
    from larenor_server.plugins.volume_create_journal import VolumeCreateJournal

    private = PrivateArrConfiguration(
        serviceId=service_id, apiKey=secrets.token_hex(16)
    )
    with (
        ResourceJournal(daemon.root / "resource-journal") as resources,
        VolumeCreateJournal(daemon.root / "volume-journal") as volumes,
        ManagedWorkerJournal(daemon.root / "managed-container-journal") as containers,
    ):
        binding_builder = _binding_builder(
            source, endpoint, helper_id, resources, volumes, containers
        )
        engine = smoke._managed_engine(endpoint)
        operations = JournaledManagedContainerOperations(containers, engine)
        backend = shared._runtime_backend(
            operations,
            binding_builder,
            endpoint,
            volumes,
            source.catalog,
            source.policy,
            helper_id,
            daemon.platform,
        )
        receipt = backend.install_configured_arr(
            uuid.uuid4().hex,
            source.stack,
            service_id,
            api_key=private.apiKey,
            cancelled=threading.Event(),
            deadline=time.monotonic() + 120,
            gate=lambda: True,
        )
        binding = binding_builder(source.stack, service_id)
        running = engine.inspect_container(receipt.container_id)
        require(
            receipt.state == service_id + "_container_started"
            and receipt.service_state == service_id + "_service_verified"
            and managed_container_matches(running, binding)
            and running.get("State", {}).get("Running") is True
        )
        host = binding.payload()["specification"]["HostConfig"]
        daemon.verify_container_resources(
            running.get("State", {}).get("Pid"),
            host["Memory"],
            host["NanoCpus"],
            host["PidsLimit"],
        )
        return _ArrPeer(
            service_id,
            binding,
            private.apiKey,
            receipt.configuration,
            receipt.container_id,
        )


def _converge_seerr(
    daemon, source, endpoint, helper_id, jellyfin_peer, arr_peers
):
    from larenor_server.plugins.managed_container import (
        JournaledManagedContainerOperations,
        ManagedWorkerJournal,
        managed_container_matches,
    )
    from larenor_server.plugins.resource_journal import ResourceJournal
    from larenor_server.plugins.seerr_arr_wiring import (
        SeerrArrService,
        SeerrArrWiring,
    )
    from larenor_server.plugins.seerr_bootstrap_executor import (
        SeerrBootstrapExecutionError,
        SeerrBootstrapExecutor,
    )
    from larenor_server.plugins.seerr_bootstrap_models import (
        PINNED_ARR_HD_1080P_PROFILE_ID,
        PrivateSeerrArrBinding,
        PrivateSeerrBootstrap,
    )
    from larenor_server.plugins.seerr_initial_admin import SeerrInitialAdmin
    from larenor_server.plugins.seerr_initialization import SeerrInitialization
    from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
    from larenor_server.plugins.worker import WorkerStep

    job = uuid.uuid4().hex
    with (
        ResourceJournal(daemon.root / "resource-journal") as resources,
        VolumeCreateJournal(daemon.root / "volume-journal") as volumes,
        ManagedWorkerJournal(daemon.root / "managed-container-journal") as containers,
    ):
        binding_builder = _binding_builder(
            source, endpoint, helper_id, resources, volumes, containers
        )
        engine = smoke._managed_engine(endpoint)
        operations = JournaledManagedContainerOperations(containers, engine)
        seerr_binding = binding_builder(source.stack, "seerr")

        def command(kind):
            return WorkerStep(
                job,
                seerr_binding.name.removeprefix("larenor-"),
                kind,
                uuid.uuid4().hex,
                time.time() + 120,
            )

        created = operations.apply(command("create_container"), seerr_binding)
        require(created.state == "succeeded" and created.container_id is not None)
        started = operations.apply(command("start_container"), seerr_binding)
        require(
            started.state == "succeeded"
            and started.code == "container_started"
            and started.container_id == created.container_id
        )
        _ready, ready_connection = _open_seerr(
            engine,
            seerr_binding,
            source.stack,
            started.container_id,
            deadline=time.monotonic() + 120,
        )
        ready_connection.close()

        private_arr = tuple(
            PrivateSeerrArrBinding(
                serviceId=peer.service_id,
                configurationId=peer.configuration.resource_id,
                configurationRevision=peer.configuration.revision,
                resourceRevision=peer.configuration.revision,
                serviceRevision=peer.configuration.revision,
                configurationDigest=peer.configuration.configuration_digest,
                hostname=peer.binding.name,
                apiKey=peer.api_key,
                rootPath="/data/movies" if peer.service_id == "radarr" else "/data/shows",
                profileId=PINNED_ARR_HD_1080P_PROFILE_ID,
                profileName="HD-1080p",
            )
            for peer in arr_peers
        )
        private = PrivateSeerrBootstrap(
            credential=jellyfin_peer.credential,
            sourceBootstrapId=jellyfin_peer.binding.name.removeprefix("larenor-"),
            sourceBootstrapRevision=1,
            arrBindings=private_arr,
        )
        wiring = SeerrArrWiring()
        initialization = SeerrInitialization()
        try:
            bootstrap = SeerrBootstrapExecutor(
                operations,
                binding_builder,
                SeerrInitialAdmin(),
                wiring,
                initialization,
            ).execute(
                job,
                source.stack,
                private,
                deadline=time.monotonic() + 120,
                gate=lambda: True,
            )
        except SeerrBootstrapExecutionError as error:
            raise SeerrManagedCIError(
                "seerr_bootstrap_failed",
                bootstrap_code=error.code,
                cause_code=error.cause_code,
                completed_steps=len(error.completed_steps),
            ) from None
        require(
            bootstrap.state == "verified"
            and bootstrap.completed_steps
            == (
                "uninitialized_verified",
                "admin_created",
                "api_key_verified",
                "session_destroyed",
                "arr_wiring_verified",
                "initialization_verified",
            )
            and bootstrap.arr_wiring is not None
            and bootstrap.initialization is not None
            and bootstrap.initialization.changed is True
        )
        running = engine.inspect_container(seerr_binding.name)
        require(
            managed_container_matches(running, seerr_binding)
            and running.get("State", {}).get("Running") is True
        )
        host = seerr_binding.payload()["specification"]["HostConfig"]
        daemon.verify_container_resources(
            running.get("State", {}).get("Pid"),
            host["Memory"],
            host["NanoCpus"],
            host["PidsLimit"],
        )
        daemon.docker(
            ["restart", "--time=10", started.container_id], timeout=30, limit=128
        )
        restarted, connection = _open_seerr(
            engine,
            seerr_binding,
            source.stack,
            started.container_id,
            deadline=time.monotonic() + 120,
        )
        require(
            managed_container_matches(restarted, seerr_binding)
            and restarted.get("State", {}).get("Running") is True
        )
        services = tuple(
            SeerrArrService(
                peer.service_id,
                peer.binding.name,
                7878 if peer.service_id == "radarr" else 8989,
                peer.api_key,
                PINNED_ARR_HD_1080P_PROFILE_ID,
                "HD-1080p",
                "/data/movies" if peer.service_id == "radarr" else "/data/shows",
            )
            for peer in arr_peers
        )
        try:
            readback = wiring.configure(
                connection,
                seerr_api_key=bootstrap.api_key,
                services=services,
                total_seconds=45,
                close_connection=False,
            )
            initialized = initialization.complete(
                connection,
                seerr_api_key=bootstrap.api_key,
                total_seconds=30,
            )
        finally:
            connection.close()
        require(
            readback == bootstrap.arr_wiring
            and initialized.state == "verified"
            and initialized.changed is False
        )
        daemon.verify_container_resources(
            restarted.get("State", {}).get("Pid"),
            host["Memory"],
            host["NanoCpus"],
            host["PidsLimit"],
        )
        return _SeerrNativeResult(
            "seerr_container_started",
            True,
            True,
            bootstrap.state,
            "session_destroyed" in bootstrap.completed_steps,
            readback.service_ids,
            initialized.state,
            bootstrap.initialization.changed,
            True,
            initialized.changed is False,
        )


def _converge_native_stack(daemon, sources, checkout_binding):
    with diagnostic_phase("resource_prepare"):
        endpoint, volume_states = _prepare_resources(daemon, sources)
    with diagnostic_phase("helper_build"):
        helper_id, attestation = shared._build_helper(daemon, checkout_binding)
    with diagnostic_phase("volume_prepare"):
        _prepare_volumes(daemon, sources, helper_id)
    peers = []
    with diagnostic_phase("jellyfin_peer"):
        smoke._managed_create_and_start(
            daemon,
            sources["jellyfin"],
            endpoint,
            helper_id,
            peer_consumer=lambda peer: peers.append(peer),
        )
        require(len(peers) == 1)
    with diagnostic_phase("arr_peers"):
        arr_peers = tuple(
            _install_arr(daemon, sources[service_id], endpoint, helper_id, service_id)
            for service_id in ("radarr", "sonarr")
        )
    with diagnostic_phase("bootstrap"):
        result = _converge_seerr(
            daemon,
            sources["seerr"],
            endpoint,
            helper_id,
            peers[0],
            arr_peers,
        )
    return attestation, volume_states, result


def characterize(daemon, *, checkout_binding=None):
    checkout_binding = (
        smoke.capture_source(os.environ["GITHUB_SHA"])
        if checkout_binding is None
        else checkout_binding
    )
    smoke.check_source(checkout_binding)
    sources = _stack_sources(daemon.platform)
    source = sources["seerr"]
    with diagnostic_phase("native_convergence"):
        attestation, volume_states, result = _converge_native_stack(
            daemon, sources, checkout_binding
        )
    smoke.check_source(checkout_binding)
    component = next(
        item.manifest
        for item in source.catalog.entries
        if item.manifest.serviceId == "seerr"
    )
    return {
        "schemaVersion": 2,
        "result": "seerr_characterized",
        "serviceVersion": component.version,
        "platform": daemon.platform,
        "sourceCommit": checkout_binding[0],
        "catalogDigest": source.catalog.digest,
        "seerrManifestDigest": source.image.image.digest,
        "seerrConfigDigest": source.image.image.configDigest,
        "helper": attestation,
        "imageState": "ready",
        "networkState": "ready",
        "volumeStates": volume_states,
        "volumeCount": 1,
        "containerMode": "journaled_managed_v2",
        "containerJournalVersion": 2,
        "containerState": result.state,
        "freshStateVerified": result.fresh,
        "adminState": result.admin_state,
        "adminSessionClosed": result.admin_session_closed,
        "arrWiringState": "verified",
        "arrServiceIds": list(result.arr_service_ids),
        "initializationState": result.initialization_state,
        "initializationChanged": result.initialization_changed,
        "authenticatedReadbackVerified": result.authenticated_readback,
        "restartCount": 1,
        "freshStatePersistent": result.persistent,
        "restartIdempotent": result.restart_idempotent,
        "installAvailable": False,
    }


def run():
    selected = validate_launch(
        os.environ, platform.system(), platform.machine(), os.geteuid()
    )
    commit = os.environ["GITHUB_SHA"]
    owner = smoke.EphemeralDaemon()
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGALRM)
    previous = {item: signal.getsignal(item) for item in signals}

    def cancel(_signum, _frame):
        for item in signals:
            signal.signal(item, signal.SIG_IGN)
        owner.emergency_cleanup()
        raise _Cancelled()

    try:
        for item in signals:
            signal.signal(item, cancel)
        signal.alarm(2400)
        with smoke.diagnostic_phase("source_capture"):
            binding = smoke.capture_source(commit)
        with owner as daemon:
            value = characterize(daemon, checkout_binding=binding)
        with smoke.diagnostic_phase("source_recheck"):
            smoke.check_source(binding)
        validate_receipt(value, commit, selected)
        print(json.dumps(value, sort_keys=True, separators=(",", ":")))
    finally:
        signal.alarm(0)
        for item, handler in previous.items():
            signal.signal(item, handler)


def _unique(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value)
        value[key] = item
    return value


def _nonfinite(_value):
    raise SeerrManagedCIError("seerr_characterization_evidence_invalid")


def verify(path):
    try:
        with Path(path).open("rb") as source:
            raw = source.read(32769)
        require(0 < len(raw) <= 32768)
        value = json.loads(raw, object_pairs_hook=_unique, parse_constant=_nonfinite)
        commit = os.environ.get("GITHUB_SHA", "")
        selected = os.environ.get("EXPECTED_PLATFORM", "")
        smoke.verify_checkout(commit)
        validate_receipt(value, commit, selected)
        print("seerr_characterization_receipt_verified")
    except SeerrManagedCIError:
        raise
    except Exception:
        raise SeerrManagedCIError("seerr_characterization_evidence_invalid") from None


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    try:
        if args == ["--run-ephemeral-ci"]:
            run()
        elif len(args) == 2 and args[0] == "--verify-receipt":
            verify(args[1])
        else:
            raise SeerrManagedCIError("seerr_characterization_evidence_invalid")
        return 0
    except _Cancelled:
        print("seerr_characterization_cancelled", file=sys.stderr)
    except Exception as error:
        if type(error) is smoke.SmokeError:
            print(smoke.failure_diagnostic(error), file=sys.stderr)
        elif (
            type(error) is SeerrManagedCIError
            and error.args
            and error.args[0] in _DIAGNOSTIC_CODES
        ):
            print(error.diagnostic(), file=sys.stderr)
        else:
            print("seerr_characterization_failed", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
