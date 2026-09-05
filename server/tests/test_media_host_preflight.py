"""One stack budget, stable observed paths and no installation/network effects."""

from dataclasses import replace
import os
from pathlib import Path
import time
from types import SimpleNamespace

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.host_preflight import HostInspector, HostPolicy, HostRoot, HostPreflightError
from larenor_server.plugins.preflight_models import PreflightCheck
from larenor_server.plugins.stack_plan import build_media_stack_plan


def stack(**settings):
    return build_media_stack_plan(load_catalog(), settings, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a'*32, homeId='b'*32), 'c'*32)


@pytest.fixture
def roots(tmp_path):
    result = {}
    for identity, purpose in [('appdata', 'data'), ('library', 'library'), ('music', 'music')]:
        path = tmp_path / identity
        path.mkdir(mode=0o700)
        result[identity] = HostRoot(str(path), purpose)
    return result


def volume(amount):
    return SimpleNamespace(f_bavail=amount, f_frsize=1048576, f_flag=0)


def inspector(roots, amount=65536, **kwargs):
    return HostInspector(HostPolicy(roots), platform_provider=lambda: 'linux/amd64',
        statvfs_provider=lambda _: volume(amount), **kwargs)


def checks(result, code):
    return [item for item in result.checks if item.code == code]


@pytest.mark.parametrize('amount,status', [(16384, 'failed'), (49151, 'failed'), (49152, 'passed'), (65536, 'passed')])
def test_stack_charges_every_component_once_on_a_shared_filesystem(roots, amount, status):
    selected = stack(musicRootId='music')
    host = inspector(roots, amount)
    # Individual child success is insufficient for the full stack.
    assert all(checks(host.inspect(c.plan), 'storage_capacity')[0].status == 'passed'
               for c in selected.components)
    result = host.inspect_stack(selected)
    assert (result.catalogDigest, result.planHash, result.platform) == (
        selected.catalogDigest, selected.planHash, selected.platform)
    assert [(c.requiredMiB, c.availableMiB, c.status) for c in checks(result, 'storage_capacity')] == [
        (49152, amount, status)]
    assert all(c.status == 'passed' for c in checks(result, 'storage_root'))
    for code in ('docker_engine', 'daemon_mount_context', 'daemon_network_context',
                 'daemon_root_context', 'port_availability', 'receiver_network'):
        assert [c.status for c in checks(result, code)] == ['unknown']
    assert selected.installAvailable is False
    assert all(not list(Path(root.path).iterdir()) for root in roots.values())
    assert all(root.path not in result.model_dump_json() for root in roots.values())


def test_budget_is_aggregated_per_distinct_writable_filesystem_not_root_alias(roots):
    original = os.fstat
    identities = {Path(root.path).stat().st_ino: identity for identity, root in roots.items()}
    def observe(fd):
        actual = original(fd)
        values = list(actual)
        if actual.st_ino in identities:
            values[2] = {'appdata': 10, 'library': 20, 'music': 30}[identities[actual.st_ino]]
        return os.stat_result(values)
    result = inspector(roots, stat_provider=observe).inspect_stack(stack(musicRootId='music'))
    assert [(c.rootId, c.requiredMiB) for c in checks(result, 'storage_capacity')] == [
        ('appdata', 49152), ('library', 24576)]
    # Music and Jellyfin's media views are read-only, never extra write budgets.
    assert 'music' not in {c.rootId for c in checks(result, 'storage_capacity')}


def test_aliases_do_not_multiply_available_space(roots):
    roots['library'] = replace(roots['library'], path=roots['appdata'].path)
    result = inspector(roots, 30000).inspect_stack(stack())
    assert [(c.availableMiB, c.requiredMiB, c.status) for c in checks(result, 'storage_capacity')] == [
        (30000, 49152, 'failed')]


def test_missing_root_cannot_contribute_capacity(roots):
    del roots['appdata']
    result = inspector(roots).inspect_stack(stack())
    assert next(c for c in checks(result, 'storage_root') if c.rootId == 'appdata').status == 'failed'
    unknown = next(c for c in checks(result, 'storage_capacity') if c.rootId == 'appdata')
    assert (unknown.status, unknown.availableMiB, unknown.requiredMiB) == ('unknown', None, 49152)


@pytest.mark.parametrize('method', ['inspect', 'inspect_stack'])
def test_directory_replacement_during_measurement_invalidates_local_capacity(roots, method):
    path = Path(roots['appdata'].path)
    moved = path.with_name('previous')
    def observe(_fd):
        if not moved.exists():
            path.rename(moved)
            path.mkdir(mode=0o700)
        return volume(65536)
    host = HostInspector(HostPolicy(roots), platform_provider=lambda: 'linux/amd64', statvfs_provider=observe)
    selected = stack()
    result = getattr(host, method)(selected if method == 'inspect_stack' else selected.components[0].plan)
    assert next(c for c in checks(result, 'storage_root') if c.rootId == 'appdata').status == 'failed'
    assert next(c for c in checks(result, 'storage_capacity') if c.rootId == 'appdata').status == 'unknown'


def test_untrusted_stack_or_expired_deadline_never_observes_paths(roots):
    calls = []
    host = HostInspector(HostPolicy(roots), platform_provider=lambda: calls.append('platform'))
    selected = stack()
    with pytest.raises(HostPreflightError, match='plan_untrusted'):
        host.inspect_stack(selected.model_copy(update={'planHash': 'f'*64}))
    with pytest.raises(HostPreflightError, match='inspection_unavailable'):
        host.inspect_stack(selected, deadline=time.monotonic()-1)
    assert calls == []


@pytest.mark.parametrize('code', ['daemon_mount_context', 'daemon_network_context', 'daemon_root_context'])
def test_context_checks_are_bounded_observations_without_private_identifiers(code):
    check = PreflightCheck(code=code, status='unknown')
    assert check.rootId is check.availableMiB is check.requiredMiB is None
    for extra in ({'rootId': 'appdata'}, {'availableMiB': 1}, {'requiredMiB': 1}):
        with pytest.raises(ValueError):
            PreflightCheck(code=code, status='passed', **extra)


def test_failed_storage_callback_is_not_retried_or_accepted(roots, monkeypatch):
    from larenor_server.plugins.docker_probe import DockerEndpoint
    calls = []
    class Probe:
        def __init__(self, endpoint):
            pass
        def observe(self, platform, *, during, deadline):
            return during()
    monkeypatch.setattr('larenor_server.plugins.host_preflight.DockerProbe', Probe)
    host = HostInspector(HostPolicy(roots, docker=DockerEndpoint('/run/docker.sock', daemon_executable='/usr/bin/dockerd')),
        platform_provider=lambda: 'linux/amd64')
    def storage(*args):
        calls.append('storage')
        if len(calls) == 1:
            raise OSError('private observation failed')
        return []
    monkeypatch.setattr(host, '_storage', storage)
    with pytest.raises(HostPreflightError, match='inspection_unavailable'):
        host.inspect_stack(stack())
    assert calls == ['storage']


@pytest.mark.parametrize('context,expected', [
    ((True, True, True), ['passed']*3),
    ((False, True, False), ['failed', 'passed', 'failed']),
    (None, ['unknown']*3),
])
def test_configured_daemon_context_is_separate_from_worker_local_storage(roots, monkeypatch, context, expected):
    from larenor_server.plugins.docker_probe import DockerEndpoint, DockerObservation
    from larenor_server.plugins.daemon_context import DaemonContext
    calls = []
    class Probe:
        def __init__(self, endpoint):
            pass
        def observe(self, platform, *, during, deadline):
            calls.append(during())
            return DockerObservation('passed', None if context is None else DaemonContext(*context), calls[-1])
    monkeypatch.setattr('larenor_server.plugins.host_preflight.DockerProbe', Probe)
    host = HostInspector(HostPolicy(roots, docker=DockerEndpoint('/run/docker.sock', daemon_executable='/usr/bin/dockerd')),
        platform_provider=lambda: 'linux/amd64', statvfs_provider=lambda _: volume(65536))
    result = host.inspect_stack(stack())
    assert len(calls) == 1
    assert checks(result, 'docker_engine')[0].status == 'passed'
    assert checks(result, 'storage_capacity')[0].status == 'passed'
    assert [checks(result, c)[0].status for c in ('daemon_mount_context', 'daemon_network_context', 'daemon_root_context')] == expected
    assert checks(result, 'port_availability')[0].status == 'unknown'


def test_extended_caller_deadline_does_not_extend_worker_inspection_budget(roots, monkeypatch):
    monkeypatch.setattr('larenor_server.plugins.host_preflight.time.monotonic', lambda: 100.0)
    host = inspector(roots)
    received = []
    monkeypatch.setattr(host, '_storage', lambda plans, deadline: received.append(deadline) or [])
    host.inspect_stack(stack(), deadline=1000.0)
    assert received == [105.0]


def test_legacy_docker_policy_shares_incoming_deadline_and_storage_observation(roots, monkeypatch):
    from larenor_server.plugins.docker_probe import DockerEndpoint, DockerObservation
    calls = []
    monkeypatch.setattr('larenor_server.plugins.host_preflight.time.monotonic', lambda: 100.0)
    class Probe:
        def __init__(self, endpoint):
            assert endpoint.daemon_executable is None
        def inspect(self, platform):
            raise AssertionError('unbudgeted inspection')
        def observe(self, platform, *, during, deadline):
            calls.append((platform, deadline, during()))
            return DockerObservation('passed', None, calls[-1][2])
    monkeypatch.setattr('larenor_server.plugins.host_preflight.DockerProbe', Probe)
    host = HostInspector(HostPolicy(roots, docker=DockerEndpoint('/run/docker.sock')),
        platform_provider=lambda: 'linux/amd64', statvfs_provider=lambda _: volume(65536))
    result = host.inspect_stack(stack(), deadline=100.05)
    assert len(calls) == 1 and calls[0][:2] == ('linux/amd64', 100.05)
    assert checks(result, 'docker_engine')[0].status == 'passed'
    assert checks(result, 'daemon_mount_context')[0].status == 'unknown'
