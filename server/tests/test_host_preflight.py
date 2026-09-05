"""Read-only preflight against temporary directories and injected host facts."""

from dataclasses import replace
import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest

from larenor_server.plugins.catalog import load_catalog, plan
from larenor_server.plugins.host_preflight import HostInspector, HostPolicy, HostRoot, HostPreflightError


NOW = 1788609600.125


def selected(service='jellyfin', settings=None, platform='linux/amd64'):
    entry = next(item for item in load_catalog().entries if item.manifest.serviceId == service)
    return plan(entry, settings or {}, platform)


def space(mib=16384, *, available=None, fragment=1048576):
    return SimpleNamespace(f_bavail=mib if available is None else available, f_frsize=fragment, f_flag=0)


@pytest.fixture
def roots(tmp_path):
    result = {}
    for identity, purpose in [('appdata', 'data'), ('library', 'library'), ('media', 'media'), ('music', 'music')]:
        directory = tmp_path / identity
        directory.mkdir(mode=0o700)
        result[identity] = HostRoot(str(directory), purpose)
    return result


def inspector(roots, **kwargs):
    return HostInspector(HostPolicy(roots), platform_provider=lambda: 'linux/amd64',
                         clock=lambda: NOW, statvfs_provider=lambda fd: space(), **kwargs)


def checks(result, code):
    return [item for item in result.checks if item.code == code]


def test_readonly_preflight_binds_result_and_does_not_claim_install_readiness(roots):
    request = selected()
    result = inspector(roots).inspect(request)
    assert (result.catalogDigest, result.planHash, result.platform) == (request.catalogDigest, request.planHash, request.image.platform)
    assert result.checkedAt == '2026-09-05T12:00:00.125Z'
    assert checks(result, 'platform')[0].status == 'passed'
    assert [(c.rootId, c.status) for c in checks(result, 'storage_root')] == [('appdata', 'passed')]
    assert [(c.availableMiB, c.requiredMiB, c.status) for c in checks(result, 'storage_capacity')] == [(16384, 8192, 'passed')]
    for code in ('docker_engine', 'port_availability', 'receiver_network'):
        assert checks(result, code)[0].status == 'unknown'
    assert not request.installable
    public = result.model_dump_json()
    for root in roots.values():
        assert root.path not in public and root.path not in repr(root)


@pytest.mark.parametrize('service', ['jellyfin', 'seerr', 'sonarr', 'radarr', 'qbittorrent', 'music_assistant'])
def test_each_packaged_component_is_inspected_without_enabling_install(roots, service):
    result = inspector(roots).inspect(selected(service))
    assert all(c.status == 'passed' for c in checks(result, 'storage_root'))
    # All roots are on the same actual temporary filesystem, even config/cache
    # or the shared writable library. Charge the plan budget once for that fs.
    assert len(checks(result, 'storage_capacity')) == 1
    assert checks(result, 'storage_capacity')[0].requiredMiB == 8192
    assert checks(result, 'receiver_network')[0].status == 'unknown'


def test_same_filesystem_free_space_is_never_summed_across_roots(roots):
    instance = HostInspector(HostPolicy(roots), platform_provider=lambda: 'linux/amd64', clock=lambda: NOW,
                             statvfs_provider=lambda fd: space(5000))
    result = instance.inspect(selected('sonarr'))
    assert [(c.availableMiB, c.requiredMiB, c.status) for c in checks(result, 'storage_capacity')] == [(5000, 8192, 'failed')]


@pytest.mark.parametrize('root_id,purpose', [('appdata', 'library'), ('library', 'data'), ('media', 'music'), ('music', 'media')])
def test_root_purpose_is_bound_to_the_catalog_setting(roots, root_id, purpose):
    roots[root_id] = replace(roots[root_id], purpose=purpose)
    service, settings = ('sonarr', {}) if root_id == 'library' else ('jellyfin', {'mediaRootId': 'media'}) if root_id == 'media' else ('music_assistant', {'musicRootId': 'music'}) if root_id == 'music' else ('jellyfin', {})
    result = inspector(roots).inspect(selected(service, settings))
    assert next(c for c in checks(result, 'storage_root') if c.rootId == root_id).status == 'failed'


def test_missing_unknown_and_non_directory_roots_fail_without_path_disclosure(roots, tmp_path):
    for value in (HostRoot(str(tmp_path / 'missing'), 'data'), HostRoot(str(tmp_path / 'file'), 'data'), None):
        (tmp_path / 'file').write_text('private-secret')
        policy = dict(roots)
        if value is None:
            del policy['appdata']
        else:
            policy['appdata'] = value
        result = inspector(policy).inspect(selected())
        assert checks(result, 'storage_root')[0].status == 'failed'
        assert str(tmp_path) not in result.model_dump_json()
        assert 'private-secret' not in repr(result)


@pytest.mark.parametrize('location', ['root', 'ancestor', 'child'])
def test_symlinks_in_root_or_existing_managed_subtree_fail(roots, tmp_path, location):
    original = Path(roots['appdata'].path)
    if location == 'root':
        link = tmp_path / 'link'
        link.symlink_to(original, target_is_directory=True)
        roots['appdata'] = HostRoot(str(link), 'data')
    elif location == 'ancestor':
        link = tmp_path / 'link'
        link.symlink_to(tmp_path, target_is_directory=True)
        roots['appdata'] = HostRoot(str(link / 'appdata'), 'data')
    else:
        (original / 'jellyfin').symlink_to(tmp_path / 'media', target_is_directory=True)
    result = inspector(roots).inspect(selected())
    assert checks(result, 'storage_root')[0].status == 'failed'


@pytest.mark.parametrize('location', ['root', 'ancestor', 'child'])
def test_foreign_writable_directories_fail(roots, tmp_path, location):
    root = Path(roots['appdata'].path)
    if location == 'root':
        root.chmod(0o777)
    elif location == 'ancestor':
        tmp_path.chmod(0o777)
    else:
        (root / 'jellyfin').mkdir(mode=0o777)
        (root / 'jellyfin').chmod(0o777)
    try:
        result = inspector(roots).inspect(selected())
        assert checks(result, 'storage_root')[0].status == 'failed'
    finally:
        tmp_path.chmod(0o700)


def test_missing_managed_subdirectories_are_not_created(roots):
    base = Path(roots['appdata'].path)
    assert not list(base.iterdir())
    assert checks(inspector(roots).inspect(selected()), 'storage_root')[0].status == 'passed'
    assert not list(base.iterdir())


@pytest.mark.parametrize('host', ['linux/arm64', None, 'darwin/arm64', 'windows/amd64'])
def test_wrong_or_unsupported_host_platform_fails(roots, host):
    instance = HostInspector(HostPolicy(roots), platform_provider=lambda: host, clock=lambda: NOW)
    result = instance.inspect(selected())
    assert result.platform == 'linux/amd64'
    assert checks(result, 'platform')[0].status == 'failed'


@pytest.mark.parametrize('changed', [{'installable': True}, {'planHash': '0' * 64}, {'ports': ()}, {'mounts': ()}])
def test_tampered_plan_is_rejected_before_host_observation(roots, changed):
    calls = []
    instance = HostInspector(HostPolicy(roots), platform_provider=lambda: calls.append('platform'))
    with pytest.raises(HostPreflightError, match='^plan_untrusted$'):
        instance.inspect(selected('sonarr').model_copy(update=changed))
    assert calls == []


@pytest.mark.parametrize('available,fragment', [(-1, 1048576), (True, 1048576), (1, 0), (1, -1), (1, True), (2**80, 2**80)])
def test_invalid_statvfs_values_fail_without_claiming_capacity(roots, available, fragment):
    instance = HostInspector(HostPolicy(roots), platform_provider=lambda: 'linux/amd64', clock=lambda: NOW,
                             statvfs_provider=lambda fd: space(available=available, fragment=fragment))
    result = instance.inspect(selected())
    assert checks(result, 'storage_capacity')[0].status == 'failed'
    assert checks(result, 'storage_capacity')[0].availableMiB is None


def test_observation_error_is_static_and_does_not_expose_exception_text(roots):
    def unavailable(fd):
        raise OSError('private-path-or-secret')
    instance = HostInspector(HostPolicy(roots), platform_provider=lambda: 'linux/amd64', clock=lambda: NOW,
                             statvfs_provider=unavailable)
    result = instance.inspect(selected())
    assert checks(result, 'storage_capacity')[0].status == 'unknown'
    assert 'private-path-or-secret' not in result.model_dump_json()


@pytest.mark.parametrize('path,purpose', [('relative', 'data'), ('/a/../b', 'data'), ('/a/./b', 'data'), ('/a', 'unknown'), ('/', 'data'), ('/a\x00b', 'data')])
def test_policy_rejects_unbounded_or_unsafe_paths(path, purpose):
    with pytest.raises(HostPreflightError, match='^invalid_policy$'):
        HostPolicy({'appdata': HostRoot(path, purpose)})


def test_policy_is_copied_and_rejects_unknown_id_and_excess_entries(roots):
    policy = HostPolicy(roots)
    roots.clear()
    assert len(policy.roots) == 4
    for values in ({'../secret': next(iter(policy.roots.values()))}, {f'root{i}': next(iter(policy.roots.values())) for i in range(17)}):
        with pytest.raises(HostPreflightError, match='^invalid_policy$'):
            HostPolicy(values)
