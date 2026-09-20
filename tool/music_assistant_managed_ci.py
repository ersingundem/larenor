#!/usr/bin/env python3
"""Opt-in native Music Assistant start, fresh-state and restart acceptance."""

from contextlib import contextmanager
from dataclasses import dataclass, replace
import hashlib
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
_ACCEPTANCE_SOURCE_FILES = (
    ".github/workflows/music-assistant-managed-characterization.yml",
    "tool/music_assistant_managed_ci.py",
    "tool/native_ci_scope.py",
    "tool/tests/music_assistant_managed_ci_test.py",
    "tool/tests/music_assistant_managed_workflow_test.py",
    "server/larenor_server/app.py",
    "server/larenor_server/core.py",
    "server/larenor_server/plugins/packagedcatalog.json",
    "server/larenor_server/plugins/managed_container.py",
    "server/larenor_server/plugins/installation_execution.py",
    "server/larenor_server/plugins/installation_ipc.py",
    "server/larenor_server/plugins/installation_runtime.py",
    "server/larenor_server/plugins/music_assistant_bootstrap_runtime.py",
    "server/larenor_server/plugins/music_assistant_bootstrap_jobs.py",
    "server/larenor_server/plugins/music_assistant_bootstrap_job_models.py",
    "server/larenor_server/plugins/music_assistant_bootstrap_job_schema.py",
    "server/larenor_server/plugins/music_assistant_core.py",
    "server/larenor_server/plugins/music_assistant_core_models.py",
    "server/larenor_server/plugins/music_assistant_core_schema.py",
    "server/tests/test_music_assistant_bootstrap_jobs.py",
    "server/tests/test_music_assistant_bootstrap_runtime.py",
    "server/tests/test_music_assistant_core_wiring.py",
)
_DIAGNOSTIC_PHASES = {
    "resource_prepare": "music_assistant_resource_prepare_failed",
    "helper_build": "music_assistant_helper_build_failed",
    "volume_prepare": "music_assistant_volume_prepare_failed",
    "runtime_setup": "music_assistant_runtime_setup_failed",
    "container_create": "music_assistant_container_create_failed",
    "container_start": "music_assistant_container_start_failed",
    "fresh_state": "music_assistant_fresh_state_failed",
    "resource_verify": "music_assistant_resource_verify_failed",
    "container_restart": "music_assistant_container_restart_failed",
    "restart_state": "music_assistant_restart_state_failed",
}
_CONTAINER_CREATE_DIAGNOSTICS = frozenset({
    *smoke._MANAGED_CREATE_DIAGNOSTICS,
    "managed_create_preflight_failed",
    "managed_create_uncertain",
    "managed_create_resource_conflict",
    "managed_create_expired",
    "managed_create_receipt_invalid",
})
_DIAGNOSTIC_CODES = frozenset(
    {
        "music_assistant_characterization_evidence_invalid",
        "music_assistant_characterization_cancelled",
        "music_assistant_characterization_failed",
        "music_assistant_container_exited",
        "music_assistant_container_capability_denied",
        "music_assistant_container_permission_denied",
        "music_assistant_container_port_conflict",
        "music_assistant_container_readonly_root",
        "music_assistant_container_runtime_broken",
        "music_assistant_container_storage_exhausted",
        "music_assistant_container_oom_killed",
        "music_assistant_info_unreachable",
        *_CONTAINER_CREATE_DIAGNOSTICS,
        *_DIAGNOSTIC_PHASES.values(),
    }
)


class MusicAssistantManagedCIError(Exception):
    """Closed native evidence failure; private Engine data never escapes."""


class _Cancelled(BaseException):
    pass


def require(value):
    if not value:
        raise MusicAssistantManagedCIError("music_assistant_characterization_evidence_invalid")


def acceptance_source_hashes():
    return {
        name: hashlib.sha256(smoke._source_bytes(smoke.REPOSITORY / name)).hexdigest()
        for name in _ACCEPTANCE_SOURCE_FILES
    }


def capture_acceptance_source(commit):
    smoke.verify_checkout(commit)
    git = [
        "/usr/bin/git", "-c", "safe.directory=" + str(smoke.REPOSITORY),
        "-C", str(smoke.REPOSITORY),
    ]
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
    smoke.bounded_command(
        git + ["ls-files", "--error-unmatch", "--", *_ACCEPTANCE_SOURCE_FILES],
        environment=environment, limit=4096)
    smoke.bounded_command(
        git + ["diff", "--exit-code", "HEAD", "--", *_ACCEPTANCE_SOURCE_FILES],
        environment=environment, limit=256)
    value = commit, acceptance_source_hashes()
    check_acceptance_source(value)
    return value


def check_acceptance_source(binding):
    commit, expected = binding
    smoke.verify_checkout(commit)
    require(acceptance_source_hashes() == expected)


@contextmanager
def diagnostic_phase(phase):
    code = _DIAGNOSTIC_PHASES.get(phase)
    if code is None:
        raise MusicAssistantManagedCIError("music_assistant_characterization_evidence_invalid")
    try:
        yield
    except MusicAssistantManagedCIError as error:
        if error.args == ("music_assistant_characterization_evidence_invalid",):
            raise MusicAssistantManagedCIError(code) from None
        raise
    except smoke.SmokeError:
        raise
    except Exception:
        raise MusicAssistantManagedCIError(code) from None


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
    """Select only the pinned MusicAssistant image and owned appdata volume."""
    base = smoke.fixture_source(selected_platform)
    image = next(
        item
        for item in base.plan.resources
        if item.kind == "ensure_image" and item.serviceId == "music_assistant"
    )
    targets = tuple(
        item
        for item in base.volumes.resources
        if item.serviceId == "music_assistant" and item.kind == "managed_appdata"
    )
    require(
        len(targets) == 1
        and targets[0].target == "/data"
        and targets[0].serviceId == "music_assistant"
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


def _require_container_created(receipt, engine):
    if (
        getattr(receipt, "state", None) == "succeeded"
        and getattr(receipt, "container_id", None) is not None
    ):
        return receipt
    diagnostic = smoke._managed_create_receipt_failure(
        receipt, getattr(engine, "managed_create_diagnostic", None)
    )
    if diagnostic not in _CONTAINER_CREATE_DIAGNOSTICS:
        diagnostic = "managed_create_receipt_invalid"
    raise MusicAssistantManagedCIError(diagnostic)


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
        if item.manifest.serviceId == "music_assistant"
    )
    hashes = smoke.source_hashes()
    acceptance_hashes = acceptance_source_hashes()
    helper = value["helper"]
    helper_digest = helper.get("configDigest")
    require(
        type(helper_digest) is str
        and re.fullmatch(r"sha256:[0-9a-f]{64}", helper_digest)
    )
    expected = {
        "schemaVersion": 1,
        "result": "music_assistant_characterized",
        "serviceVersion": component.version,
        "platform": selected,
        "sourceCommit": commit,
        "catalogDigest": source.catalog.digest,
        "acceptanceSourceHashes": acceptance_hashes,
        "musicAssistantManifestDigest": source.image.image.digest,
        "musicAssistantConfigDigest": source.image.image.configDigest,
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
        "containerState": "music_assistant_container_started",
        "freshStateVerified": True,
        "bootstrapAuthenticated": True,
        "restartCount": 1,
        "restartTokenPersistent": True,
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
class _MusicAssistantNativeResult:
    state: str
    fresh: bool
    authenticated: bool
    token_persistent: bool


_EXIT_SIGNATURES = (
    (b"read-only file system", "music_assistant_container_readonly_root"),
    (b"operation not permitted", "music_assistant_container_capability_denied"),
    (b"permission denied", "music_assistant_container_permission_denied"),
    (b"address already in use", "music_assistant_container_port_conflict"),
    (b"no space left on device", "music_assistant_container_storage_exhausted"),
    (b"modulenotfounderror", "music_assistant_container_runtime_broken"),
    (b"importerror", "music_assistant_container_runtime_broken"),
)


def _closed_exit_diagnostic(engine, container_id):
    try:
        response = engine._exchange(
            "GET",
            "/containers/" + container_id + "/logs?stdout=1&stderr=1&tail=200",
        )
        if response.status != 200 or len(response.body) > 65536:
            return "music_assistant_container_exited"
        lowered = response.body.lower()
        return next(
            code for signature, code in _EXIT_SIGNATURES if signature in lowered
        )
    except (StopIteration, Exception):
        return "music_assistant_container_exited"


def _require_running(engine, name, diagnose_exit=None):
    value = engine.inspect_container(name)
    state = value.get("State") if type(value) is dict else None
    if type(state) is not dict or state.get("Running") is not True:
        code = (
            "music_assistant_container_oom_killed"
            if type(state) is dict and state.get("OOMKilled") is True
            else diagnose_exit(value.get("Id"))
            if callable(diagnose_exit) and type(value.get("Id")) is str
            else "music_assistant_container_exited"
        )
        raise MusicAssistantManagedCIError(code)


def _public_info(*, deadline, engine, name, diagnose_exit=None):
    import http.client
    from larenor_server.plugins.music_assistant_bootstrap_runtime import (
        MusicAssistantBootstrapRuntime,
        MusicAssistantBootstrapRuntimeError,
    )

    while True:
        connection = None
        try:
            connection = http.client.HTTPConnection(
                "127.0.0.1", 8095, timeout=max(0.1, min(5.0, deadline - time.monotonic()))
            )
            connection.request("GET", "/info", headers={
                "Accept": "application/json", "Connection": "close"
            })
            response = connection.getresponse()
            raw = response.read(65537)
            require(response.status == 200 and len(raw) <= 65536)
            value = json.loads(
                raw.decode("utf-8"), object_pairs_hook=_unique,
                parse_constant=_nonfinite)
            MusicAssistantBootstrapRuntime._info(value, False)
            return value["server_id"]
        except MusicAssistantManagedCIError:
            raise
        except MusicAssistantBootstrapRuntimeError:
            raise MusicAssistantManagedCIError(
                "music_assistant_fresh_state_failed") from None
        except Exception:
            _require_running(engine, name, diagnose_exit)
            if time.monotonic() >= deadline:
                raise MusicAssistantManagedCIError(
                    "music_assistant_info_unreachable") from None
            time.sleep(0.25)
        finally:
            if connection is not None:
                try:
                    connection.close()
                except Exception:
                    pass


def _authenticated_restart_readback(runtime, installation_id, readback, *, deadline):
    import threading
    from larenor_server.plugins.music_assistant_bootstrap_runtime import (
        MusicAssistantBootstrapRuntimeError,
    )

    while True:
        try:
            cancelled = threading.Event()
            user = runtime._rpc(
                installation_id, "restart-user", readback.token, "auth/me", {},
                deadline, cancelled, lambda: True)
            info = runtime._rpc(
                installation_id, "restart-info", readback.token, "info", {},
                deadline, cancelled, lambda: True)
            require(
                type(user) is dict
                and user.get("username") == "larenor-core"
                and user.get("role") == "admin"
                and type(info) is dict
                and info.get("server_id") == readback.serverId
                and info.get("server_version") == readback.serverVersion
                and info.get("schema_version") == readback.schemaVersion
                and info.get("onboard_done") is True
            )
            return
        except MusicAssistantManagedCIError:
            raise
        except MusicAssistantBootstrapRuntimeError:
            if time.monotonic() >= deadline:
                raise MusicAssistantManagedCIError(
                    "music_assistant_restart_state_failed") from None
            time.sleep(0.25)


def _start_verify_restart(daemon, source, endpoint, helper_id):
    from larenor_server.plugins.managed_container import (
        JellyfinBindingBuilder,
        JellyfinEngineReaders,
        JellyfinResourceProofBroker,
        JournaledManagedContainerOperations,
        ManagedWorkerJournal,
        managed_container_matches,
    )
    from larenor_server.plugins.music_assistant_bootstrap_runtime import (
        MusicAssistantBootstrapRuntime,
    )
    from larenor_server.plugins.resource_journal import ResourceJournal
    from larenor_server.plugins.volume_bootstrap import VolumeBootstrapVerifier
    from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
    from larenor_server.plugins.worker import WorkerStep

    job = uuid.uuid4().hex
    installation_id = next(
        item.installationId for item in source.stack.components
        if item.serviceId == "music_assistant")
    with (
        ResourceJournal(daemon.root / "resource-journal") as resources,
        VolumeCreateJournal(daemon.root / "volume-journal") as volumes,
        ManagedWorkerJournal(
            daemon.root / "music-assistant-container-journal", initialize=True
        ) as containers,
    ):
        verifier = VolumeBootstrapVerifier(endpoint, helper_id, daemon.platform)
        readers = JellyfinEngineReaders(endpoint, verifier)
        broker = JellyfinResourceProofBroker(
            source.stack, source.catalog, source.policy, resources, volumes, readers,
            engine_identity=endpoint, service_id="music_assistant")
        builder = JellyfinBindingBuilder(
            source.catalog, source.policy, containers.identity, broker,
            service_id="music_assistant")
        binding = builder(source.stack)
        engine = smoke._managed_engine(endpoint)
        operations = JournaledManagedContainerOperations(containers, engine)

        def command(kind):
            return WorkerStep(
                job, binding.name.removeprefix("larenor-"), kind,
                uuid.uuid4().hex, time.time() + 60)

        with diagnostic_phase("container_create"):
            created = operations.apply(command("create_container"), binding)
            _require_container_created(created, engine)
        with diagnostic_phase("container_start"):
            started = operations.apply(command("start_container"), binding)
            require(
                started.state == "succeeded"
                and started.code == "container_started"
                and started.container_id == created.container_id)
        with diagnostic_phase("fresh_state"):
            server_id = _public_info(
                deadline=time.monotonic() + 120,
                engine=engine,
                name=binding.name,
                diagnose_exit=lambda container_id: _closed_exit_diagnostic(
                    engine, container_id),
            )
            running = engine.inspect_container(binding.name)
            require(
                managed_container_matches(running, binding)
                and running.get("State", {}).get("Running") is True)
            runtime = MusicAssistantBootstrapRuntime()
            readback = runtime.create(
                installation_id=installation_id, username="larenor-core",
                credential=secrets.token_urlsafe(48),
                deadline=time.monotonic() + 60, gate=lambda: True)
            require(readback.serverId == server_id)
        host = binding.payload()["specification"]["HostConfig"]
        with diagnostic_phase("resource_verify"):
            require(
                host["NetworkMode"] == "host"
                and host["Privileged"] is False
                and host["CapDrop"] == ["ALL"]
                and host["CapAdd"] == ["NET_BIND_SERVICE"]
                and host["ReadonlyRootfs"] is True)
            daemon.verify_container_resources(
                running.get("State", {}).get("Pid"), host["Memory"],
                host["NanoCpus"], host["PidsLimit"])
        with diagnostic_phase("container_restart"):
            daemon.docker(
                ["restart", "--time=10", started.container_id],
                timeout=30, limit=128)
        with diagnostic_phase("restart_state"):
            _authenticated_restart_readback(
                runtime, installation_id, readback, deadline=time.monotonic() + 120)
            restarted = engine.inspect_container(binding.name)
            require(
                managed_container_matches(restarted, binding)
                and restarted.get("State", {}).get("Running") is True)
            daemon.verify_container_resources(
                restarted.get("State", {}).get("Pid"), host["Memory"],
                host["NanoCpus"], host["PidsLimit"])
    return _MusicAssistantNativeResult(
        "music_assistant_container_started", True, True, True)

def characterize(daemon, *, checkout_binding=None, acceptance_binding=None):
    checkout_binding = (
        smoke.capture_source(os.environ["GITHUB_SHA"])
        if checkout_binding is None
        else checkout_binding
    )
    smoke.check_source(checkout_binding)
    acceptance_binding = (
        capture_acceptance_source(checkout_binding[0])
        if acceptance_binding is None else acceptance_binding)
    check_acceptance_source(acceptance_binding)
    source = fixture_source(daemon.platform)
    with diagnostic_phase("resource_prepare"):
        endpoint, volume_states = _prepare_resources(daemon, source)
    with diagnostic_phase("helper_build"):
        helper_id, attestation = shared._build_helper(daemon, checkout_binding)
    with diagnostic_phase("volume_prepare"):
        shared._prepare_volumes(daemon, source, helper_id)
    result = _start_verify_restart(daemon, source, endpoint, helper_id)
    smoke.check_source(checkout_binding)
    check_acceptance_source(acceptance_binding)
    component = next(
        item.manifest
        for item in source.catalog.entries
        if item.manifest.serviceId == "music_assistant"
    )
    return {
        "schemaVersion": 1,
        "result": "music_assistant_characterized",
        "serviceVersion": component.version,
        "platform": daemon.platform,
        "sourceCommit": checkout_binding[0],
        "catalogDigest": source.catalog.digest,
        "acceptanceSourceHashes": dict(acceptance_binding[1]),
        "musicAssistantManifestDigest": source.image.image.digest,
        "musicAssistantConfigDigest": source.image.image.configDigest,
        "helper": attestation,
        "imageState": "ready",
        "networkState": "ready",
        "volumeStates": volume_states,
        "volumeCount": 1,
        "containerMode": "journaled_managed_v2",
        "containerJournalVersion": 2,
        "containerState": result.state,
        "freshStateVerified": result.fresh,
        "bootstrapAuthenticated": result.authenticated,
        "restartCount": 1,
        "restartTokenPersistent": result.token_persistent,
        "installAvailable": False,
    }


def run():
    selected = validate_launch(
        os.environ, platform.system(), platform.machine(), os.geteuid()
    )
    commit = os.environ["GITHUB_SHA"]
    acceptance_binding = capture_acceptance_source(commit)
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
            value = characterize(
                daemon, checkout_binding=binding,
                acceptance_binding=acceptance_binding)
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
    raise MusicAssistantManagedCIError("music_assistant_characterization_evidence_invalid")


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
        print("music_assistant_characterization_receipt_verified")
    except MusicAssistantManagedCIError:
        raise
    except Exception:
        raise MusicAssistantManagedCIError("music_assistant_characterization_evidence_invalid") from None


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    try:
        if args == ["--run-ephemeral-ci"]:
            run()
        elif len(args) == 2 and args[0] == "--verify-receipt":
            verify(args[1])
        else:
            raise MusicAssistantManagedCIError("music_assistant_characterization_evidence_invalid")
        return 0
    except _Cancelled:
        print("music_assistant_characterization_cancelled", file=sys.stderr)
    except Exception as error:
        if type(error) is smoke.SmokeError:
            print(smoke.failure_diagnostic(error), file=sys.stderr)
        elif (
            type(error) is MusicAssistantManagedCIError
            and error.args
            and error.args[0] in _DIAGNOSTIC_CODES
        ):
            print(error.args[0], file=sys.stderr)
        else:
            print("music_assistant_characterization_failed", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
