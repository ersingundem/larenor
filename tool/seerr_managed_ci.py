#!/usr/bin/env python3
"""Opt-in native Seerr start, fresh-state and restart acceptance."""

from contextlib import contextmanager
from dataclasses import dataclass, replace
import json
import os
from pathlib import Path
import platform
import re
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


class SeerrManagedCIError(Exception):
    """Closed native evidence failure; private Engine data never escapes."""


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
        "schemaVersion": 1,
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
        "restartCount": 1,
        "freshStatePersistent": True,
        "installAvailable": False,
    }
    require(_same(value, expected))


def _prepare_resources(daemon, source):
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

    endpoint = DockerEndpoint(str(daemon.root / "engine.sock"), owner_uid=0)
    images = UnixImageEngine(endpoint)
    characterize_resources(
        daemon.root,
        source,
        images,
        UnixNetworkEngine(endpoint),
        UnixNetworkCreator(endpoint),
    )
    arguments = {
        "plan": source.plan,
        "stack": source.stack,
        "catalog": source.catalog,
        "policy": source.policy,
    }
    cancelled = threading.Event()
    with ResourceJournal(daemon.root / "resource-journal") as journal:
        image = JournaledImageOperations(journal, images).apply(
            **arguments,
            resource_id=source.image.resourceId,
            authorize_pull=lambda: True,
            cancelled=cancelled,
        )
    creator = UnixVolumeCreator(endpoint)
    with VolumeCreateJournal(
        daemon.root / "volume-journal", initialize=True
    ) as journal:
        receipt = JournaledVolumeCreates(journal, creator).apply(
            source.volumes,
            source.stack,
            source.catalog,
            source.policy,
            source.targets[0].resourceId,
            authorize_create=lambda: True,
            cancelled=cancelled,
        )
    require(image.state == "ready" and receipt.state == "observed_requires_bootstrap")
    return endpoint, [receipt.state]


@dataclass(frozen=True)
class _SeerrNativeResult:
    state: str
    fresh: bool
    persistent: bool


def _fresh_public_state(engine, binding, stack, container_id, *, deadline):
    from larenor_server.plugins.jellyfin_startup import _StartupReader
    from larenor_server.plugins.seerr_endpoint import (
        SeerrEndpointError,
        open_seerr_endpoint,
    )
    from larenor_server.plugins.seerr_initial_admin import (
        SeerrInitialAdmin,
        SeerrInitialAdminLimits,
        _PUBLIC_FIELDS,
        _json,
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
    connection = opened.connection
    try:
        limits = SeerrInitialAdminLimits(
            total_seconds=max(0.1, min(20.0, deadline - time.monotonic()))
        )
        reader = _StartupReader(connection, deadline)
        status, _headers, raw, _closed = SeerrInitialAdmin._request(
            connection,
            reader,
            deadline,
            limits,
            "GET",
            "/api/v1/settings/public",
            final=True,
        )
        value = _json(raw, "seerr_initial_state_conflict")
        require(
            status == 200
            and type(value) is dict
            and set(value) <= _PUBLIC_FIELDS
            and value.get("initialized") is False
            and value.get("applicationTitle") == "Seerr"
        )
        return observed
    finally:
        connection.close()


def _start_verify_restart(daemon, source, endpoint, helper_id):
    from larenor_server.plugins.managed_container import (
        JellyfinBindingBuilder,
        JellyfinEngineReaders,
        JellyfinResourceProofBroker,
        JournaledManagedContainerOperations,
        ManagedWorkerJournal,
        managed_container_matches,
    )
    from larenor_server.plugins.resource_journal import ResourceJournal
    from larenor_server.plugins.volume_bootstrap import VolumeBootstrapVerifier
    from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
    from larenor_server.plugins.worker import WorkerStep

    job = uuid.uuid4().hex
    with (
        ResourceJournal(daemon.root / "resource-journal") as resources,
        VolumeCreateJournal(daemon.root / "volume-journal") as volumes,
        ManagedWorkerJournal(
            daemon.root / "seerr-container-journal", initialize=True
        ) as containers,
    ):
        verifier = VolumeBootstrapVerifier(endpoint, helper_id, daemon.platform)
        readers = JellyfinEngineReaders(endpoint, verifier)
        broker = JellyfinResourceProofBroker(
            source.stack,
            source.catalog,
            source.policy,
            resources,
            volumes,
            readers,
            engine_identity=endpoint,
            service_id="seerr",
        )
        builder = JellyfinBindingBuilder(
            source.catalog,
            source.policy,
            containers.identity,
            broker,
            service_id="seerr",
        )
        binding = builder(source.stack)
        engine = smoke._managed_engine(endpoint)
        operations = JournaledManagedContainerOperations(containers, engine)

        def command(kind):
            return WorkerStep(
                job,
                binding.name.removeprefix("larenor-"),
                kind,
                uuid.uuid4().hex,
                time.time() + 60,
            )

        with diagnostic_phase("container_create"):
            created = operations.apply(command("create_container"), binding)
            require(created.state == "succeeded" and created.container_id is not None)
        with diagnostic_phase("container_start"):
            started = operations.apply(command("start_container"), binding)
            require(
                started.state == "succeeded"
                and started.code == "container_started"
                and started.container_id == created.container_id
            )
        deadline = time.monotonic() + 120
        with diagnostic_phase("fresh_state"):
            running = _fresh_public_state(
                engine, binding, source.stack, started.container_id, deadline=deadline
            )
            require(
                managed_container_matches(running, binding)
                and running.get("State", {}).get("Running") is True
            )
        host = binding.payload()["specification"]["HostConfig"]
        with diagnostic_phase("resource_verify"):
            daemon.verify_container_resources(
                running.get("State", {}).get("Pid"),
                host["Memory"],
                host["NanoCpus"],
                host["PidsLimit"],
            )
        with diagnostic_phase("container_restart"):
            daemon.docker(
                ["restart", "--time=10", started.container_id],
                timeout=30,
                limit=128,
            )
        with diagnostic_phase("restart_state"):
            restarted = _fresh_public_state(
                engine,
                binding,
                source.stack,
                started.container_id,
                deadline=time.monotonic() + 120,
            )
            require(
                managed_container_matches(restarted, binding)
                and restarted.get("State", {}).get("Running") is True
            )
            daemon.verify_container_resources(
                restarted.get("State", {}).get("Pid"),
                host["Memory"],
                host["NanoCpus"],
                host["PidsLimit"],
            )
    return _SeerrNativeResult("seerr_container_started", True, True)


def characterize(daemon, *, checkout_binding=None):
    checkout_binding = (
        smoke.capture_source(os.environ["GITHUB_SHA"])
        if checkout_binding is None
        else checkout_binding
    )
    smoke.check_source(checkout_binding)
    source = fixture_source(daemon.platform)
    with diagnostic_phase("resource_prepare"):
        endpoint, volume_states = _prepare_resources(daemon, source)
    with diagnostic_phase("helper_build"):
        helper_id, attestation = shared._build_helper(daemon, checkout_binding)
    with diagnostic_phase("volume_prepare"):
        shared._prepare_volumes(daemon, source, helper_id)
    result = _start_verify_restart(daemon, source, endpoint, helper_id)
    smoke.check_source(checkout_binding)
    component = next(
        item.manifest
        for item in source.catalog.entries
        if item.manifest.serviceId == "seerr"
    )
    return {
        "schemaVersion": 1,
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
        "restartCount": 1,
        "freshStatePersistent": result.persistent,
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
        signal.alarm(1200)
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
            print(error.args[0], file=sys.stderr)
        else:
            print("seerr_characterization_failed", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
