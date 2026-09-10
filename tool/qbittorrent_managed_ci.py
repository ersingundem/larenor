#!/usr/bin/env python3
"""Opt-in native qBittorrent config, start, readback and restart acceptance."""

from dataclasses import replace
from contextlib import contextmanager
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

from tool import jellyfin_storage_smoke as smoke


_DIAGNOSTIC_PHASES = {
    'resource_prepare': 'qbittorrent_resource_prepare_failed',
    'runtime_setup': 'qbittorrent_runtime_setup_failed',
    'runtime_install': 'qbittorrent_runtime_install_failed',
    'configuration_receipt': 'qbittorrent_configuration_receipt_failed',
    'container_receipt': 'qbittorrent_container_receipt_failed',
    'service_receipt': 'qbittorrent_service_receipt_failed',
    'container_inspect': 'qbittorrent_container_inspect_failed',
    'resource_verify': 'qbittorrent_resource_verify_failed',
    'container_restart': 'qbittorrent_container_restart_failed',
    'bootstrap_reverify': 'qbittorrent_bootstrap_reverify_failed',
    'post_restart_inspect': 'qbittorrent_post_restart_inspect_failed',
}
_PRODUCTION_DIAGNOSTIC_CODES = frozenset({
    'invalid_execution_request',
    'invalid_worker_result',
    'qbittorrent_config_authority_changed',
    'qbittorrent_config_resources_unavailable',
    'qbittorrent_config_write_failed',
    'qbittorrent_config_result_invalid',
    'qbittorrent_config_timeout',
    'qbittorrent_service_unavailable',
    'qbittorrent_service_changed',
    'qbittorrent_service_verification_failed',
    'qbittorrent_config_runtime_untrusted',
    'qbittorrent_config_runtime_configuration_invalid',
    'qbittorrent_config_runtime_effect_failed',
    'qbittorrent_config_runtime_result_invalid',
    'qbittorrent_config_effect_untrusted',
    'qbittorrent_config_effect_configuration_invalid',
    'qbittorrent_config_effect_dispatch_denied',
    'qbittorrent_config_effect_cancelled',
    'qbittorrent_config_effect_create_failed',
    'qbittorrent_config_effect_start_failed',
    'qbittorrent_config_effect_stream_failed',
    'qbittorrent_config_effect_result_failed',
    'qbittorrent_config_effect_wait_failed',
    'qbittorrent_config_effect_cleanup_failed',
    'qbittorrent_config_effect_authority_changed',
    'invalid_qbittorrent_bootstrap_execution',
    'qbittorrent_bootstrap_authority_changed',
    'qbittorrent_bootstrap_resources_unavailable',
    'qbittorrent_bootstrap_endpoint_unavailable',
    'qbittorrent_bootstrap_endpoint_changed',
    'qbittorrent_bootstrap_categories_failed',
    'qbittorrent_bootstrap_readback_failed',
    'qbittorrent_bootstrap_timeout',
})
_ENGINE_DIAGNOSTIC_CODES = frozenset({
    'engine_stdin_invalid', 'engine_stdin_invalid_limits',
    'engine_stdin_protocol', 'engine_stdin_response_limit',
    'engine_stdin_unavailable', 'engine_stdin_timeout',
    'engine_stdin_cancelled', 'engine_stdin_api_unsupported',
    'engine_stdin_dispatch_denied',
    'engine_stdin_version_protocol',
    'engine_stdin_attach_protocol',
    'engine_stdin_frames_protocol',
})
_RUNTIME_CAUSE_CODES = frozenset({
    'qbittorrent_configure_stage_failed',
    'qbittorrent_execution_stage_failed',
    'qbittorrent_bootstrap_stage_failed',
    'qbittorrent_receipt_stage_failed',
    'qbittorrent_execution_worker_unavailable',
    'qbittorrent_execution_invalid_worker_result',
    'qbittorrent_execution_resource_conflict',
    'qbittorrent_execution_container_not_running',
    'qbittorrent_execution_dispatch_expired',
    'qbittorrent_bootstrap_binding_invalid_installation_plan',
    'qbittorrent_bootstrap_binding_resources_unavailable',
    'qbittorrent_bootstrap_binding_resources_untrusted',
    'qbittorrent_bootstrap_before_connect_failed',
    'qbittorrent_bootstrap_after_categories_connect_failed',
    'qbittorrent_bootstrap_after_categories_failed',
    'qbittorrent_bootstrap_after_readback_connect_failed',
    'qbittorrent_bootstrap_after_readback_failed',
})
_DIAGNOSTIC_CODES = frozenset({
    'qbittorrent_characterization_evidence_invalid',
    *_DIAGNOSTIC_PHASES.values(),
    *_PRODUCTION_DIAGNOSTIC_CODES,
    *_ENGINE_DIAGNOSTIC_CODES,
    *_RUNTIME_CAUSE_CODES,
})


class QbittorrentManagedCIError(Exception):
    """Static native evidence failure; private Engine data never escapes."""


def _production_diagnostic(error):
    from larenor_server.plugins.installation_execution import (
        InstallationExecutionError,
    )
    from larenor_server.plugins.qbittorrent_bootstrap_executor import (
        QbittorrentBootstrapExecutionError,
    )
    from larenor_server.plugins.qbittorrent_config_effect import (
        QbittorrentConfigEffectError,
    )
    from larenor_server.plugins.qbittorrent_config_models import (
        QbittorrentConfigurationExecutionError,
    )
    from larenor_server.plugins.qbittorrent_config_runtime import (
        QbittorrentConfigRuntimeError,
    )

    trusted = {
        InstallationExecutionError,
        QbittorrentBootstrapExecutionError,
        QbittorrentConfigEffectError,
        QbittorrentConfigurationExecutionError,
        QbittorrentConfigRuntimeError,
    }
    cause = getattr(error, 'cause_code', None)
    if type(error) in trusted and cause in _RUNTIME_CAUSE_CODES:
        return cause
    if type(error) in trusted and cause in _ENGINE_DIAGNOSTIC_CODES:
        return cause
    code = getattr(error, 'code', None)
    return code if type(error) in trusted and code in _PRODUCTION_DIAGNOSTIC_CODES else None


@contextmanager
def diagnostic_phase(phase):
    """Replace private runtime failures with an allowlisted stage code."""
    code = _DIAGNOSTIC_PHASES.get(phase)
    if code is None:
        raise QbittorrentManagedCIError(
            'qbittorrent_characterization_evidence_invalid')
    try:
        yield
    except QbittorrentManagedCIError as error:
        if error.args == ('qbittorrent_characterization_evidence_invalid',):
            raise QbittorrentManagedCIError(code) from None
        raise
    except smoke.SmokeError:
        raise
    except Exception as error:
        production_code = _production_diagnostic(error)
        if production_code is not None:
            raise QbittorrentManagedCIError(production_code) from None
        raise QbittorrentManagedCIError(code) from None


class _Cancelled(BaseException):
    pass


def require(value):
    if not value:
        raise QbittorrentManagedCIError(
            'qbittorrent_characterization_evidence_invalid')


def validate_launch(environment, system, machine, uid):
    selected = smoke.native_platform(environment, system, machine, uid)
    event = environment.get('GITHUB_EVENT_NAME')
    repository = environment.get('GITHUB_REPOSITORY')
    manual = (
        event == 'workflow_dispatch'
        and environment.get('GITHUB_REF') == 'refs/heads/main'
        and environment.get('GITHUB_BASE_REF') == ''
        and environment.get('PR_HEAD_REPOSITORY') == '')
    pull_request = (
        event == 'pull_request'
        and re.fullmatch(
            r'refs/pull/[1-9][0-9]*/merge',
            environment.get('GITHUB_REF', ''))
        and environment.get('GITHUB_BASE_REF') == 'main'
        and environment.get('PR_HEAD_REPOSITORY') == repository)
    require(
        (manual or pull_request)
        and repository == 'ersingundem/larenor'
        and environment.get('GITHUB_WORKFLOW_SHA')
        == environment.get('GITHUB_SHA')
        and environment.get('EXPECTED_PLATFORM') == selected)
    return selected


def fixture_source(selected_platform):
    """Select only the qBittorrent image and its two owned volume intents."""
    base = smoke.fixture_source(selected_platform)
    image = next(
        item for item in base.plan.resources
        if item.kind == 'ensure_image' and item.serviceId == 'qbittorrent')
    targets = tuple(
        item for item in base.volumes.resources
        if (item.serviceId == 'qbittorrent'
            and item.kind == 'managed_appdata')
        or item.kind == 'managed_library')
    require(
        len(targets) == 2
        and {item.kind for item in targets}
        == {'managed_appdata', 'managed_library'}
        and {item.target for item in targets} == {'/config', '/media'})
    return replace(
        base, image=image, targets=targets, managed_targets=targets)


def _same(left, right):
    if type(left) is not type(right):
        return False
    if type(right) is dict:
        return (left.keys() == right.keys()
                and all(_same(left[key], value)
                        for key, value in right.items()))
    if type(right) is list:
        return (len(left) == len(right)
                and all(_same(a, b) for a, b in zip(left, right)))
    return left == right


def validate_receipt(value, commit, selected):
    require(
        type(commit) is str and re.fullmatch(r'[0-9a-f]{40}', commit)
        and selected in {'linux/amd64', 'linux/arm64'}
        and type(value) is dict and type(value.get('helper')) is dict)
    source = fixture_source(selected)
    hashes = smoke.source_hashes()
    helper = value['helper']
    helper_digest = helper.get('configDigest')
    require(
        type(helper_digest) is str
        and re.fullmatch(r'sha256:[0-9a-f]{64}', helper_digest))
    expected = {
        'schemaVersion': 1,
        'result': 'qbittorrent_characterized',
        'platform': selected,
        'sourceCommit': commit,
        'catalogDigest': source.catalog.digest,
        'qbittorrentManifestDigest': source.image.image.digest,
        'qbittorrentConfigDigest': source.image.image.configDigest,
        'helper': {
            'configDigest': helper_digest,
            'platform': selected,
            'sourceCommit': commit,
            'publishedManifestDigest': None,
            'helperSourceSha256': hashes['tool/volume_bootstrap_helper.py'],
            'probeSourceSha256': hashes['tool/jellyfin_storage_probe.py'],
            'dockerfileSha256': hashes['server/Dockerfile.volume-bootstrap'],
            'sourceHashes': hashes,
        },
        'imageState': 'ready',
        'networkState': 'ready',
        'volumeStates': ['observed_requires_bootstrap'] * 2,
        'volumeCount': 2,
        'containerMode': 'journaled_managed_v2',
        'containerJournalVersion': 2,
        'configurationState': 'qbittorrent_config_installed',
        'containerState': 'qbittorrent_container_started',
        'serviceState': 'qbittorrent_service_verified',
        'categoryCount': 2,
        'categoriesPersistent': True,
        'apiKeyVerified': True,
        'restartCount': 1,
        'installAvailable': False,
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

    endpoint = DockerEndpoint(str(daemon.root / 'engine.sock'), owner_uid=0)
    images = UnixImageEngine(endpoint)
    characterize_resources(
        daemon.root, source, images, UnixNetworkEngine(endpoint),
        UnixNetworkCreator(endpoint))
    arguments = dict(
        plan=source.plan, stack=source.stack,
        catalog=source.catalog, policy=source.policy)
    cancelled = threading.Event()
    with ResourceJournal(daemon.root / 'resource-journal') as journal:
        image = JournaledImageOperations(journal, images).apply(
            **arguments, resource_id=source.image.resourceId,
            authorize_pull=lambda: True, cancelled=cancelled)
    volume_states = []
    creator = UnixVolumeCreator(endpoint)
    with VolumeCreateJournal(
            daemon.root / 'volume-journal', initialize=True) as journal:
        for target in source.targets:
            receipt = JournaledVolumeCreates(journal, creator).apply(
                source.volumes, source.stack, source.catalog, source.policy,
                target.resourceId, authorize_create=lambda: True,
                cancelled=cancelled)
            volume_states.append(receipt.state)
    require(
        image.state == 'ready'
        and volume_states == ['observed_requires_bootstrap'] * 2)
    return endpoint, volume_states


def _build_helper(daemon, checkout_binding):
    with smoke.diagnostic_phase('helper_stage'):
        context = smoke.stage_context(daemon.root, checkout_binding)
    commit, hashes = checkout_binding
    labels = smoke.source_labels(commit, dict(hashes))
    smoke._helper_base(daemon, context, checkout_binding)
    iid_file = daemon.root / 'helper.iid'
    with smoke.diagnostic_phase('helper_build'):
        daemon.docker([
            'build', '--pull', '--quiet', '--network=none',
            *['--label=' + key + '=' + value
              for key, value in labels.items()],
            '--file', str(context / 'server/Dockerfile.volume-bootstrap'),
            '--iidfile', str(iid_file), str(context),
        ], timeout=600, limit=256, diagnose_failure=True)
    with smoke.diagnostic_phase('helper_inspect'):
        smoke.check_source(checkout_binding)
        smoke.check_staged(context, checkout_binding)
        helper_id = iid_file.read_text().strip()
        smoke.require(smoke._HASH.fullmatch(helper_id) is not None)
        inspected = smoke._decoded(daemon.docker([
            'image', 'inspect', '--format', '{{json .}}', helper_id,
        ], limit=65536))
        attestation = smoke.helper_attestation(
            helper_id, inspected, daemon.platform, commit,
            expected_hashes=hashes)
    with smoke.diagnostic_phase('helper_seed'):
        smoke.require(
            smoke._helper(daemon, helper_id, 'image_seed')
            == {'imageSeed': True})
    return helper_id, attestation


def _prepare_volumes(daemon, source, helper_id):
    for target in source.targets:
        with smoke.diagnostic_phase('initial_permissions'):
            smoke.require(
                smoke._helper(
                    daemon, helper_id, 'writable', target=target)
                == {'writable': False, 'uid': 1000, 'gid': 1000})
        with smoke.diagnostic_phase('bootstrap_check'):
            smoke.require(
                smoke._helper(
                    daemon, helper_id, 'check', target=target,
                    bootstrap=True)
                == {'schemaVersion': 1, 'state': 'empty_uninitialized'})
        with smoke.diagnostic_phase('bootstrap_initialize'):
            smoke.require(
                smoke._helper(
                    daemon, helper_id, 'initialize_empty_root',
                    target=target, bootstrap=True)
                == {'schemaVersion': 1, 'state': 'empty_initialized'})
        with smoke.diagnostic_phase('initialized_permissions'):
            smoke.require(
                smoke._helper(
                    daemon, helper_id, 'writable', target=target)
                == {'writable': True, 'uid': 1000, 'gid': 1000})


def _install_and_restart(daemon, source, endpoint, helper_id):
    from larenor_server.plugins.installation_runtime import _RuntimeBackend
    from larenor_server.plugins.managed_container import (
        JellyfinBindingBuilder, JellyfinEngineReaders,
        JellyfinResourceProofBroker, JournaledManagedContainerOperations,
        ManagedWorkerJournal, managed_container_matches,
    )
    from larenor_server.plugins.qbittorrent_config_models import (
        PrivateQbittorrentConfiguration,
    )
    from larenor_server.plugins.qbittorrent_config_runtime import (
        QbittorrentConfigRuntime,
    )
    from larenor_server.plugins.resource_journal import ResourceJournal
    from larenor_server.plugins.volume_bootstrap import VolumeBootstrapVerifier
    from larenor_server.plugins.volume_create_journal import VolumeCreateJournal

    private = PrivateQbittorrentConfiguration(
        credential=secrets.token_urlsafe(48),
        apiKey=secrets.token_urlsafe(32),
        saltHex=secrets.token_hex(16))
    job = uuid.uuid4().hex
    with ResourceJournal(daemon.root / 'resource-journal') as resources, \
            VolumeCreateJournal(daemon.root / 'volume-journal') as volumes, \
            ManagedWorkerJournal(
                daemon.root / 'qbittorrent-container-journal',
                initialize=True) as containers:
        verifier = VolumeBootstrapVerifier(
            endpoint, helper_id, daemon.platform)
        readers = JellyfinEngineReaders(endpoint, verifier)
        broker = JellyfinResourceProofBroker(
            source.stack, source.catalog, source.policy,
            resources, volumes, readers, engine_identity=endpoint,
            service_id='qbittorrent')
        builder = JellyfinBindingBuilder(
            source.catalog, source.policy, containers.identity, broker,
            service_id='qbittorrent')

        def binding(stack, service_id='qbittorrent'):
            require(service_id == 'qbittorrent')
            return builder(stack)

        with diagnostic_phase('runtime_setup'):
            engine = smoke._managed_engine(endpoint)
            operations = JournaledManagedContainerOperations(
                containers, engine)
            backend = _RuntimeBackend(
                operations, binding,
                QbittorrentConfigRuntime(
                    endpoint, volumes, source.catalog, source.policy,
                    helper_id, daemon.platform))
        with diagnostic_phase('runtime_install'):
            receipt = backend.install_configured_qbittorrent(
                job, source.stack, private.credential,
                api_key=private.apiKey, salt=bytes.fromhex(private.saltHex),
                cancelled=threading.Event(), deadline=time.monotonic() + 90,
                gate=lambda: True)
        with diagnostic_phase('configuration_receipt'):
            require(
                receipt.configuration.state
                == 'qbittorrent_config_installed')
        with diagnostic_phase('container_receipt'):
            require(receipt.state == 'qbittorrent_container_started')
        with diagnostic_phase('service_receipt'):
            require(
                receipt.service_state == 'qbittorrent_service_verified')
        with diagnostic_phase('container_inspect'):
            binding_value = binding(source.stack)
            running = engine.inspect_container(receipt.container_id)
            require(
                managed_container_matches(running, binding_value)
                and running.get('State', {}).get('Running') is True)
            host = binding_value.payload()['specification']['HostConfig']
        with diagnostic_phase('resource_verify'):
            daemon.verify_container_resources(
                running.get('State', {}).get('Pid'), host['Memory'],
                host['NanoCpus'], host['PidsLimit'])
        with diagnostic_phase('container_restart'):
            daemon.docker([
                'restart', '--time=10', receipt.container_id,
            ], timeout=30, limit=128)
        with diagnostic_phase('bootstrap_reverify'):
            restarted = backend.qbittorrent_bootstrap.execute(
                job, source.stack, private,
                deadline=time.monotonic() + 90, gate=lambda: True)
            require(
                restarted.state == 'verified'
                and restarted.categories.categories
                == (('movies', '/data/downloads/movies'),
                    ('tv', '/data/downloads/tv'))
                and restarted.categories.completed_steps
                == ('categories_observed', 'categories_verified')
                and restarted.readback.state == 'verified'
                and restarted.readback.version == 'v5.2.3')
        with diagnostic_phase('post_restart_inspect'):
            running = engine.inspect_container(receipt.container_id)
            require(
                managed_container_matches(running, binding_value)
                and running.get('State', {}).get('Running') is True)
            daemon.verify_container_resources(
                running.get('State', {}).get('Pid'), host['Memory'],
                host['NanoCpus'], host['PidsLimit'])
        return receipt


def characterize(daemon, *, checkout_binding=None):
    """Exercise the exact production qBittorrent path on an owned daemon."""
    checkout_binding = (
        smoke.capture_source(os.environ['GITHUB_SHA'])
        if checkout_binding is None else checkout_binding)
    smoke.check_source(checkout_binding)
    source = fixture_source(daemon.platform)
    with diagnostic_phase('resource_prepare'):
        endpoint, volume_states = _prepare_resources(daemon, source)
    helper_id, attestation = _build_helper(daemon, checkout_binding)
    _prepare_volumes(daemon, source, helper_id)
    receipt = _install_and_restart(
        daemon, source, endpoint, helper_id)
    smoke.check_source(checkout_binding)
    return {
        'schemaVersion': 1,
        'result': 'qbittorrent_characterized',
        'platform': daemon.platform,
        'sourceCommit': checkout_binding[0],
        'catalogDigest': source.catalog.digest,
        'qbittorrentManifestDigest': source.image.image.digest,
        'qbittorrentConfigDigest': source.image.image.configDigest,
        'helper': attestation,
        'imageState': 'ready',
        'networkState': 'ready',
        'volumeStates': volume_states,
        'volumeCount': 2,
        'containerMode': 'journaled_managed_v2',
        'containerJournalVersion': 2,
        'configurationState': receipt.configuration.state,
        'containerState': receipt.state,
        'serviceState': receipt.service_state,
        'categoryCount': 2,
        'categoriesPersistent': True,
        'apiKeyVerified': True,
        'restartCount': 1,
        'installAvailable': False,
    }


def run():
    selected = validate_launch(
        os.environ, platform.system(), platform.machine(), os.geteuid())
    commit = os.environ['GITHUB_SHA']
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
        with smoke.diagnostic_phase('source_capture'):
            binding = smoke.capture_source(commit)
        with owner as daemon:
            value = characterize(daemon, checkout_binding=binding)
        with smoke.diagnostic_phase('source_recheck'):
            smoke.check_source(binding)
        validate_receipt(value, commit, selected)
        print(json.dumps(value, sort_keys=True, separators=(',', ':')))
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
    raise QbittorrentManagedCIError(
        'qbittorrent_characterization_evidence_invalid')


def verify(path):
    try:
        with Path(path).open('rb') as source:
            raw = source.read(32769)
        require(0 < len(raw) <= 32768)
        value = json.loads(
            raw, object_pairs_hook=_unique, parse_constant=_nonfinite)
        commit = os.environ.get('GITHUB_SHA', '')
        selected = os.environ.get('EXPECTED_PLATFORM', '')
        smoke.verify_checkout(commit)
        validate_receipt(value, commit, selected)
        print('qbittorrent_characterization_receipt_verified')
    except QbittorrentManagedCIError:
        raise
    except Exception:
        raise QbittorrentManagedCIError(
            'qbittorrent_characterization_evidence_invalid') from None


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    try:
        if args == ['--run-ephemeral-ci']:
            run()
        elif len(args) == 2 and args[0] == '--verify-receipt':
            verify(args[1])
        else:
            raise QbittorrentManagedCIError(
                'qbittorrent_characterization_evidence_invalid')
        return 0
    except _Cancelled:
        print('qbittorrent_characterization_cancelled', file=sys.stderr)
    except Exception as error:
        if type(error) is smoke.SmokeError:
            print(smoke.failure_diagnostic(error), file=sys.stderr)
        elif (type(error) is QbittorrentManagedCIError
              and error.args and error.args[0] in _DIAGNOSTIC_CODES):
            print(error.args[0], file=sys.stderr)
        else:
            print('qbittorrent_characterization_failed', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
