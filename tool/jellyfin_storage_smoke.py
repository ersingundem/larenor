#!/usr/bin/env python3
"""Opt-in native CI characterization; never connects to an existing daemon.

The only CLI action creates a transient owned cgroup, mount namespace, daemon,
data root, socket and empty Docker client configuration. No supplied socket,
platform or DOCKER_HOST fallback exists. CI environment checks are an
accidental-use guard, not a production authority issuer. This is not wired to
Server API/runtime.
"""
from contextlib import contextmanager
from dataclasses import dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from types import MappingProxyType
import uuid


REPOSITORY = Path(__file__).resolve().parents[1]
_HASH = re.compile(r'sha256:[0-9a-f]{64}\Z')
_CONTAINER_ID = re.compile(r'[0-9a-f]{64}\Z')
_COMMIT = re.compile(r'[0-9a-f]{40}\Z')
_CODES = {'storage_characterization_failed','native_ephemeral_ci_required','fixture_command_failed',
    'owned_daemon_lost','owned_daemon_unavailable','owned_cleanup_failed','fixture_image_unresolved',
    'fixture_volume_unresolved','fixture_protocol_failed','jellyfin_startup_timeout',
    'unexpected_image_volume','unexpected_initial_write_access','restart_identity_changed','fixture_source_changed',
    'owned_daemon_scope_invalid'}
# Quiet legacy build can emit buffered progress followed by its final error.
# Keep the complete diagnostic input bounded; never export or persist it.
_BUILD_STDERR_LIMIT = 65536
_BUILD_ERROR_PATTERNS = {
    'helper_build_manifest_missing': (b'manifest unknown',),
    'helper_build_platform_missing': (b'no matching manifest for ', b'no match for platform in manifest'),
    'helper_build_registry_limit': (b'toomanyrequests:', b'429 too many requests'),
    'helper_build_registry_auth': (b'pull access denied', b'unauthorized: authentication required'),
    'helper_build_runtime_failed': (b'failed to create shim task', b'oci runtime create failed', b'runc create failed'),
    'helper_build_context_failed': (b'copy failed:', b'failed to read dockerfile'),
    'helper_build_tls_failed': (b'x509:', b'tls handshake timeout'),
    'helper_build_dns_failed': (b'no such host', b'temporary failure in name resolution'),
    'helper_build_storage_failed': (b'no space left on device', b'read-only file system'),
    'helper_build_step_failed': (b'returned a non-zero code:',),
}
# start --attach also performs inspect/attach/wait/stream operations. These
# private signatures do not prove which of those operations or host paths failed.
_START_STDERR_LIMIT = 65536
_START_ERROR_PATTERNS = {
    'helper_base_exec_failed': (b'exec format error', b'executable file not found'),
    'helper_base_permission_failed': (b'permission denied', b'operation not permitted'),
    'helper_base_storage_failed': (b'no space left on device', b'read-only file system'),
    'helper_base_daemon_unavailable': (b'cannot connect to the docker daemon', b'error during connect:'),
    'helper_base_container_missing': (b'no such container:',),
    'helper_base_wait_failed': (b'error waiting for container:',),
}
_START_RUNTIME_PATTERNS = (b'failed to create shim task', b'oci runtime create failed',
    b'runc create failed', b'failed to create task for container')
_STATE_ERROR_PATTERNS = {
    'helper_base_isolation_failed': (b'cgroup', b'apparmor', b'seccomp', b'selinux',
        b'namespace', b'rootfs', b'failed to mount', b'mount callback'),
    'helper_base_host_resource_failed': (b'resource temporarily unavailable',
        b'cannot allocate memory', b'too many open files'),
    'helper_base_path_failed': (b'no such file or directory', b'not a directory'),
    'helper_base_identity_failed': (b'no matching entries in passwd file',
        b'unable to find user', b'unable to find group'),
    'helper_base_configuration_failed': (b'invalid argument', b'invalid configuration'),
}
_PATH_LOCATION_PATTERNS = {
    'helper_base_image_path_failed': (b'/usr/local/bin/python', b'/opt/larenor/'),
    'helper_base_proc_path_failed': (b'/proc/',),
    'helper_base_sys_path_failed': (b'/sys/',),
    'helper_base_runtime_path_failed': (b'/run/',),
    'helper_base_engine_path_failed': (b'/tmp/larenor-jellyfin-', b'/var/lib/docker/'),
    'helper_base_host_path_failed': (b'/etc/resolv.conf', b'/etc/hostname', b'/etc/hosts'),
}
_PATH_RELATION_CODES = {
    frozenset(('helper_base_engine_path_failed', 'helper_base_image_path_failed')):
        'helper_base_engine_image_path_failed',
    frozenset(('helper_base_engine_path_failed', 'helper_base_proc_path_failed')):
        'helper_base_engine_proc_path_failed',
    frozenset(('helper_base_engine_path_failed', 'helper_base_sys_path_failed')):
        'helper_base_engine_sys_path_failed',
    frozenset(('helper_base_engine_path_failed', 'helper_base_runtime_path_failed')):
        'helper_base_engine_runtime_path_failed',
    frozenset(('helper_base_engine_path_failed', 'helper_base_host_path_failed')):
        'helper_base_engine_host_path_failed',
}
_PATH_COOCCURRENCE_CODES = {
    frozenset(('helper_base_engine_path_failed', 'helper_base_image_path_failed')):
        'helper_base_engine_image_paths_observed',
    frozenset(('helper_base_engine_path_failed', 'helper_base_proc_path_failed')):
        'helper_base_engine_proc_paths_observed',
    frozenset(('helper_base_engine_path_failed', 'helper_base_sys_path_failed')):
        'helper_base_engine_sys_paths_observed',
    frozenset(('helper_base_engine_path_failed', 'helper_base_runtime_path_failed')):
        'helper_base_engine_runtime_paths_observed',
    frozenset(('helper_base_engine_path_failed', 'helper_base_host_path_failed')):
        'helper_base_engine_host_paths_observed',
}
_PROC_SUBPATH_PATTERNS = {
    'helper_base_proc_sys_net_path_observed': (b'/proc/sys/net/',),
    'helper_base_proc_self_fd_path_observed': (b'/proc/self/fd/',),
    'helper_base_proc_self_mountinfo_observed': (b'/proc/self/mountinfo',),
    'helper_base_proc_self_namespace_observed': (b'/proc/self/ns/',),
}
_PROC_PROCESS_PATTERNS = {
    'helper_base_proc_process_namespace_observed': re.compile(rb'/proc/[1-9][0-9]{0,9}/ns/'),
    'helper_base_proc_process_fd_path_observed': re.compile(rb'/proc/[1-9][0-9]{0,9}/fd/'),
}
_PROC_PROCESS_NAMESPACE_PATTERN = re.compile(
    rb'/proc/[1-9][0-9]{0,9}/ns/([^/]+)\Z')
_PROC_PROCESS_NAMESPACE_CODES = {
    b'net': 'helper_base_proc_process_net_namespace_observed',
    b'mnt': 'helper_base_proc_process_mnt_namespace_observed',
    b'ipc': 'helper_base_proc_process_ipc_namespace_observed',
    b'uts': 'helper_base_proc_process_uts_namespace_observed',
    b'pid': 'helper_base_proc_process_pid_namespace_observed',
    b'pid_for_children': 'helper_base_proc_process_pid_children_namespace_observed',
    b'user': 'helper_base_proc_process_user_namespace_observed',
    b'cgroup': 'helper_base_proc_process_cgroup_namespace_observed',
    b'time': 'helper_base_proc_process_time_namespace_observed',
    b'time_for_children': 'helper_base_proc_process_time_children_namespace_observed',
}
_PATH_TOKEN = re.compile(rb"/[^\s\"'(),:;]+")
_MANAGED_CREATE_DIAGNOSTICS = {
    'managed_create_mount_rejected', 'managed_create_network_rejected',
    'managed_create_cgroup_rejected', 'managed_create_security_rejected',
    'managed_create_image_rejected', 'managed_create_resource_rejected',
    'managed_create_engine_rejected', 'managed_create_transport_failed',
    'managed_create_binding_rejected', 'managed_create_protocol_failed',
    'managed_create_endpoint_rejected', 'managed_create_resource_conflict',
    'managed_create_response_invalid', 'managed_create_identity_invalid',
    'managed_create_platform_warning', 'managed_create_network_warning',
    'managed_create_resource_warning', 'managed_create_security_warning',
    'managed_create_warning_unclassified',
    'managed_create_swap_warning', 'managed_create_memory_warning',
    'managed_create_cpu_warning', 'managed_create_pids_warning',
    'managed_inspect_memory_swap_mismatch', 'managed_inspect_memory_mismatch',
    'managed_inspect_cpu_mismatch', 'managed_inspect_pids_mismatch',
    'managed_inspect_security_mismatch', 'managed_inspect_tmpfs_mismatch',
    'managed_inspect_tmpfs_targets_mismatch', 'managed_inspect_tmpfs_order_mismatch',
    'managed_inspect_tmpfs_empty_normalized',
    'managed_inspect_tmpfs_size_normalized', 'managed_inspect_tmpfs_option_missing',
    'managed_inspect_tmpfs_option_extra', 'managed_inspect_tmpfs_value_mismatch',
    'managed_inspect_requested_mount_mismatch', 'managed_inspect_network_mode_mismatch',
    'managed_inspect_init_mismatch', 'managed_inspect_restart_mismatch',
    'managed_inspect_identity_mismatch', 'managed_inspect_config_mismatch',
    'managed_inspect_forbidden_host_mismatch',
    'managed_inspect_observed_mount_mismatch',
    'managed_inspect_network_attachment_mismatch',
    'managed_inspect_networks_missing', 'managed_inspect_network_key_mismatch',
    'managed_inspect_network_id_missing', 'managed_inspect_network_id_mismatch',
    'managed_inspect_nonresource_mismatch',
}
_DIAGNOSTIC_CODES = _CODES | set(_BUILD_ERROR_PATTERNS) | set(_START_ERROR_PATTERNS) | {
    'helper_base_runtime_failed', 'helper_base_error_ambiguous',
    'helper_base_state_error_ambiguous', *_STATE_ERROR_PATTERNS,
    'helper_base_path_location_ambiguous', *_PATH_LOCATION_PATTERNS,
    *_PATH_RELATION_CODES.values(), *_PATH_COOCCURRENCE_CODES.values(),
    *_PROC_SUBPATH_PATTERNS, *_PROC_PROCESS_PATTERNS, 'helper_base_proc_subpaths_ambiguous',
    *_PROC_PROCESS_NAMESPACE_CODES.values(), 'helper_base_proc_process_namespaces_ambiguous',
    'helper_base_process_oom', 'helper_base_process_nonzero', 'helper_base_process_running',
    'helper_base_process_dead', 'helper_base_process_exited_zero',
    'helper_base_process_not_started', 'helper_base_process_not_started_nonzero',
    'helper_base_state_read_failed', 'helper_base_state_invalid',
    'helper_base_state_unclassified', 'helper_base_state_error_unclassified',
    'helper_base_state_status_unclassified',
    'helper_base_state_known_status_unclassified',
    'fixture_command_stderr_limit', 'helper_build_error_ambiguous',
    'invalid_image_preparation', 'invalid_image_binding',
    'fixture_command_exit_failed', 'fixture_command_output_limit', 'fixture_command_timeout',
    'fixture_command_spawn_failed', 'fixture_command_io_failed',
    'image_cancelled', 'image_pull_not_authorized', 'image_observation_unavailable',
    'invalid_image_limits', 'image_protocol', 'image_stream_limit', 'image_pull_failed',
    'image_engine_unavailable', 'image_timeout', 'image_unverified', 'image_api_unsupported',
    'invalid_volume_preparation', 'invalid_volume_binding', 'invalid_volume_effect_limits',
    'volume_create_not_authorized', 'volume_protocol', 'volume_response_limit',
    'volume_engine_unavailable', 'volume_timeout', 'volume_cancelled', 'volume_api_unsupported',
    'journal_unavailable', 'unsafe_worker_path', 'worker_busy', 'invalid_binding',
    *_MANAGED_CREATE_DIAGNOSTICS, 'managed_create_preflight_failed',
    'managed_create_uncertain', 'managed_create_resource_conflict',
    'managed_create_expired', 'managed_create_receipt_invalid',
    'managed_resource_limits_unverified',
    'storage_characterization_evidence_invalid'}
_PHASES = {'launcher', 'launch_validation', 'source_capture', 'daemon_start', 'daemon_cleanup',
    'characterization', 'image_prepare', 'volume_prepare', 'image_inspect', 'helper_stage',
    'helper_base_binding', 'helper_base_pull', 'helper_base_inspect', 'helper_base_create',
    'helper_base_created', 'helper_base_start', 'helper_base_result',
    'helper_build', 'helper_inspect', 'helper_seed', 'initial_permissions', 'bootstrap_check',
    'bootstrap_initialize', 'initialized_permissions', 'sentinel_write', 'container_create',
    'container_inspect', 'container_start', 'initial_health', 'initial_identity', 'initial_data',
    'container_restart', 'restart_health', 'restart_identity', 'root_verify', 'sentinel_verify',
    'restart_data', 'source_recheck', 'receipt_validate', 'receipt_verify'}
_SOURCE_FILES = (
    '.github/workflows/jellyfin-storage-characterization.yml',
    '.github/workflows/jellyfin-managed-characterization.yml',
    'tool/volume_bootstrap_helper.py', 'tool/jellyfin_storage_probe.py',
    'tool/jellyfin_storage_smoke.py', 'tool/jellyfin_storage_ci.py',
    'tool/jellyfin_managed_ci.py',
    'tool/media_resource_smoke.py',
    'server/Dockerfile.volume-bootstrap',
    'server/Dockerfile.volume-bootstrap.dockerignore',
    'server/larenor_server/context.py',
    'server/larenor_server/services/transport.py',
    'server/larenor_server/plugins/packagedcatalog.json',
    'server/larenor_server/plugins/catalog.py',
    'server/larenor_server/plugins/stack_plan.py',
    'server/larenor_server/plugins/resource_models.py',
    'server/larenor_server/plugins/resource_plan.py',
    'server/larenor_server/plugins/resource_journal.py',
    'server/larenor_server/plugins/image_resources.py',
    'server/larenor_server/plugins/image_preparation.py',
    'server/larenor_server/plugins/network_resources.py',
    'server/larenor_server/plugins/network_transport.py',
    'server/larenor_server/plugins/network_effects.py',
    'server/larenor_server/plugins/network_preparation.py',
    'server/larenor_server/plugins/volume_plan.py',
    'server/larenor_server/plugins/volume_resources.py',
    'server/larenor_server/plugins/volume_transport.py',
    'server/larenor_server/plugins/volume_effects.py',
    'server/larenor_server/plugins/volume_create_journal.py',
    'server/larenor_server/plugins/volume_preparation.py',
    'server/larenor_server/plugins/managed_container.py',
    'server/larenor_server/plugins/worker.py',
    'server/larenor_server/plugins/docker_probe.py',
    'server/larenor_server/plugins/engine_http.py',
    'LICENSE', 'NOTICE',
)
_BUILD_FILES = ('tool/volume_bootstrap_helper.py', 'tool/jellyfin_storage_probe.py',
    'server/Dockerfile.volume-bootstrap', 'LICENSE', 'NOTICE')


class SmokeError(Exception):
    def __init__(self, code='storage_characterization_failed', *, phase=None):
        self.phase = _closed(phase, _PHASES, 'launcher')
        super().__init__(_closed(code, _DIAGNOSTIC_CODES, 'storage_characterization_failed'))


def _closed(value, allowed, fallback):
    return value if type(value) is str and len(value) <= 64 and value in allowed else fallback


def _error_code(error):
    # Read only BaseException's stored arguments, never __str__/repr or a custom
    # property. Arbitrary diagnostics, paths, output and credentials stay private.
    args = BaseException.args.__get__(error)
    return _closed(args[0] if len(args) == 1 else None,
                   _DIAGNOSTIC_CODES, 'storage_characterization_failed')


@contextmanager
def diagnostic_phase(name):
    """Preserve the innermost failing boundary; cleanup success cannot replace it."""
    selected = _closed(name, _PHASES, 'launcher')
    try:
        yield
    except Exception as error:
        if type(error) is SmokeError:
            selected = _closed(error.phase, _PHASES, selected)
            # An unannotated SmokeError belongs to this boundary.
            if selected == 'launcher':
                selected = _closed(name, _PHASES, 'launcher')
        raise SmokeError(_error_code(error), phase=selected) from None


def failure_diagnostic(error):
    phase = _closed(error.phase, _PHASES, 'launcher') if type(error) is SmokeError else 'launcher'
    return 'storage_characterization_failed phase='+phase+' code='+_error_code(error)


def require(value, code='storage_characterization_failed'):
    if not value:
        raise SmokeError(code)


def native_platform(environment, system, machine, uid):
    selected = {'x86_64': ('X64', 'linux/amd64'), 'aarch64': ('ARM64', 'linux/arm64')}.get(machine)
    require(system == 'Linux' and type(uid) is int and uid == 0 and selected is not None
        and environment.get('CI') == 'true' and environment.get('GITHUB_ACTIONS') == 'true'
        and environment.get('RUNNER_ENVIRONMENT') == 'github-hosted'
        and environment.get('RUNNER_ARCH') == selected[0]
        and _COMMIT.fullmatch(environment.get('GITHUB_SHA', '')) is not None,
        'native_ephemeral_ci_required')
    return selected[1]


def child_environment(root):
    return {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'HOME': str(root), 'DOCKER_CONFIG': str(root/'docker-config'),
        'DOCKER_API_VERSION': '1.47', 'DOCKER_BUILDKIT': '0', 'LANG': 'C.UTF-8'}


def _signal_group(process, sig):
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def _build_error(stderr):
    """Diagnostic signature only, never authority or raw Docker output."""
    folded = stderr.lower()
    matched = {code for code, patterns in _BUILD_ERROR_PATTERNS.items()
               if any(pattern in folded for pattern in patterns)}
    if len(matched) == 1:
        return matched.pop()
    return 'helper_build_error_ambiguous' if matched else 'fixture_command_exit_failed'


def _start_error(stderr):
    """Only complete nonzero stderr; a wrapper is fallback, not another cause."""
    folded = stderr.lower()
    matched = {code for code, patterns in _START_ERROR_PATTERNS.items()
               if any(pattern in folded for pattern in patterns)}
    if len(matched) == 1:
        return matched.pop()
    if matched:
        return 'helper_base_error_ambiguous'
    if any(pattern in folded for pattern in _START_RUNTIME_PATTERNS):
        return 'helper_base_runtime_failed'
    return 'fixture_command_exit_failed'


def _path_location_codes(path):
    """Classify one parsed absolute path without conflating nested root names."""
    engine = any(pattern in path for pattern in _PATH_LOCATION_PATTERNS[
        'helper_base_engine_path_failed'])
    locations = set()
    if any(pattern in path for pattern in _PATH_LOCATION_PATTERNS[
            'helper_base_image_path_failed']):
        locations.add('helper_base_image_path_failed')
    if path.startswith(b'/proc/') or (engine and b'/proc/' in path):
        locations.add('helper_base_proc_path_failed')
    if path.startswith(b'/sys/') or (engine and b'/sys/' in path):
        locations.add('helper_base_sys_path_failed')
    if path.startswith(b'/run/') or (engine and b'/run/' in path):
        locations.add('helper_base_runtime_path_failed')
    if engine:
        locations.add('helper_base_engine_path_failed')
    if any(pattern in path for pattern in _PATH_LOCATION_PATTERNS[
            'helper_base_host_path_failed']):
        locations.add('helper_base_host_path_failed')
    return locations


def _proc_subpath_codes(paths):
    """Return closed subfamilies from genuine procfs-rooted path tokens only."""
    matched = set()
    for path in paths:
        if not path.startswith(b'/proc/'):
            continue
        for code, patterns in _PROC_SUBPATH_PATTERNS.items():
            if code == 'helper_base_proc_self_mountinfo_observed':
                observed = path in patterns
            else:
                observed = any(path.startswith(pattern) for pattern in patterns)
            if observed:
                matched.add(code)
        matched.update(code for code, pattern in _PROC_PROCESS_PATTERNS.items()
                       if pattern.match(path) is not None)
    return matched


def _proc_process_namespace_codes(paths):
    """Map namespace leaves without retaining or returning their process IDs."""
    matched = set()
    for path in paths:
        match = _PROC_PROCESS_NAMESPACE_PATTERN.fullmatch(path)
        if match is not None:
            code = _PROC_PROCESS_NAMESPACE_CODES.get(match.group(1))
            if code is not None:
                matched.add(code)
    return matched


def _state_error(error):
    """Reduce a private Engine state error to a fixed non-secret family."""
    classified = _start_error(error)
    if classified != 'fixture_command_exit_failed':
        return classified
    folded = error.lower()
    message = _PATH_TOKEN.sub(b'', folded)
    matched = {code for code, patterns in _STATE_ERROR_PATTERNS.items()
               if any(pattern in message for pattern in patterns)}
    if len(matched) == 1:
        classified = matched.pop()
        if classified == 'helper_base_path_failed':
            path_locations = [_path_location_codes(path)
                              for path in _PATH_TOKEN.findall(folded)]
            locations = set().union(*path_locations) if path_locations else set()
            if len(locations) == 1:
                return locations.pop()
            if locations:
                relation = _PATH_RELATION_CODES.get(frozenset(locations))
                if relation is not None and any(path_codes == locations
                                                for path_codes in path_locations):
                    return relation
                cooccurrence = _PATH_COOCCURRENCE_CODES.get(frozenset(locations))
                if cooccurrence == 'helper_base_engine_proc_paths_observed':
                    paths = _PATH_TOKEN.findall(folded)
                    proc_paths = _proc_subpath_codes(paths)
                    if len(proc_paths) == 1:
                        if proc_paths == {'helper_base_proc_process_namespace_observed'}:
                            namespaces = _proc_process_namespace_codes(paths)
                            if len(namespaces) == 1:
                                return namespaces.pop()
                            if namespaces:
                                return 'helper_base_proc_process_namespaces_ambiguous'
                        return proc_paths.pop()
                    if proc_paths:
                        return 'helper_base_proc_subpaths_ambiguous'
                return cooccurrence or 'helper_base_path_location_ambiguous'
        return classified
    return 'helper_base_state_error_ambiguous' if matched else classified


def _diagnose_base_start_state(daemon, container_id, original):
    """Privately reduce one owned post-failure state read to a closed code."""
    if type(original) is not SmokeError:
        raise TypeError('exact SmokeError required')
    fallback = _error_code(original)
    def unreadable(code):
        return code if fallback == 'fixture_command_exit_failed' else fallback
    try:
        raw = daemon.docker(
            ['container','inspect','--format','{{json .State}}',container_id],
            timeout=10, limit=65536)
    except Exception:
        return unreadable('helper_base_state_read_failed')
    try:
        state = json.loads(raw)
        if type(state) is not dict:
            return unreadable('helper_base_state_invalid')
        status, exit_code, error = state.get('Status'), state.get('ExitCode'), state.get('Error')
        if (type(status) is not str or type(exit_code) is not int or type(exit_code) is bool
                or type(error) is not str
                or any(type(state.get(key)) is not bool
                    for key in ('Running','Paused','Restarting','Dead','OOMKilled'))):
            return unreadable('helper_base_state_invalid')
        error_bytes = error.encode('utf-8')
        if len(error_bytes) > 65536:
            return unreadable('helper_base_state_invalid')
    except (ValueError, TypeError, RecursionError, UnicodeError):
        return unreadable('helper_base_state_invalid')
    if error:
        classified = _state_error(error_bytes)
        if classified != 'fixture_command_exit_failed':
            return classified
    if state['OOMKilled']:
        return 'helper_base_process_oom'
    if state['Dead']:
        return 'helper_base_process_dead'
    if state['Running'] or state['Paused'] or state['Restarting'] or status == 'running':
        return 'helper_base_process_running'
    if status == 'exited' and exit_code != 0:
        return 'helper_base_process_nonzero'
    if not error and status == 'exited' and exit_code == 0:
        return 'helper_base_process_exited_zero'
    if not error and status == 'created' and exit_code == 0:
        return 'helper_base_process_not_started'
    if error:
        return unreadable('helper_base_state_error_unclassified')
    if status == 'created' and exit_code != 0:
        return 'helper_base_process_not_started_nonzero'
    if status not in {'created','restarting','running','removing','paused','exited','dead'}:
        return unreadable('helper_base_state_status_unclassified')
    return unreadable('helper_base_state_known_status_unclassified')


def bounded_command(arguments, *, environment, timeout=60, limit=65536,
                    diagnose_failure=False, diagnose_process=False, diagnose_start=False):
    """Separate process-only, private build and private attached-start diagnostics."""
    require(type(diagnose_failure) is bool and type(diagnose_process) is bool
        and type(diagnose_start) is bool and not (diagnose_failure and diagnose_start), 'fixture_command_failed')
    private_stderr = diagnose_failure or diagnose_start
    detailed_codes = private_stderr or diagnose_process
    def check(value, code):
        require(value, code if detailed_codes else 'fixture_command_failed')
    process = None
    stderr = bytearray()
    deadline = time.monotonic() + timeout
    try:
        process = subprocess.Popen(arguments, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE if private_stderr else subprocess.DEVNULL,
            bufsize=0, start_new_session=True)
        result = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
            if private_stderr:
                selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
            while selector.get_map():
                remaining = deadline - time.monotonic()
                check(remaining > 0, 'fixture_command_timeout')
                ready = selector.select(remaining)
                check(ready, 'fixture_command_timeout')
                for key, _ in ready:
                    buffer, bound, code = ((result, limit, 'fixture_command_output_limit')
                        if key.data == 'stdout' else (stderr, _START_STDERR_LIMIT if diagnose_start else _BUILD_STDERR_LIMIT,
                              'fixture_command_stderr_limit'))
                    chunk = os.read(key.fd, bound - len(buffer) + 1)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    buffer.extend(chunk)
                    check(len(buffer) <= bound, code)
        remaining = deadline - time.monotonic()
        check(remaining > 0, 'fixture_command_timeout')
        if process.wait(timeout=remaining) != 0:
            check(False, _start_error(stderr) if diagnose_start else
                  _build_error(stderr) if diagnose_failure else 'fixture_command_exit_failed')
        return bytes(result)
    except subprocess.TimeoutExpired:
        raise SmokeError('fixture_command_timeout' if detailed_codes else 'fixture_command_failed') from None
    except OSError:
        code = 'fixture_command_spawn_failed' if process is None else 'fixture_command_io_failed'
        raise SmokeError(code if detailed_codes else 'fixture_command_failed') from None
    finally:
        stderr.clear()
        if process is not None:
            try:
                # An exited parent can leave descendants holding its pipe open.
                # The group remains ours even when Popen.poll() has reaped it.
                _signal_group(process, signal.SIGKILL)
                process.wait(timeout=5)
            finally:
                process.stdout.close()
                if process.stderr is not None:
                    process.stderr.close()


def daemon_unit(root):
    name = root.name
    require(re.fullmatch(r'larenor-jellyfin-[a-z0-9_-]{6,72}', name) is not None,
            'owned_daemon_scope_invalid')
    return name+'.service'


def container_cgroup_parent(root):
    return '/system.slice/'+daemon_unit(root)+'/containers'


def daemon_command(root):
    unit = daemon_unit(root)
    environment = child_environment(root)
    return ['/usr/bin/systemd-run', '--quiet', '--no-ask-password', '--collect',
        '--expand-environment=no', '--unit='+unit,
        '--property=Type=exec', '--property=ExitType=main', '--property=Restart=no',
        '--property=Delegate=yes', '--property=DelegateSubgroup=daemon',
        '--property=KillMode=control-group', '--property=SendSIGKILL=yes',
        '--property=TimeoutStartSec=45s', '--property=TimeoutStopSec=15s',
        '--property=RuntimeMaxSec=1200s', '--property=StandardInput=null',
        '--property=StandardOutput=null', '--property=StandardError=null',
        '/usr/bin/env', '-i', *(key+'='+environment[key] for key in sorted(environment)),
        '/usr/bin/unshare', '--mount', '--propagation=private', '/usr/bin/dockerd',
        '--host=unix://'+str(root/'engine.sock'), '--data-root='+str(root/'data'),
        '--exec-root='+str(root/'exec'), '--pidfile='+str(root/'daemon.pid'),
        '--config-file='+str(root/'daemon.json'), '--bridge=none', '--iptables=false',
        '--ip6tables=false', '--ip-forward=false', '--ip-masq=false',
        '--userland-proxy=false', '--storage-driver=vfs', '--group=root',
        '--exec-opt=native.cgroupdriver=cgroupfs',
        '--cgroup-parent='+container_cgroup_parent(root)]


_UNIT_PROPERTIES = ('Id','LoadState','ActiveState','SubState','Transient','InvocationID',
    'ControlGroup','MainPID','KillMode','Delegate','DelegateSubgroup')


def unit_show_command(root, *properties):
    require(properties and all(property in _UNIT_PROPERTIES for property in properties),
            'owned_daemon_scope_invalid')
    return ['/usr/bin/systemctl','--no-ask-password','--no-pager','show',daemon_unit(root),
        *(('--property='+property) for property in properties)]


def _unit_properties(raw, root):
    require(type(raw) is bytes and 0 < len(raw) <= 4096, 'owned_daemon_lost')
    values = {}
    try:
        for line in raw.splitlines():
            key, separator, value = line.partition(b'=')
            key = key.decode('ascii')
            require(separator == b'=' and key in _UNIT_PROPERTIES and key not in values,
                    'owned_daemon_lost')
            values[key] = value.decode('ascii')
    except UnicodeError:
        raise SmokeError('owned_daemon_lost') from None
    require(set(values) == set(_UNIT_PROPERTIES)
        and values['Id'] == daemon_unit(root)
        and values['LoadState'] == 'loaded'
        and values['ActiveState'] == 'active'
        and values['SubState'] == 'running'
        and values['Transient'] == 'yes'
        and re.fullmatch(r'[0-9a-f]{32}', values['InvocationID']) is not None
        and values['ControlGroup'] == '/system.slice/'+daemon_unit(root)
        and re.fullmatch(r'[1-9][0-9]{0,9}', values['MainPID']) is not None
        and values['KillMode'] == 'control-group'
        and values['Delegate'] == 'yes'
        and values['DelegateSubgroup'] == 'daemon', 'owned_daemon_lost')
    return values


def _bounded_file(path, limit=4096):
    with path.open('rb') as source:
        value = source.read(limit+1)
    require(len(value) <= limit, 'owned_daemon_lost')
    return value


def _cgroup_populated(raw, code='owned_cleanup_failed'):
    require(type(raw) is bytes and 0 < len(raw) <= 4096, code)
    fields = {}
    for line in raw.splitlines():
        parts = line.split()
        require(len(parts) == 2 and parts[0] not in fields, code)
        fields[parts[0]] = parts[1]
    require(fields.get(b'populated') in (b'0', b'1'), code)
    return fields[b'populated'] == b'1'


class EphemeralDaemon:
    """Own only resources created in this context; cleanup cannot select a host."""
    def __init__(self):
        self.root = self.socket_identity = self.root_identity = None
        self.unit_attempted = False
        self.unit_identity = self.cgroup_fd = self.cgroup_identity = None
        self.cgroup_kill_fd = self.cgroup_events_fd = None
        self.cgroup_live_observed = False
        self.container_cgroup_parent = None
        self.emergency_requested = self.emergency_applied = False

    def _unit_output(self, *properties):
        return bounded_command(unit_show_command(self.root, *properties),
            environment=child_environment(self.root), timeout=5, limit=4096)

    def _capture_unit(self):
        values = _unit_properties(self._unit_output(*_UNIT_PROPERTIES), self.root)
        process_cgroup = _bounded_file(Path('/proc')/values['MainPID']/'cgroup')
        require(b'0::'+values['ControlGroup'].encode('ascii')+b'/daemon\n' in process_cgroup.splitlines(True),
                'owned_daemon_lost')
        path = Path('/sys/fs/cgroup'+values['ControlGroup'])
        fd = kill_fd = events_fd = None
        try:
            fd = os.open(path, os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
            info = os.fstat(fd)
            require(stat.S_ISDIR(info.st_mode), 'owned_daemon_lost')
            kill_fd = os.open('cgroup.kill', os.O_WRONLY|os.O_CLOEXEC, dir_fd=fd)
            events_fd = os.open('cgroup.events', os.O_RDONLY|os.O_CLOEXEC, dir_fd=fd)
            initial = os.pread(events_fd, 4097, 0)
            require(_cgroup_populated(initial, 'owned_daemon_lost'), 'owned_daemon_lost')
            confirmed = _unit_properties(self._unit_output(*_UNIT_PROPERTIES), self.root)
            require(confirmed == values, 'owned_daemon_lost')
            confirm_fd = os.open(path, os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
            try:
                confirm_info = os.fstat(confirm_fd)
                confirmed_cgroup = _bounded_file(Path('/proc')/values['MainPID']/'cgroup')
                require((confirm_info.st_dev, confirm_info.st_ino) == (info.st_dev, info.st_ino)
                    and b'0::'+values['ControlGroup'].encode('ascii')+b'/daemon\n'
                        in confirmed_cgroup.splitlines(True), 'owned_daemon_lost')
            finally:
                os.close(confirm_fd)
        except BaseException:
            for descriptor in (events_fd, kill_fd, fd):
                if descriptor is not None:
                    os.close(descriptor)
            raise
        self.unit_identity = values['InvocationID'], values['ControlGroup'], values['MainPID']
        self.cgroup_fd, self.cgroup_kill_fd, self.cgroup_events_fd = fd, kill_fd, events_fd
        self.cgroup_identity = info.st_dev, info.st_ino
        self.cgroup_live_observed = True

    def _check_unit(self):
        values = _unit_properties(self._unit_output(*_UNIT_PROPERTIES), self.root)
        info = os.fstat(self.cgroup_fd)
        require(self.unit_identity == (values['InvocationID'],values['ControlGroup'],values['MainPID'])
            and self.cgroup_identity == (info.st_dev,info.st_ino),
            'owned_daemon_lost')

    def emergency_cleanup(self):
        self.emergency_requested = True
        if self.cgroup_kill_fd is None or self.emergency_applied:
            return
        require(os.write(self.cgroup_kill_fd, b'1') == 1, 'owned_cleanup_failed')
        self.emergency_applied = True

    def _wait_cgroup_empty(self, *, retirement_allowed):
        deadline = time.monotonic()+20
        while True:
            require(self.cgroup_events_fd is not None, 'owned_cleanup_failed')
            try:
                value = os.pread(self.cgroup_events_fd, 4097, 0)
            except OSError as error:
                require(error.errno == errno.ENODEV and retirement_allowed
                    and self.cgroup_live_observed, 'owned_cleanup_failed')
                return
            require(len(value) <= 4096, 'owned_cleanup_failed')
            if not _cgroup_populated(value):
                return
            require(time.monotonic() < deadline, 'owned_cleanup_failed')
            time.sleep(0.05)

    def _socket(self):
        try:
            require(self.unit_identity is not None, 'owned_daemon_lost')
            self._check_unit()
            value = (self.root/'engine.sock').lstat()
            require(stat.S_ISSOCK(value.st_mode) and value.st_uid == 0
                    and not value.st_mode & 0o002, 'owned_daemon_lost')
            identity = value.st_dev, value.st_ino
            require(self.socket_identity is None or self.socket_identity == identity, 'owned_daemon_lost')
            return identity
        except OSError:
            raise SmokeError('owned_daemon_lost') from None

    def docker(self, args, *, timeout=60, limit=65536, diagnose_failure=False, diagnose_process=False,
               diagnose_start=False):
        self._socket()
        if args and args[0] in ('create','run'):
            requested = [arg for arg in args if arg.startswith('--cgroup-parent=')]
            require(requested == ['--cgroup-parent='+self.container_cgroup_parent],
                    'owned_daemon_scope_invalid')
        return bounded_command(['/usr/bin/docker', '--host=unix://'+str(self.root/'engine.sock'),
            '--config='+str(self.root/'docker-config'), *args], environment=child_environment(self.root),
            timeout=timeout, limit=limit, diagnose_failure=diagnose_failure,
            diagnose_process=diagnose_process, diagnose_start=diagnose_start)

    def _container_cgroup_path(self, pid):
        require(type(pid) is int and pid > 0 and type(self.container_cgroup_parent) is str,
                'owned_daemon_lost')
        try:
            value = _bounded_file(Path('/proc')/str(pid)/'cgroup')
        except OSError:
            raise SmokeError('owned_daemon_lost') from None
        prefix = b'0::'+self.container_cgroup_parent.encode('ascii')+b'/'
        selected = [line.removesuffix(b'\n') for line in value.splitlines(True)
                    if line.startswith(prefix)]
        require(len(selected) == 1 and re.fullmatch(rb'0::/[A-Za-z0-9_.:/-]{1,1024}', selected[0]),
                'owned_daemon_lost')
        try:
            relative = selected[0].removeprefix(b'0::').decode('ascii')
        except UnicodeError:
            raise SmokeError('owned_daemon_lost') from None
        return Path('/sys/fs/cgroup'+relative)

    def verify_container_cgroup(self, pid):
        self._container_cgroup_path(pid)

    def verify_container_resources(self, pid, memory, nano_cpus, pids_limit):
        require(type(memory) is int and memory > 0 and type(nano_cpus) is int
                and nano_cpus > 0 and type(pids_limit) is int and pids_limit > 0,
                'managed_resource_limits_unverified')
        path = self._container_cgroup_path(pid)
        directory = None
        try:
            directory = os.open(path, os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
            values = {}
            for name in ('memory.max', 'cpu.max', 'pids.max'):
                descriptor = os.open(name, os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,
                                     dir_fd=directory)
                try:
                    raw = os.pread(descriptor, 129, 0)
                finally:
                    os.close(descriptor)
                require(0 < len(raw) <= 128 and raw.endswith(b'\n'),
                        'managed_resource_limits_unverified')
                values[name] = raw.removesuffix(b'\n')
            quota = nano_cpus * 100000 // 1000000000
            require(values == {
                'memory.max': str(memory).encode('ascii'),
                'cpu.max': (str(quota)+' 100000').encode('ascii'),
                'pids.max': str(pids_limit).encode('ascii'),
            }, 'managed_resource_limits_unverified')
        except (OSError, ValueError, TypeError, UnicodeError):
            raise SmokeError('managed_resource_limits_unverified') from None
        finally:
            if directory is not None:
                os.close(directory)

    def _verify_daemon_root(self):
        actual = json.loads(self.docker(['info', '--format', '{{json .DockerRootDir}}']))
        require(actual == str(self.root/'data'), 'owned_daemon_lost')

    @diagnostic_phase('daemon_start')
    def __enter__(self):
        self.platform = native_platform(os.environ, platform.system(), platform.machine(), os.geteuid())
        self.root = Path(tempfile.mkdtemp(prefix='larenor-jellyfin-'+uuid.uuid4().hex+'-', dir='/tmp'))
        info = self.root.lstat()
        self.root_identity = info.st_dev, info.st_ino
        try:
            self.container_cgroup_parent = container_cgroup_parent(self.root)
            (self.root/'docker-config').mkdir(mode=0o700)
            (self.root/'daemon.json').write_text('{}')
            (self.root/'daemon.json').chmod(0o600)
            self.unit_attempted = True
            try:
                launched = bounded_command(daemon_command(self.root),
                    environment=child_environment(self.root), timeout=15, limit=256,
                    diagnose_process=True)
            except SmokeError as error:
                if _error_code(error) == 'fixture_command_spawn_failed':
                    self.unit_attempted = False
                raise
            require(launched == b'', 'owned_daemon_unavailable')
            self._capture_unit()
            deadline = time.monotonic() + 40
            while not (self.root/'engine.sock').exists():
                require(time.monotonic() < deadline, 'owned_daemon_unavailable')
                self._check_unit()
                time.sleep(0.1)
            self.socket_identity = self._socket()
            self._verify_daemon_root()
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    @diagnostic_phase('daemon_cleanup')
    def __exit__(self, *_):
        if self.unit_attempted and self.cgroup_fd is None:
            raise SmokeError('owned_cleanup_failed')
        if self.cgroup_fd is not None:
            try:
                self.emergency_cleanup()
                self._wait_cgroup_empty(retirement_allowed=self.emergency_applied)
            finally:
                for descriptor in (self.cgroup_events_fd, self.cgroup_kill_fd, self.cgroup_fd):
                    if descriptor is not None:
                        os.close(descriptor)
            self.cgroup_kill_fd = self.cgroup_events_fd = None
            self.cgroup_fd = self.cgroup_identity = self.unit_identity = None
            self.cgroup_live_observed = False
            self.emergency_requested = self.emergency_applied = False
        self.unit_attempted = False
        if self.root is not None:
            value = self.root.lstat()
            require(stat.S_ISDIR(value.st_mode) and (value.st_dev, value.st_ino) == self.root_identity,
                    'owned_cleanup_failed')
            shutil.rmtree(self.root)
            self.root = None
            self.container_cgroup_parent = None


@dataclass(frozen=True, repr=False)
class FixtureSource:
    catalog: object
    stack: object
    policy: object
    plan: object
    volumes: object
    image: object
    targets: tuple


def fixture_source(selected_platform):
    from larenor_server.context import ContextResponse
    from larenor_server.plugins.catalog import load_catalog
    from larenor_server.plugins.resource_models import WorkerPolicyBinding
    from larenor_server.plugins.resource_plan import build_resource_plan
    from larenor_server.plugins.stack_plan import build_media_stack_plan
    from larenor_server.plugins.volume_plan import build_volume_plan
    catalog = load_catalog()
    context = ContextResponse(schemaVersion=1, coreId=uuid.uuid4().hex, homeId=uuid.uuid4().hex)
    stack = build_media_stack_plan(catalog, {}, selected_platform, context, uuid.uuid4().hex)
    # Identifies this fixture protocol; deliberately not an operator policy/grant.
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=1,
        workerPolicyDigest=hashlib.sha256(b'larenor-owned-ci-storage-fixture-v1').hexdigest())
    plan, volumes = build_resource_plan(stack, catalog, policy), build_volume_plan(stack, catalog, policy)
    image = next(r for r in plan.resources if r.kind == 'ensure_image' and r.serviceId == 'jellyfin')
    targets = tuple(r for r in volumes.resources if r.serviceId == 'jellyfin')
    require(len(targets) == 2 and {v.target for v in targets} == {'/config','/cache'})
    return FixtureSource(catalog, stack, policy, plan, volumes, image, targets)


def prepare_storage(root, source, images, volumes):
    from larenor_server.plugins.image_preparation import JournaledImageOperations
    from larenor_server.plugins.resource_journal import ResourceJournal
    from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
    from larenor_server.plugins.volume_preparation import JournaledVolumeCreates
    image_dir, volume_dir = root/'image-journal', root/'volume-journal'
    with diagnostic_phase('image_prepare'):
        with ResourceJournal(image_dir, initialize=not image_dir.exists()) as journal:
            result = JournaledImageOperations(journal, images).apply(source.plan, source.stack,
                source.catalog, source.policy, source.image.resourceId, authorize_pull=lambda:True)
            require(result.state == 'ready', 'fixture_image_unresolved')
    states = []
    with diagnostic_phase('volume_prepare'):
        with VolumeCreateJournal(volume_dir, initialize=not volume_dir.exists()) as journal:
            for target in source.targets:
                receipt = JournaledVolumeCreates(journal, volumes).apply(source.volumes, source.stack,
                    source.catalog, source.policy, target.resourceId, authorize_create=lambda:True)
                require(receipt.state == 'observed_requires_bootstrap', 'fixture_volume_unresolved')
                states.append(receipt.state)
    return {'imageState': result.state, 'volumeStates': states}


def _source_bytes(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        with os.fdopen(fd, 'rb') as source:
            require(stat.S_ISREG(os.fstat(source.fileno()).st_mode), 'fixture_source_changed')
            raw = source.read(1048577)
        require(len(raw) <= 1048576, 'fixture_source_changed')
        return raw
    except OSError:
        raise SmokeError('fixture_source_changed') from None


def source_hashes():
    return {name: hashlib.sha256(_source_bytes(REPOSITORY/name)).hexdigest()
            for name in _SOURCE_FILES}


def capture_source(commit):
    verify_checkout(commit)
    binding = commit, MappingProxyType(source_hashes())
    check_source(binding)
    return binding


def check_source(binding):
    commit, expected = binding
    verify_checkout(commit)
    require(source_hashes() == expected, 'fixture_source_changed')


def check_staged(context, binding):
    expected = binding[1]
    require({str(p.relative_to(context)) for p in context.rglob('*') if not p.is_dir()}
            == set(_BUILD_FILES), 'fixture_source_changed')
    for name in _BUILD_FILES:
        require(hashlib.sha256(_source_bytes(context/name)).hexdigest() == expected[name],
                'fixture_source_changed')


def stage_context(root, binding):
    """Legacy Docker reads only this new allowlisted context, never the checkout.

    Rechecks detect observed checkout/stage drift, not a malicious local writer
    changing and restoring bytes between checks. No user paths are accepted.
    """
    check_source(binding)
    context = root/'helper-context'
    context.mkdir(mode=0o700)
    for name in _BUILD_FILES:
        raw = _source_bytes(REPOSITORY/name)
        require(hashlib.sha256(raw).hexdigest() == binding[1][name], 'fixture_source_changed')
        target = context/name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with target.open('xb') as output:
            output.write(raw)
    check_source(binding)
    check_staged(context, binding)
    return context


def source_labels(commit, hashes):
    return {'org.opencontainers.image.revision': commit,
        'org.larenor.fixture.source-bundle': hashlib.sha256(
            json.dumps(hashes, sort_keys=True, separators=(',', ':')).encode()).hexdigest()}


def verify_checkout(commit):
    require(type(commit) is str and _COMMIT.fullmatch(commit), 'fixture_source_changed')
    git = ['/usr/bin/git','-c','safe.directory='+str(REPOSITORY),'-C',str(REPOSITORY)]
    env = {'PATH':'/usr/bin:/bin','LANG':'C.UTF-8'}
    head = bounded_command(git+['rev-parse','HEAD'], environment=env, limit=64).decode().strip()
    require(head == commit, 'fixture_source_changed')
    bounded_command(git+['ls-files','--error-unmatch','--',*_SOURCE_FILES],environment=env,limit=4096)
    bounded_command(git+['diff','--exit-code','HEAD','--',*_SOURCE_FILES],environment=env,limit=256)


def helper_attestation(image_id, inspected, selected_platform, commit, *, expected_hashes=None):
    require(type(image_id) is str and _HASH.fullmatch(image_id) and _COMMIT.fullmatch(commit))
    require(inspected.get('Id') == image_id and inspected.get('Os') == 'linux'
            and inspected.get('Architecture') == selected_platform.split('/')[1])
    hashes = source_hashes() if expected_hashes is None else dict(expected_hashes)
    labels = inspected.get('Config',{}).get('Labels') or {}
    require(all(labels.get(key) == value for key,value in source_labels(commit,hashes).items()),
            'fixture_source_changed')
    return {'configDigest': image_id, 'platform': selected_platform, 'sourceCommit': commit,
        'publishedManifestDigest': None,
        'helperSourceSha256': hashes['tool/volume_bootstrap_helper.py'],
        'probeSourceSha256': hashes['tool/jellyfin_storage_probe.py'],
        'dockerfileSha256': hashes['server/Dockerfile.volume-bootstrap'], 'sourceHashes':hashes}


def verify_container(value, source, image_config, expected_cgroup_parent):
    require(type(value) is dict and value.get('Image') == source.image.image.configDigest)
    config, host = value.get('Config',{}), value.get('HostConfig',{})
    require(config.get('User') == '1000:1000' and host.get('NetworkMode') == 'none'
        and not host.get('PortBindings') and host.get('Privileged') is False
        and host.get('CapDrop') == ['ALL']
        and host.get('CgroupParent') == expected_cgroup_parent)
    for key in ('Entrypoint','Cmd','Volumes'):
        require(config.get(key) == image_config.get(key))
    mounts, requested = value.get('Mounts'), host.get('Mounts')
    require(type(mounts) is list and len(mounts) == 2 and type(requested) is list and len(requested) == 2)
    for target in source.targets:
        actual = [m for m in mounts if m.get('Destination') == target.target]
        desired = [m for m in requested if m.get('Target') == target.target]
        require(len(actual) == len(desired) == 1)
        require(actual[0].get('Type') == 'volume' and actual[0].get('Name') == target.name
            and actual[0].get('Driver') == 'local' and actual[0].get('RW') is True)
        require(desired[0].get('Type') == 'volume' and desired[0].get('Source') == target.name
            and desired[0].get('ReadOnly',False) is False
            and desired[0].get('VolumeOptions',{}).get('NoCopy') is True)
    require(not host.get('Binds') and not host.get('VolumesFrom'))


def _decoded(raw):
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        raise SmokeError('fixture_protocol_failed') from None



def _base_container(value, image_id, container_id, expected_cgroup_parent, *, finished):
    require(type(value) is dict and value.get('Id') == container_id
        and value.get('Image') == image_id, 'fixture_protocol_failed')
    config, host, state = value.get('Config'), value.get('HostConfig'), value.get('State')
    require(all(type(v) is dict for v in (config, host, state)), 'fixture_protocol_failed')
    require(config.get('User') == '0:0'
        and config.get('Entrypoint') == ['/usr/local/bin/python']
        and config.get('Cmd') == ['-I','-c','print("larenor-helper-base-ok-v1")']
        and not config.get('Volumes') and value.get('Mounts') == []
        and host.get('NetworkMode') == 'none' and host.get('ReadonlyRootfs') is True
        and host.get('Privileged') is False and host.get('CapDrop') == ['ALL']
        and host.get('CgroupParent') == expected_cgroup_parent
        and not any(host.get(k) for k in ('CapAdd','Binds','Mounts','VolumesFrom','PortBindings')),
        'fixture_protocol_failed')
    require(state.get('Status') == ('exited' if finished else 'created')
        and all(state.get(k) is False for k in ('Running','Paused','Dead','OOMKilled'))
        and type(state.get('ExitCode')) is int and state['ExitCode'] == 0,
        'fixture_protocol_failed')


def _helper_base(daemon, context, binding):
    """Isolate a minimal native process from legacy build; never a bootstrap grant.

    One probe belongs to the fresh daemon and is removed by its whole-namespace
    cleanup. A failed/uncertain create or start is never retried or adopted.
    """
    with diagnostic_phase('helper_base_binding'):
        check_source(binding)
        check_staged(context, binding)
        lines = _source_bytes(context/'server/Dockerfile.volume-bootstrap').decode('ascii').splitlines()
        bases = [line for line in lines if re.match(r'\s*FROM\s', line, re.IGNORECASE)]
        require(len(bases) == 1, 'fixture_source_changed')
        match = re.fullmatch(r'FROM (python:[0-9]+\.[0-9]+\.[0-9]+-slim-bookworm@sha256:[0-9a-f]{64})', bases[0])
        require(match is not None, 'fixture_source_changed')
        reference = match.group(1)
    with diagnostic_phase('helper_base_pull'):
        daemon.docker(['pull','--quiet','--platform='+daemon.platform,reference], timeout=180, limit=4096)
    with diagnostic_phase('helper_base_inspect'):
        value = _decoded(daemon.docker(['image','inspect','--format','{{json .}}',reference], limit=65536))
        require(type(value) is dict and type(value.get('Id')) is str
            and _HASH.fullmatch(value['Id']) and value.get('Os') == 'linux'
            and value.get('Architecture') == daemon.platform.split('/')[1], 'fixture_protocol_failed')
        config, digests = value.get('Config'), value.get('RepoDigests')
        require(type(config) is dict and not config.get('Volumes')
            and type(digests) is list and any(type(d) is str and d.endswith('@'+reference.split('@')[1])
                for d in digests), 'fixture_protocol_failed')
        image_id = value['Id']
    with diagnostic_phase('helper_base_create'):
        raw = daemon.docker(['create','--name=larenor-helper-base-probe','--pull=never','--network=none',
            '--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--user=0:0',
            '--pids-limit=32','--memory=64m','--restart=no','--entrypoint=/usr/local/bin/python',
            '--cgroup-parent='+daemon.container_cgroup_parent,
            image_id,'-I','-c','print("larenor-helper-base-ok-v1")'], limit=128)
        container_id = raw.decode('ascii').strip()
        require(re.fullmatch(r'[0-9a-f]{64}', container_id), 'fixture_protocol_failed')
    def inspect(finished):
        value = _decoded(daemon.docker(['container','inspect','--format','{{json .}}',container_id], limit=65536))
        _base_container(value, image_id, container_id, daemon.container_cgroup_parent,
            finished=finished)
    with diagnostic_phase('helper_base_created'):
        inspect(False)
    with diagnostic_phase('helper_base_start'):
        try:
            result = daemon.docker(['start','--attach',container_id], timeout=20, limit=128,
                diagnose_process=True, diagnose_start=True)
        except SmokeError as error:
            raise SmokeError(_diagnose_base_start_state(daemon, container_id, error)) from None
        require(result == b'larenor-helper-base-ok-v1\n', 'fixture_protocol_failed')
    with diagnostic_phase('helper_base_result'):
        inspect(True)
        check_source(binding)
        check_staged(context, binding)

def _helper(daemon, image_id, mode, *, target=None, bootstrap=False, network='none'):
    args = ['run','--rm','--network='+network,'--read-only','--cap-drop=ALL',
        '--security-opt=no-new-privileges','--pids-limit=32','--memory=64m',
        '--cgroup-parent='+daemon.container_cgroup_parent,
        '--user='+('0:0' if bootstrap and mode != 'verify_root' else '1000:1000')]
    if mode == 'app_identity':
        require(re.fullmatch(r'container:[0-9a-f]{64}', network) is not None)
        args.append('--pid='+network)
    if bootstrap:
        if mode == 'initialize_empty_root':
            args.append('--cap-add=CHOWN')
    else:
        args += ['--entrypoint=/usr/local/bin/python']
    if target is not None:
        args += ['--mount=type=volume,src='+target.name+',dst=/volume,volume-nocopy']
    args += [image_id]
    if not bootstrap:
        args += ['-I','/opt/larenor/jellyfin_storage_probe.py']
    args += [mode]
    return _decoded(daemon.docker(args, timeout=20, limit=4096))


def _health(daemon, helper_id, container_id):
    deadline = time.monotonic()+180
    while time.monotonic() < deadline:
        try:
            value = _helper(daemon, helper_id, 'health', network='container:'+container_id)
            require(type(value) is dict and value.get('version') == '10.11.11'
                and value.get('wizardCompleted') is False
                and re.fullmatch(r'[0-9a-f]{32}', value.get('id','')))
            return value
        except SmokeError:
            time.sleep(1)
    raise SmokeError('jellyfin_startup_timeout')


class _BootstrapVerifier:
    """Native acceptance adapter for the fixed, attested bootstrap helper."""

    def __init__(self, endpoint, daemon, helper_id):
        self._endpoint = endpoint
        self._daemon = daemon
        self._helper_id = helper_id

    def verify(self, intent, *, cancelled):
        from larenor_server.plugins.managed_container import VolumeBootstrapObservation
        require(type(cancelled) is threading.Event and not cancelled.is_set())
        binding, receipt = intent.binding, intent.receipt
        value = _helper(
            self._daemon, self._helper_id, 'verify_root',
            target=binding.resource, bootstrap=True,
        )
        require(value == {'schemaVersion': 1, 'state': 'root_verified'})
        return VolumeBootstrapObservation(
            binding.resource_id, binding.resource.operationId, binding.journal_id,
            binding.ownership_nonce, receipt.revision, binding.resource.name,
            binding.resource.target, 'root_verified',
        )


def _managed_create_rejection(status, body):
    """Reduce a private Docker rejection to one closed diagnostic category."""
    fallback = 'managed_create_engine_rejected'
    if type(status) is not int or type(body) is not bytes or not 0 < len(body) <= 4096:
        return fallback

    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError()
            value[key] = item
        return value

    try:
        value = json.loads(body, object_pairs_hook=unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if type(value) is not dict or set(value) != {'message'}:
            return fallback
        message = value['message']
        if type(message) is not str or not 0 < len(message) <= 4096:
            return fallback
        lowered = message.casefold()
    except (ValueError, TypeError, UnicodeError, RecursionError):
        return fallback

    categories = (
        ('managed_create_mount_rejected', ('mount', 'volume')),
        ('managed_create_network_rejected', ('network',)),
        ('managed_create_cgroup_rejected', ('cgroup',)),
        ('managed_create_security_rejected',
         ('security opt', 'apparmor', 'seccomp', 'selinux', 'capabilit', 'privileg')),
        ('managed_create_image_rejected', ('no such image', 'image not found')),
        ('managed_create_resource_rejected',
         ('memory limit', 'minimum memory', 'nano cpu', 'pids limit', 'resource')),
    )
    for code, patterns in categories:
        if any(pattern in lowered for pattern in patterns):
            return code
    return fallback


def _managed_create_success_diagnostic(body):
    if type(body) is not bytes or not 0 < len(body) <= 1048576:
        return 'managed_create_response_invalid'

    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError()
            value[key] = item
        return value

    try:
        value = json.loads(body, object_pairs_hook=unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, TypeError, UnicodeError, RecursionError):
        return 'managed_create_response_invalid'
    if type(value) is not dict:
        return 'managed_create_response_invalid'
    if (type(value.get('Id')) is not str
            or re.fullmatch(r'[0-9a-f]{64}', value['Id']) is None):
        return 'managed_create_identity_invalid'
    warnings = value.get('Warnings')
    if warnings not in (None, []):
        if (type(warnings) is not list or not 1 <= len(warnings) <= 8
                or not all(type(item) is str and 0 < len(item) <= 1024
                           for item in warnings)):
            return 'managed_create_warning_unclassified'
        lowered = '\n'.join(warnings).casefold()
        categories = (
            ('managed_create_platform_warning',
             ('requested image', 'host platform', 'platform does not match')),
            ('managed_create_network_warning',
             ('forwarding is disabled', 'networking will not work', 'bridge-nf-call')),
            ('managed_create_swap_warning', ('swap',)),
            ('managed_create_memory_warning', ('memory limit',)),
            ('managed_create_cpu_warning', ('cpu',)),
            ('managed_create_pids_warning', ('pids limit',)),
            ('managed_create_resource_warning',
             ('resource',)),
            ('managed_create_security_warning',
             ('apparmor', 'seccomp', 'selinux', 'security opt', 'capabilit')),
        )
        for code, patterns in categories:
            if any(pattern in lowered for pattern in patterns):
                return code
        return 'managed_create_warning_unclassified'
    return None


def _tmpfs_size_token(value):
    if type(value) is not str:
        return None
    match = re.fullmatch(r'size=([0-9]{1,20})([kKmMgG]?[bB]?)', value)
    if match is None:
        return None
    amount = int(match.group(1))
    unit = match.group(2).casefold().removesuffix('b')
    multiplier = {'': 1, 'k': 1024, 'm': 1048576, 'g': 1073741824}.get(unit)
    return amount * multiplier if multiplier is not None else None


def _tmpfs_diagnostic(actual, expected):
    if expected == {} and actual in (None, {}):
        return 'managed_inspect_tmpfs_empty_normalized'
    if type(actual) is not dict or type(expected) is not dict or set(actual) != set(expected):
        return 'managed_inspect_tmpfs_targets_mismatch'
    for target in sorted(expected):
        desired, observed = expected[target], actual[target]
        if desired == observed:
            continue
        if type(desired) is not str or type(observed) is not str:
            return 'managed_inspect_tmpfs_value_mismatch'
        desired_parts, observed_parts = desired.split(','), observed.split(',')
        if (not all(desired_parts) or not all(observed_parts)
                or len(set(desired_parts)) != len(desired_parts)
                or len(set(observed_parts)) != len(observed_parts)):
            return 'managed_inspect_tmpfs_value_mismatch'
        if set(desired_parts) == set(observed_parts):
            return 'managed_inspect_tmpfs_order_mismatch'
        desired_size = next((_tmpfs_size_token(item) for item in desired_parts
                             if item.startswith('size=')), None)
        observed_size = next((_tmpfs_size_token(item) for item in observed_parts
                              if item.startswith('size=')), None)
        desired_without = {item for item in desired_parts if not item.startswith('size=')}
        observed_without = {item for item in observed_parts if not item.startswith('size=')}
        if (desired_size is not None and desired_size == observed_size
                and desired_without == observed_without):
            return 'managed_inspect_tmpfs_size_normalized'
        desired_keys = {item.partition('=')[0] for item in desired_parts}
        observed_keys = {item.partition('=')[0] for item in observed_parts}
        if desired_keys - observed_keys:
            return 'managed_inspect_tmpfs_option_missing'
        if observed_keys - desired_keys:
            return 'managed_inspect_tmpfs_option_extra'
        return 'managed_inspect_tmpfs_value_mismatch'
    return 'managed_inspect_tmpfs_value_mismatch'


def _network_diagnostic(networks, name, identity):
    if type(networks) is not dict or not networks:
        return 'managed_inspect_networks_missing'
    if set(networks) != {name}:
        return 'managed_inspect_network_key_mismatch'
    attached = networks[name]
    if type(attached) is not dict or not attached.get('NetworkID'):
        return 'managed_inspect_network_id_missing'
    if attached.get('NetworkID') != identity:
        return 'managed_inspect_network_id_mismatch'
    return 'managed_inspect_network_attachment_mismatch'


def _managed_inspect_diagnostic(value, binding):
    try:
        payload = binding.payload()
        body = payload['specification']
        expected = body['HostConfig']
        actual = value.get('HostConfig')
        if type(expected) is not dict or type(actual) is not dict:
            return 'managed_inspect_nonresource_mismatch'
        for field, code in (
                ('MemorySwap', 'managed_inspect_memory_swap_mismatch'),
                ('Memory', 'managed_inspect_memory_mismatch'),
                ('NanoCpus', 'managed_inspect_cpu_mismatch'),
                ('PidsLimit', 'managed_inspect_pids_mismatch')):
            if actual.get(field) != expected.get(field):
                return code
        if any(actual.get(field) != expected.get(field) for field in (
                'Privileged', 'CapDrop', 'CapAdd', 'SecurityOpt', 'ReadonlyRootfs')):
            return 'managed_inspect_security_mismatch'
        if (actual.get('Tmpfs') != expected.get('Tmpfs')
                and not (expected.get('Tmpfs') == {} and actual.get('Tmpfs') in (None, {}))):
            return _tmpfs_diagnostic(actual.get('Tmpfs'), expected.get('Tmpfs'))
        for field, code in (
                ('Mounts', 'managed_inspect_requested_mount_mismatch'),
                ('NetworkMode', 'managed_inspect_network_mode_mismatch'),
                ('Init', 'managed_inspect_init_mismatch')):
            if field == 'Mounts':
                from larenor_server.plugins.managed_container import _observed_requested_mounts_match
                if _observed_requested_mounts_match(actual.get(field), expected.get(field)):
                    continue
            if actual.get(field) != expected.get(field):
                return code
        restart = expected.get('RestartPolicy')
        if restart == {'Name': 'no'}:
            restart = {'Name': 'no', 'MaximumRetryCount': 0}
        if actual.get('RestartPolicy') != restart:
            return 'managed_inspect_restart_mismatch'
        if (value.get('Id') is None or value.get('Name') != '/'+payload['name']
                or value.get('Image') != payload['image_id']):
            return 'managed_inspect_identity_mismatch'
        config = value.get('Config')
        inherited = payload['image_configuration']
        if type(config) is not dict or type(inherited) is not dict:
            return 'managed_inspect_config_mismatch'
        desired_env = {item.partition('=')[0]: item for item in inherited.get('Env') or []}
        desired_env.update({item.partition('=')[0]: item for item in body.get('Env') or []})
        desired_labels = {**(inherited.get('Labels') or {}), **body['Labels']}
        if (type(config.get('Env')) is not list
                or sorted(config['Env']) != sorted(desired_env.values())
                or config.get('Labels') != desired_labels
                or config.get('Image') != body.get('Image')
                or config.get('User') != body.get('User')):
            return 'managed_inspect_config_mismatch'
        for key in ('Cmd', 'Entrypoint', 'WorkingDir', 'Volumes', 'Healthcheck',
                    'StopSignal', 'Shell'):
            if (config.get(key) or None) != (inherited.get(key) or None):
                return 'managed_inspect_config_mismatch'
        if any(config.get(key) not in (None, False) for key in ('Tty','OpenStdin','StdinOnce')):
            return 'managed_inspect_config_mismatch'
        from larenor_server.plugins.worker import _FORBIDDEN_OBSERVED
        if not all(actual.get(key) in allowed for key, allowed in _FORBIDDEN_OBSERVED.items()
                   if key != 'Mounts'):
            return 'managed_inspect_forbidden_host_mismatch'
        mounts = value.get('Mounts')
        desired_mounts = {item['target']: item['name'] for item in payload['mounts']}
        if type(mounts) is not list or len(mounts) != len(desired_mounts):
            return 'managed_inspect_observed_mount_mismatch'
        for mount in mounts:
            if (type(mount) is not dict or mount.get('Type') != 'volume'
                    or mount.get('Name') != desired_mounts.get(mount.get('Destination'))
                    or mount.get('Driver') != 'local' or mount.get('RW') is not True):
                return 'managed_inspect_observed_mount_mismatch'
        networks = (value.get('NetworkSettings') or {}).get('Networks')
        network_name = expected.get('NetworkMode')
        if (type(networks) is not dict or set(networks) != {network_name}
                or type(networks[network_name]) is not dict
                or networks[network_name].get('NetworkID') != payload['network_id']):
            return _network_diagnostic(networks, network_name, payload['network_id'])
    except (AttributeError, KeyError, TypeError, ValueError, RecursionError):
        return 'managed_inspect_nonresource_mismatch'
    return 'managed_inspect_nonresource_mismatch'


def _managed_engine(endpoint):
    from larenor_server.plugins.worker import DockerWorkerError, UnixDockerEngine

    class DiagnosticEngine(UnixDockerEngine):
        managed_create_diagnostic = None
        managed_binding = None

        def _exchange(self, method, target, body=None):
            create = method == 'POST' and target.startswith('/containers/create?')
            try:
                response = super()._exchange(method, target, body)
            except DockerWorkerError:
                if create:
                    self.managed_create_diagnostic = 'managed_create_transport_failed'
                raise
            if create:
                self.managed_create_diagnostic = (
                    _managed_create_success_diagnostic(response.body)
                    if response.status == 201
                    else _managed_create_rejection(response.status, response.body)
                )
            return response

        def create_managed_container(self, binding):
            self.managed_binding = binding
            try:
                return super().create_managed_container(binding)
            except DockerWorkerError as error:
                if self.managed_create_diagnostic is None:
                    self.managed_create_diagnostic = {
                        'invalid_binding': 'managed_create_binding_rejected',
                        'engine_protocol': 'managed_create_protocol_failed',
                        'engine_peer_rejected': 'managed_create_endpoint_rejected',
                        'unsafe_worker_path': 'managed_create_endpoint_rejected',
                        'engine_conflict': 'managed_create_resource_conflict',
                    }.get(error.code, 'managed_create_transport_failed')
                raise

        def inspect_container(self, name):
            value = super().inspect_container(name)
            if self.managed_binding is not None and value is not None:
                from larenor_server.plugins.managed_container import managed_container_matches
                if not managed_container_matches(value, self.managed_binding):
                    self.managed_create_diagnostic = _managed_inspect_diagnostic(
                        value, self.managed_binding)
            return value

    return DiagnosticEngine(endpoint.path, socket_uid=endpoint.owner_uid)


def _managed_create_receipt_failure(receipt, diagnostic):
    if diagnostic in _MANAGED_CREATE_DIAGNOSTICS:
        return diagnostic
    try:
        pair = receipt.state, receipt.code
    except (AttributeError, TypeError, RecursionError):
        return 'managed_create_receipt_invalid'
    return {
        ('prepared', 'accepted'): 'managed_create_preflight_failed',
        ('uncertain', 'engine_operation_uncertain'): 'managed_create_uncertain',
        ('needs_attention', 'resource_conflict'): 'managed_create_resource_conflict',
        ('needs_attention', 'dispatch_expired'): 'managed_create_expired',
    }.get(pair, 'managed_create_receipt_invalid')


def _managed_create_succeeded(receipt):
    try:
        return (receipt.state == 'succeeded'
                and receipt.code == 'container_created'
                and _CONTAINER_ID.fullmatch(receipt.container_id or '') is not None)
    except (AttributeError, TypeError, RecursionError):
        return False


def _managed_create_and_start(daemon, source, endpoint, helper_id):
    """Create/start through the production proof, binding and v2 journal path."""
    from larenor_server.plugins.managed_container import (
        JellyfinBindingBuilder, JellyfinEngineReaders, JellyfinResourceProofBroker,
        JournaledManagedContainerOperations, ManagedWorkerJournal,
        managed_container_matches,
    )
    from larenor_server.plugins.resource_journal import ResourceJournal
    from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
    from larenor_server.plugins.worker import WorkerStep

    journal_dir = daemon.root / 'managed-container-journal'
    with ResourceJournal(daemon.root / 'resource-journal') as resource_journal, \
            VolumeCreateJournal(daemon.root / 'volume-journal') as volume_journal, \
            ManagedWorkerJournal(journal_dir, initialize=True) as container_journal:
        verifier = _BootstrapVerifier(endpoint, daemon, helper_id)
        readers = JellyfinEngineReaders(endpoint, verifier)
        broker = JellyfinResourceProofBroker(
            source.stack, source.catalog, source.policy, resource_journal,
            volume_journal, readers, engine_identity=endpoint,
        )
        binding = JellyfinBindingBuilder(
            source.catalog, source.policy, container_journal.identity, broker,
        )(source.stack)
        engine = _managed_engine(endpoint)
        operations = JournaledManagedContainerOperations(container_journal, engine)
        job_id = uuid.uuid4().hex
        installation_id = binding.name.removeprefix('larenor-')
        create = operations.apply(WorkerStep(
            job_id, installation_id, 'create_container',
            uuid.uuid4().hex, time.time() + 30,
        ), binding)
        if not _managed_create_succeeded(create):
            raise SmokeError(_managed_create_receipt_failure(
                create, engine.managed_create_diagnostic,
            ))
        created = engine.inspect_container(create.container_id)
        require(managed_container_matches(created, binding))
        start = operations.apply(WorkerStep(
            job_id, installation_id, 'start_container',
            uuid.uuid4().hex, time.time() + 30,
        ), binding)
        require(start.state == 'succeeded' and start.code == 'container_started'
                and start.container_id == create.container_id)
        running = engine.inspect_container(start.container_id)
        require(managed_container_matches(running, binding)
                and running.get('State', {}).get('Running') is True)
        host = binding.payload()['specification']['HostConfig']
        daemon.verify_container_resources(running.get('State', {}).get('Pid'),
            host['Memory'], host['NanoCpus'], host['PidsLimit'])
        return start.container_id, binding, engine


@diagnostic_phase('characterization')
def characterize(daemon, *, source=None, images=None, volumes=None, checkout_binding=None,
                 managed=False):
    """The real consumer: two volumes, bootstrap, NoCopy/start/restart or fail.

    Optional objects are private offline-test seams, not CLI/runtime inputs.
    A new context never replays another daemon's state; cleanup is whole owned
    namespace shutdown, never Docker prune or removal of externally named data.
    """
    from larenor_server.plugins.docker_probe import DockerEndpoint
    from larenor_server.plugins.image_resources import UnixImageEngine, image_binding
    from larenor_server.plugins.volume_effects import UnixVolumeCreator
    checkout_binding = capture_source(os.environ['GITHUB_SHA']) if checkout_binding is None else checkout_binding
    check_source(checkout_binding)
    source = fixture_source(daemon.platform) if source is None else source
    endpoint = DockerEndpoint(str(daemon.root/'engine.sock'), owner_uid=0)
    images = UnixImageEngine(endpoint) if images is None else images
    volumes = UnixVolumeCreator(endpoint) if volumes is None else volumes
    require(type(managed) is bool)
    if managed:
        from larenor_server.plugins.network_effects import UnixNetworkCreator
        from larenor_server.plugins.network_transport import UnixNetworkEngine
        from tool.media_resource_smoke import characterize_resources
        characterize_resources(
            daemon.root, source, images, UnixNetworkEngine(endpoint),
            UnixNetworkCreator(endpoint),
        )
    receipt = prepare_storage(daemon.root, source, images, volumes)
    with diagnostic_phase('image_inspect'):
        binding = image_binding(source.plan, source.stack, source.catalog, source.policy, source.image.resourceId)
        observed = images.inspect(binding)
        require(observed is not None and observed.image_id == binding.config_digest)
        image_config = _decoded(observed.configuration)
        require(type(image_config) is dict and set(image_config.get('Volumes') or {}) <= {'/config','/cache'},
                'unexpected_image_volume')
    iid_file = daemon.root/'helper.iid'
    with diagnostic_phase('helper_stage'):
        context = stage_context(daemon.root, checkout_binding)
    commit, hashes = checkout_binding
    labels = source_labels(commit, dict(hashes))
    _helper_base(daemon, context, checkout_binding)
    with diagnostic_phase('helper_build'):
        daemon.docker(['build','--pull','--quiet','--network=none',
            *['--label='+key+'='+value for key,value in labels.items()], '--file',
            str(context/'server/Dockerfile.volume-bootstrap'),'--iidfile',str(iid_file),str(context)],
            timeout=600, limit=256, diagnose_failure=True)
    with diagnostic_phase('helper_inspect'):
        check_source(checkout_binding)
        check_staged(context, checkout_binding)
        helper_id = iid_file.read_text().strip()
        require(_HASH.fullmatch(helper_id) is not None)
        inspected = _decoded(daemon.docker(['image','inspect','--format','{{json .}}',helper_id], limit=65536))
        attestation = helper_attestation(helper_id, inspected, daemon.platform, commit, expected_hashes=hashes)
    with diagnostic_phase('helper_seed'):
        require(_helper(daemon, helper_id, 'image_seed') == {'imageSeed':True})
    for target in source.targets:
        # A real negative oracle, not an invented RED: if it is writable already,
        # this candidate's rootful/empty ownership assumption must be reviewed.
        with diagnostic_phase('initial_permissions'):
            require(_helper(daemon, helper_id, 'writable', target=target)
                == {'writable':False,'uid':1000,'gid':1000}, 'unexpected_initial_write_access')
        with diagnostic_phase('bootstrap_check'):
            require(_helper(daemon, helper_id, 'check', target=target, bootstrap=True)
                == {'schemaVersion':1,'state':'empty_uninitialized'})
        with diagnostic_phase('bootstrap_initialize'):
            require(_helper(daemon, helper_id, 'initialize_empty_root', target=target, bootstrap=True)
                == {'schemaVersion':1,'state':'empty_initialized'})
        with diagnostic_phase('initialized_permissions'):
            require(_helper(daemon, helper_id, 'writable', target=target)
                == {'writable':True,'uid':1000,'gid':1000})
        with diagnostic_phase('sentinel_write'):
            require(_helper(daemon, helper_id, 'write_sentinel', target=target)
                == {'sentinel':'verified','uid':1000,'gid':1000})
    managed_binding = managed_engine = None
    with diagnostic_phase('container_create'):
        if managed:
            container_id, managed_binding, managed_engine = _managed_create_and_start(
                daemon, source, endpoint, helper_id,
            )
        else:
            name = 'larenor-jellyfin-'+source.stack.preparationId
            args = ['create','--name='+name,'--network=none','--read-only','--cap-drop=ALL',
                '--security-opt=no-new-privileges','--user=1000:1000','--memory=4g','--cpus=2',
                '--cgroup-parent='+daemon.container_cgroup_parent,
                '--pids-limit=512','--restart=no','--tmpfs=/tmp:rw,nosuid,nodev,size=67108864','--env=TZ=UTC']
            args += ['--mount=type=volume,src='+v.name+',dst='+v.target+',volume-nocopy' for v in source.targets]
            container_id = daemon.docker(args+[binding.reference], limit=128).decode().strip()
            require(re.fullmatch(r'[0-9a-f]{64}', container_id) is not None)
    @diagnostic_phase('container_inspect')
    def inspect():
        if managed:
            from larenor_server.plugins.managed_container import managed_container_matches
            value = managed_engine.inspect_container(container_id)
            require(value.get('Id') == container_id
                    and managed_container_matches(value, managed_binding))
        else:
            value = _decoded(daemon.docker(['container','inspect','--format','{{json .}}',container_id], limit=262144))
            require(value.get('Id') == container_id)
            verify_container(value, source, image_config, daemon.container_cgroup_parent)
        return value
    inspect()
    with diagnostic_phase('container_start'):
        if not managed:
            daemon.docker(['start',container_id], limit=128)
        running = inspect()
        if managed:
            host = managed_binding.payload()['specification']['HostConfig']
            daemon.verify_container_resources(running.get('State',{}).get('Pid'),
                host['Memory'], host['NanoCpus'], host['PidsLimit'])
        else:
            daemon.verify_container_cgroup(running.get('State',{}).get('Pid'))
    with diagnostic_phase('initial_health'):
        first = _health(daemon, helper_id, container_id)
    with diagnostic_phase('initial_identity'):
        require(_helper(daemon, helper_id, 'app_identity', network='container:'+container_id)
                == {'uid':1000,'gid':1000})
    config_target = next(v for v in source.targets if v.target == '/config')
    with diagnostic_phase('initial_data'):
        require(_helper(daemon, helper_id, 'initial_data', target=config_target)
                == {'database':True,'configuration':True})
    with diagnostic_phase('container_restart'):
        daemon.docker(['restart','--time=10',container_id], timeout=30, limit=128)
    with diagnostic_phase('restart_health'):
        second = _health(daemon, helper_id, container_id)
        require(second == first, 'restart_identity_changed')
    with diagnostic_phase('restart_identity'):
        require(_helper(daemon, helper_id, 'app_identity', network='container:'+container_id)
                == {'uid':1000,'gid':1000})
    running = inspect()
    if managed:
        host = managed_binding.payload()['specification']['HostConfig']
        daemon.verify_container_resources(running.get('State',{}).get('Pid'),
            host['Memory'], host['NanoCpus'], host['PidsLimit'])
    else:
        daemon.verify_container_cgroup(running.get('State',{}).get('Pid'))
    for target in source.targets:
        with diagnostic_phase('root_verify'):
            require(_helper(daemon, helper_id, 'verify_root', target=target, bootstrap=True)
                    == {'schemaVersion':1,'state':'root_verified'})
        with diagnostic_phase('sentinel_verify'):
            require(_helper(daemon, helper_id, 'verify_sentinel', target=target)
                    == {'sentinel':'verified','uid':1000,'gid':1000})
    with diagnostic_phase('restart_data'):
        require(_helper(daemon, helper_id, 'initial_data', target=config_target)
                == {'database':True,'configuration':True})
    with diagnostic_phase('source_recheck'):
        check_source(checkout_binding)
        check_staged(context, checkout_binding)
    return {'schemaVersion':1,'result':'characterized','platform':daemon.platform,
        'catalogDigest':source.catalog.digest,'jellyfinManifestDigest':source.image.image.digest,
        'jellyfinConfigDigest':binding.config_digest,'helper':attestation,
        'volumeCount':2,'restartCount':1,'serverId':first['id'],
        **({'containerMode':'journaled_managed_v2','containerJournalVersion':2}
           if managed else {}),
        'bootstrapAccountConfigured':False,'installAvailable':False, **receipt}


def main(arguments=None):
    args = sys.argv[1:] if arguments is None else arguments
    if args != ['--run-ephemeral-ci']:
        print('explicit_ephemeral_ci_flag_required', file=sys.stderr)
        return 2
    try:
        checkout_binding = capture_source(os.environ.get('GITHUB_SHA',''))
        with EphemeralDaemon() as daemon:
            result = characterize(daemon, checkout_binding=checkout_binding)
        print(json.dumps(result, sort_keys=True, separators=(',', ':')))
        return 0
    except SmokeError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print('storage_characterization_failed', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
