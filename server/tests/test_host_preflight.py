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


def test_unified_stack_jellyfin_can_observe_the_approved_library_readonly(roots):
    from larenor_server.context import ContextResponse
    from larenor_server.plugins.stack_plan import build_media_stack_plan
    stack = build_media_stack_plan(load_catalog(), {}, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    request = next(component.plan for component in stack.components if component.serviceId == 'jellyfin')
    media = next(mount for mount in request.mounts if mount.target == '/media')
    assert media.rootId == 'library' and media.readOnly and media.kind == 'approved_library'
    result = inspector(roots).inspect(request)
    assert [(check.rootId, check.status) for check in checks(result, 'storage_root')] == [
        ('appdata', 'passed'), ('library', 'passed')]
    # Read-only media is not another writable capacity charge or a new folder.
    assert len(checks(result, 'storage_capacity')) == 1
    assert checks(result, 'storage_capacity')[0].rootId == 'appdata'
    assert all(not list(Path(root.path).iterdir()) for root in roots.values())
    assert checks(result, 'docker_engine')[0].status == checks(result, 'receiver_network')[0].status == 'unknown'
    assert stack.installAvailable is False and request.installable is False


@pytest.mark.parametrize('service,settings,rejected_root', [
    ('jellyfin', {'dataRootId': 'library'}, 'library'),
    ('jellyfin', {'dataRootId': 'library', 'mediaRootId': 'library'}, 'library'),
    ('jellyfin', {'mediaRootId': 'music'}, 'music'),
    ('jellyfin', {'mediaRootId': 'appdata'}, 'appdata'),
    ('music_assistant', {'musicRootId': 'library'}, 'library'),
    ('sonarr', {'libraryRootId': 'media'}, 'media'),
    ('radarr', {'libraryRootId': 'media'}, 'media'),
    ('qbittorrent', {'libraryRootId': 'media'}, 'media'),
])
def test_jellyfin_library_view_does_not_broaden_other_service_or_purpose_authority(roots, service, settings, rejected_root):
    result = inspector(roots).inspect(selected(service, settings))
    assert next(check for check in checks(result, 'storage_root') if check.rootId == rejected_root).status == 'failed'


@pytest.mark.parametrize('changed', [{'readOnly': False}, {'target': '/data'}, {'relativePath': 'other/config'}])
def test_forged_shared_library_view_never_reaches_host_observation(roots, changed):
    request = selected('jellyfin', {'mediaRootId': 'library'})
    mounts = tuple(mount.model_copy(update=changed) if mount.target == '/media' else mount for mount in request.mounts)
    calls = []
    instance = HostInspector(HostPolicy(roots), platform_provider=lambda: calls.append('platform'))
    with pytest.raises(HostPreflightError, match='^plan_untrusted$'):
        instance.inspect(request.model_copy(update={'mounts': mounts}))
    assert calls == []


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


def test_distinct_writable_filesystems_each_need_catalog_budget(roots):
    data_inode = Path(roots['appdata'].path).stat().st_ino
    library_inode = Path(roots['library'].path).stat().st_ino
    def metadata(fd):
        original = os.fstat(fd)
        if original.st_ino == library_inode:
            values = list(original)
            values[2] += 1000000  # trusted seam: a distinct mounted filesystem
            return os.stat_result(values)
        return original
    instance = HostInspector(HostPolicy(roots), platform_provider=lambda: 'linux/amd64', clock=lambda: NOW,
                             stat_provider=metadata,
                             statvfs_provider=lambda fd: space(5000 if os.fstat(fd).st_ino == data_inode else 9000))
    result = instance.inspect(selected('sonarr'))
    assert [(c.rootId, c.requiredMiB, c.availableMiB, c.status) for c in checks(result, 'storage_capacity')] == [
        ('appdata', 8192, 5000, 'failed'), ('library', 8192, 9000, 'passed')]


def test_foreign_owner_and_managed_mount_escape_fail(roots):
    child = Path(roots['appdata'].path) / 'jellyfin'
    child.mkdir(mode=0o700)
    inode = child.stat().st_ino
    for column in (2, 4):  # stat tuple device or uid
        def metadata(fd):
            original = os.fstat(fd)
            if original.st_ino == inode:
                values = list(original)
                values[column] += 1000000
                return os.stat_result(values)
            return original
        instance = HostInspector(HostPolicy(roots), platform_provider=lambda: 'linux/amd64', clock=lambda: NOW,
                                 stat_provider=metadata)
        result = instance.inspect(selected())
        assert checks(result, 'storage_root')[0].status == 'failed'


def test_existing_private_managed_children_pass_without_changes(roots):
    base = Path(roots['appdata'].path)
    for name in ('config', 'cache'):
        (base / 'jellyfin' / name).mkdir(parents=True, mode=0o700)
    assert checks(inspector(roots).inspect(selected()), 'storage_root')[0].status == 'passed'
    assert sorted(path.name for path in (base / 'jellyfin').iterdir()) == ['cache', 'config']


def test_readonly_media_root_does_not_receive_writable_budget(roots):
    result = inspector(roots).inspect(selected('jellyfin', {'mediaRootId': 'media'}))
    assert [(c.rootId, c.status) for c in checks(result, 'storage_root')] == [('appdata', 'passed'), ('media', 'passed')]
    assert [c.rootId for c in checks(result, 'storage_capacity')] == ['appdata']


def test_readonly_filesystem_cannot_pass_writable_capacity(roots):
    value = space()
    value.f_flag = os.ST_RDONLY
    instance = HostInspector(HostPolicy(roots), platform_provider=lambda: 'linux/amd64', clock=lambda: NOW,
                             statvfs_provider=lambda fd: value)
    assert checks(instance.inspect(selected()), 'storage_capacity')[0].status == 'failed'


@pytest.mark.parametrize('system,machine,expected', [('Linux', 'x86_64', 'passed'), ('Linux', 'amd64', 'passed'),
    ('Linux', 'aarch64', 'failed'), ('Linux', 'arm64', 'failed'), ('Darwin', 'x86_64', 'failed'), ('Linux', 'riscv64', 'failed')])
def test_default_platform_discovery_is_linux_and_architecture_specific(roots, monkeypatch, system, machine, expected):
    import larenor_server.plugins.host_preflight as module
    monkeypatch.setattr(module.platform, 'system', lambda: system)
    monkeypatch.setattr(module.platform, 'machine', lambda: machine)
    instance = HostInspector(HostPolicy(roots), clock=lambda: NOW)
    assert checks(instance.inspect(selected()), 'platform')[0].status == expected


def test_arm64_plan_passes_only_on_matching_host(roots):
    instance = HostInspector(HostPolicy(roots), platform_provider=lambda: 'linux/arm64', clock=lambda: NOW)
    assert checks(instance.inspect(selected(platform='linux/arm64')), 'platform')[0].status == 'passed'


@pytest.mark.parametrize('clock', [lambda: float('nan'), lambda: True, lambda: 'private-secret', lambda: 10**20])
def test_clock_errors_are_static_and_have_no_raw_context(roots, clock):
    instance = HostInspector(HostPolicy(roots), clock=clock)
    with pytest.raises(HostPreflightError, match='^inspection_unavailable$') as error:
        instance.inspect(selected())
    assert error.value.__context__ is None


def test_bad_policy_owner_or_provider_is_rejected(roots):
    for uid in (True, -1, 'private-secret'):
        with pytest.raises(HostPreflightError, match='^invalid_policy$'):
            HostPolicy(roots, owner_uid=uid)
    with pytest.raises(HostPreflightError, match='^invalid_policy$'):
        HostInspector(roots)
    with pytest.raises(HostPreflightError, match='^invalid_policy$'):
        HostInspector(HostPolicy(roots), clock='private-secret')


def test_inspection_opens_directories_readonly_and_never_mutates_or_networks(roots, monkeypatch):
    import socket
    import subprocess
    request = selected('sonarr')
    snapshot = {identity: sorted(Path(root.path).iterdir()) for identity, root in roots.items()}
    original_open = os.open
    calls = []
    def read_only_open(path, flags, *args, **kwargs):
        assert not flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND)
        calls.append(flags)
        return original_open(path, flags, *args, **kwargs)
    def forbidden(*args, **kwargs):
        pytest.fail('preflight attempted a mutation or network operation')
    with monkeypatch.context() as scoped:
        scoped.setattr(os, 'open', read_only_open)
        scoped.setattr(Path, 'mkdir', forbidden)
        scoped.setattr(socket, 'socket', forbidden)
        scoped.setattr(subprocess, 'Popen', forbidden)
        result = inspector(roots).inspect(request)
    assert calls and checks(result, 'storage_root')[0].status == 'passed'
    assert snapshot == {identity: sorted(Path(root.path).iterdir()) for identity, root in roots.items()}


def test_root_filesystem_ownership_check_fails_closed(roots):
    root_inode = Path('/').stat().st_ino
    def metadata(fd):
        original = os.fstat(fd)
        if original.st_ino == root_inode:
            values = list(original)
            values[4] = os.getuid() + 1000000
            return os.stat_result(values)
        return original
    instance = HostInspector(HostPolicy(roots), clock=lambda: NOW, stat_provider=metadata)
    assert checks(instance.inspect(selected()), 'storage_root')[0].status == 'failed'


@pytest.mark.parametrize('provider', [False, 0, ''])
def test_explicit_falsey_noncallable_provider_is_not_silently_replaced(roots, provider):
    with pytest.raises(HostPreflightError, match='^invalid_policy$'):
        HostInspector(HostPolicy(roots), clock=provider)
