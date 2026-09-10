#!/usr/bin/env python3
"""Opt-in native Sonarr/Radarr config, start, readback and restart acceptance."""

from contextlib import contextmanager
from dataclasses import replace
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
_SERVICES = frozenset({"sonarr", "radarr"})
_DIAGNOSTIC_PHASES = {
    "resource_prepare": "arr_resource_prepare_failed",
    "helper_build": "arr_helper_build_failed",
    "volume_prepare": "arr_volume_prepare_failed",
    "runtime_setup": "arr_runtime_setup_failed",
    "runtime_install": "arr_runtime_install_failed",
    "configuration_receipt": "arr_configuration_receipt_failed",
    "container_receipt": "arr_container_receipt_failed",
    "service_receipt": "arr_service_receipt_failed",
    "container_inspect": "arr_container_inspect_failed",
    "resource_verify": "arr_resource_verify_failed",
    "container_restart": "arr_container_restart_failed",
    "bootstrap_reverify": "arr_bootstrap_reverify_failed",
    "post_restart_inspect": "arr_post_restart_inspect_failed",
}
_PRODUCTION_CODES = frozenset(
    {
        "invalid_execution_request",
        "invalid_worker_result",
        "arr_config_authority_changed",
        "arr_config_resources_unavailable",
        "arr_config_write_failed",
        "arr_config_result_invalid",
        "arr_config_timeout",
        "arr_configure_stage_failed",
        "arr_execution_stage_failed",
        "arr_bootstrap_stage_failed",
        "arr_receipt_stage_failed",
        "arr_execution_authority_changed",
        "arr_execution_cancelled",
        "arr_execution_worker_unavailable",
        "arr_execution_invalid_worker_result",
        "arr_execution_resource_conflict",
        "arr_execution_container_not_running",
        "arr_execution_dispatch_expired",
        "arr_config_runtime_untrusted",
        "arr_config_runtime_configuration_invalid",
        "arr_config_runtime_effect_failed",
        "arr_config_runtime_result_invalid",
        "arr_config_effect_untrusted",
        "arr_config_effect_configuration_invalid",
        "arr_config_effect_dispatch_denied",
        "arr_config_effect_cancelled",
        "arr_config_effect_create_failed",
        "arr_config_effect_start_failed",
        "arr_config_effect_stream_failed",
        "arr_config_effect_result_failed",
        "arr_config_effect_wait_failed",
        "arr_config_effect_cleanup_failed",
        "arr_config_effect_authority_changed",
        "invalid_arr_bootstrap_execution",
        "arr_bootstrap_authority_changed",
        "arr_bootstrap_resources_unavailable",
        "arr_bootstrap_endpoint_unavailable",
        "arr_bootstrap_endpoint_changed",
        "arr_bootstrap_readback_failed",
        "arr_bootstrap_timeout",
        "arr_bootstrap_authority_changed",
        "arr_bootstrap_before_connect_failed",
        "arr_bootstrap_after_connect_failed",
        "arr_bootstrap_after_readback_failed",
        "invalid_arr_authenticated_readback",
        "arr_authentication_failed",
        "arr_readback_protocol",
        "arr_readback_mismatch",
        "arr_authenticated_readback_unavailable",
        "arr_authenticated_readback_timeout",
    }
)
_DIAGNOSTIC_CODES = frozenset(
    {
        "arr_characterization_evidence_invalid",
        "arr_characterization_cancelled",
        "arr_characterization_failed",
        *_DIAGNOSTIC_PHASES.values(),
        *_PRODUCTION_CODES,
    }
)


class ArrManagedCIError(Exception):
    """Static native evidence failure; private Engine data never escapes."""


class _Cancelled(BaseException):
    pass


def require(value):
    if not value:
        raise ArrManagedCIError("arr_characterization_evidence_invalid")


def _production_diagnostic(error):
    from larenor_server.plugins.arr_bootstrap_executor import (
        ArrBootstrapExecutionError,
    )
    from larenor_server.plugins.arr_config_effect import ArrConfigEffectError
    from larenor_server.plugins.arr_config_models import (
        ArrConfigurationExecutionError,
    )
    from larenor_server.plugins.arr_config_runtime import ArrConfigRuntimeError
    from larenor_server.plugins.installation_execution import (
        InstallationExecutionError,
    )

    trusted = {
        ArrBootstrapExecutionError,
        ArrConfigEffectError,
        ArrConfigurationExecutionError,
        ArrConfigRuntimeError,
        InstallationExecutionError,
    }
    cause = getattr(error, "cause_code", None)
    if type(error) is ArrConfigurationExecutionError and cause in _PRODUCTION_CODES:
        return cause
    code = getattr(error, "code", None)
    return code if type(error) in trusted and code in _PRODUCTION_CODES else None


@contextmanager
def diagnostic_phase(phase):
    code = _DIAGNOSTIC_PHASES.get(phase)
    if code is None:
        raise ArrManagedCIError("arr_characterization_evidence_invalid")
    try:
        yield
    except ArrManagedCIError as error:
        if error.args == ("arr_characterization_evidence_invalid",):
            raise ArrManagedCIError(code) from None
        raise
    except smoke.SmokeError:
        raise
    except Exception as error:
        production = _production_diagnostic(error)
        raise ArrManagedCIError(production or code) from None


def validate_launch(environment, system, machine, uid):
    selected = smoke.native_platform(environment, system, machine, uid)
    service = environment.get("EXPECTED_SERVICE")
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
        and service in _SERVICES
    )
    return selected, service


def fixture_source(selected_platform, service):
    """Select one Arr image, its appdata and the shared library intent."""
    require(service in _SERVICES)
    base = smoke.fixture_source(selected_platform)
    image = next(
        item
        for item in base.plan.resources
        if item.kind == "ensure_image" and item.serviceId == service
    )
    targets = tuple(
        item
        for item in base.volumes.resources
        if (item.serviceId == service and item.kind == "managed_appdata")
        or item.kind == "managed_library"
    )
    require(
        len(targets) == 2
        and {item.kind for item in targets} == {"managed_appdata", "managed_library"}
        and {item.target for item in targets} == {"/config", "/media"}
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
        return len(left) == len(right) and all(_same(a, b) for a, b in zip(left, right))
    return left == right


def validate_receipt(value, commit, selected, service):
    require(
        type(commit) is str
        and re.fullmatch(r"[0-9a-f]{40}", commit)
        and selected in {"linux/amd64", "linux/arm64"}
        and service in _SERVICES
        and type(value) is dict
        and type(value.get("helper")) is dict
    )
    source = fixture_source(selected, service)
    component = next(
        item.manifest
        for item in source.catalog.entries
        if item.manifest.serviceId == service
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
        "result": "arr_characterized",
        "serviceId": service,
        "serviceVersion": component.version,
        "platform": selected,
        "sourceCommit": commit,
        "catalogDigest": source.catalog.digest,
        "arrManifestDigest": source.image.image.digest,
        "arrConfigDigest": source.image.image.configDigest,
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
        "volumeStates": ["observed_requires_bootstrap"] * 2,
        "volumeCount": 2,
        "containerMode": "journaled_managed_v2",
        "containerJournalVersion": 2,
        "configurationState": service + "_config_installed",
        "containerState": service + "_container_started",
        "serviceState": service + "_service_verified",
        "apiKeyVerified": True,
        "restartCount": 1,
        "installAvailable": False,
    }
    require(_same(value, expected))


def _install_and_restart(daemon, source, endpoint, helper_id, service):
    from larenor_server.plugins.arr_config_models import PrivateArrConfiguration
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

    private = PrivateArrConfiguration(serviceId=service, apiKey=secrets.token_hex(16))
    job = uuid.uuid4().hex
    with (
        ResourceJournal(daemon.root / "resource-journal") as resources,
        VolumeCreateJournal(daemon.root / "volume-journal") as volumes,
        ManagedWorkerJournal(
            daemon.root / (service + "-container-journal"), initialize=True
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
            service_id=service,
        )
        builder = JellyfinBindingBuilder(
            source.catalog,
            source.policy,
            containers.identity,
            broker,
            service_id=service,
        )

        def binding(stack, service_id=service):
            require(service_id == service)
            return builder(stack)

        with diagnostic_phase("runtime_setup"):
            engine = smoke._managed_engine(endpoint)
            operations = JournaledManagedContainerOperations(containers, engine)
            backend = shared._runtime_backend(
                operations,
                binding,
                endpoint,
                volumes,
                source.catalog,
                source.policy,
                helper_id,
                daemon.platform,
            )
        with diagnostic_phase("runtime_install"):
            receipt = backend.install_configured_arr(
                job,
                source.stack,
                service,
                api_key=private.apiKey,
                cancelled=threading.Event(),
                deadline=time.monotonic() + 120,
                gate=lambda: True,
            )
        with diagnostic_phase("configuration_receipt"):
            require(receipt.configuration.state == service + "_config_installed")
        with diagnostic_phase("container_receipt"):
            require(receipt.state == service + "_container_started")
        with diagnostic_phase("service_receipt"):
            require(receipt.service_state == service + "_service_verified")
        with diagnostic_phase("container_inspect"):
            binding_value = binding(source.stack)
            running = engine.inspect_container(receipt.container_id)
            require(
                managed_container_matches(running, binding_value)
                and running.get("State", {}).get("Running") is True
            )
            host = binding_value.payload()["specification"]["HostConfig"]
        with diagnostic_phase("resource_verify"):
            daemon.verify_container_resources(
                running.get("State", {}).get("Pid"),
                host["Memory"],
                host["NanoCpus"],
                host["PidsLimit"],
            )
        with diagnostic_phase("container_restart"):
            daemon.docker(
                ["restart", "--time=10", receipt.container_id], timeout=30, limit=128
            )
        with diagnostic_phase("bootstrap_reverify"):
            restarted = backend.arr_bootstrap.execute(
                job,
                source.stack,
                private,
                deadline=time.monotonic() + 120,
                gate=lambda: True,
            )
            require(
                restarted.state == "verified"
                and restarted.service_id == service
                and restarted.readback.service_id == service
            )
        with diagnostic_phase("post_restart_inspect"):
            running = engine.inspect_container(receipt.container_id)
            require(
                managed_container_matches(running, binding_value)
                and running.get("State", {}).get("Running") is True
            )
            daemon.verify_container_resources(
                running.get("State", {}).get("Pid"),
                host["Memory"],
                host["NanoCpus"],
                host["PidsLimit"],
            )
        return receipt, restarted


def characterize(daemon, service, *, checkout_binding=None):
    """Exercise one exact production Arr path on an owned daemon."""
    checkout_binding = (
        smoke.capture_source(os.environ["GITHUB_SHA"])
        if checkout_binding is None
        else checkout_binding
    )
    smoke.check_source(checkout_binding)
    source = fixture_source(daemon.platform, service)
    with diagnostic_phase("resource_prepare"):
        endpoint, volume_states = shared._prepare_resources(daemon, source)
    with diagnostic_phase("helper_build"):
        helper_id, attestation = shared._build_helper(daemon, checkout_binding)
    with diagnostic_phase("volume_prepare"):
        shared._prepare_volumes(daemon, source, helper_id)
    receipt, restarted = _install_and_restart(
        daemon, source, endpoint, helper_id, service
    )
    smoke.check_source(checkout_binding)
    return {
        "schemaVersion": 1,
        "result": "arr_characterized",
        "serviceId": service,
        "serviceVersion": restarted.readback.version,
        "platform": daemon.platform,
        "sourceCommit": checkout_binding[0],
        "catalogDigest": source.catalog.digest,
        "arrManifestDigest": source.image.image.digest,
        "arrConfigDigest": source.image.image.configDigest,
        "helper": attestation,
        "imageState": "ready",
        "networkState": "ready",
        "volumeStates": volume_states,
        "volumeCount": 2,
        "containerMode": "journaled_managed_v2",
        "containerJournalVersion": 2,
        "configurationState": receipt.configuration.state,
        "containerState": receipt.state,
        "serviceState": receipt.service_state,
        "apiKeyVerified": True,
        "restartCount": 1,
        "installAvailable": False,
    }


def run():
    selected, service = validate_launch(
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
            value = characterize(daemon, service, checkout_binding=binding)
        with smoke.diagnostic_phase("source_recheck"):
            smoke.check_source(binding)
        validate_receipt(value, commit, selected, service)
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
    raise ArrManagedCIError("arr_characterization_evidence_invalid")


def verify(path):
    try:
        with Path(path).open("rb") as source:
            raw = source.read(32769)
        require(0 < len(raw) <= 32768)
        value = json.loads(raw, object_pairs_hook=_unique, parse_constant=_nonfinite)
        commit = os.environ.get("GITHUB_SHA", "")
        selected = os.environ.get("EXPECTED_PLATFORM", "")
        service = os.environ.get("EXPECTED_SERVICE", "")
        smoke.verify_checkout(commit)
        validate_receipt(value, commit, selected, service)
        print("arr_characterization_receipt_verified")
    except ArrManagedCIError:
        raise
    except Exception:
        raise ArrManagedCIError("arr_characterization_evidence_invalid") from None


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    try:
        if args == ["--run-ephemeral-ci"]:
            run()
        elif len(args) == 2 and args[0] == "--verify-receipt":
            verify(args[1])
        else:
            raise ArrManagedCIError("arr_characterization_evidence_invalid")
        return 0
    except _Cancelled:
        print("arr_characterization_cancelled", file=sys.stderr)
    except Exception as error:
        if type(error) is smoke.SmokeError:
            print(smoke.failure_diagnostic(error), file=sys.stderr)
        elif (
            type(error) is ArrManagedCIError
            and error.args
            and error.args[0] in _DIAGNOSTIC_CODES
        ):
            print(error.args[0], file=sys.stderr)
        else:
            print("arr_characterization_failed", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
