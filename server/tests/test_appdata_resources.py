"""Read-only owned-appdata observations against disposable local directories."""

from dataclasses import replace
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import stat

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.resource_journal import AppdataIdentity, DirectoryIdentity, ResourceJournal
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.resource_plan import build_resource_plan
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.appdata_resources import (
    AppdataError, AppdataIdMapping, AppdataRootLease, AppdataInspector,
    appdata_binding, build_appdata_marker, validate_appdata_marker,
)


def directory_identity(fd):
    value = os.fstat(fd)
    return DirectoryIdentity(value.st_dev, value.st_ino, value.st_uid, value.st_gid, stat.S_IMODE(value.st_mode))


@pytest.fixture
def prepared(tmp_path, request):
    component_index, platform = getattr(request, 'param', (0, 'linux/amd64'))
    catalog = load_catalog()
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3, workerPolicyDigest='d' * 64)
    stack = build_media_stack_plan(catalog, {}, platform,
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    plan = build_resource_plan(stack, catalog, policy)
    source = dict(plan=plan, stack=stack, catalog=catalog, policy=policy)
    resource_id = plan.resources[component_index * 2 + 1].resourceId
    binding = appdata_binding(**source, resource_id=resource_id)
    approved = tmp_path / 'approved'
    approved.mkdir(mode=0o700)
    root_fd = os.open(approved, os.O_RDONLY | os.O_DIRECTORY)
    root_identity = directory_identity(root_fd)
    proof = {'valid': True, 'mount': 13}
    # Synthetic mapping/proof is explicit: macOS UID is not a daemon userns claim.
    with AppdataRootLease(root_fd, root_id='appdata', worker_uid=os.geteuid(),
        policy_digest=policy.workerPolicyDigest, root_identity=root_identity,
        mount_id=13, mapping=AppdataIdMapping(binding.container_uid, binding.container_gid, os.geteuid(), os.getegid()),
        revalidate=lambda deadline: proof['valid'], mount_id_provider=lambda fd, deadline: proof['mount']) as lease:
        os.close(root_fd)
        with ResourceJournal(tmp_path / 'resources-v1', initialize=True) as journal, journal.locked():
            receipt = journal.prepare(**source, resource_id=resource_id)
            intent = journal.begin(resource_id, receipt.revision, **source)
            envelope = approved / binding.resource.relativePath
            yield dict(source=source, binding=binding, intent=intent, lease=lease,
                       root=approved, envelope=envelope, proof=proof)


def make_tree(value):
    envelope = value['envelope']
    envelope.mkdir(parents=True, mode=0o700)
    for parent in envelope.parents:
        if parent == value['root']:
            break
        parent.chmod(0o700)
    leaves = []
    for mount in value['binding'].resource.mounts:
        leaf = envelope / mount.proposedRelativePath.rsplit('/', 1)[1]
        leaf.mkdir(mode=0o700)
        with_fd = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY)
        leaves.append(directory_identity(with_fd))
        os.close(with_fd)
    fd = os.open(envelope, os.O_RDONLY | os.O_DIRECTORY)
    identity = AppdataIdentity(directory_identity(fd), tuple(leaves))
    os.close(fd)
    raw = build_appdata_marker(value['binding'], value['intent'], value['lease'], identity)
    marker = envelope / '.larenor-owner-v1.json'
    marker.write_bytes(raw)
    marker.chmod(0o600)
    return identity, marker, raw


def inspect(value):
    return AppdataInspector(value['lease']).inspect(value['binding'], value['intent'])


@pytest.mark.parametrize('prepared', [(index, platform) for index in range(6)
    for platform in ('linux/amd64', 'linux/arm64')], indirect=True)
def test_matching_private_tree_has_strict_bounded_marker_and_no_path_in_result(prepared):
    expected, marker, raw = make_tree(prepared)
    assert len(raw) <= 4096
    assert json.dumps(json.loads(raw), sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode() == raw
    assert validate_appdata_marker(raw, prepared['binding'], prepared['intent'], prepared['lease']) == expected
    before = marker.read_bytes()
    result = inspect(prepared)
    assert (result.state, result.identity) == ('matched', expected)
    assert result.identity.root.uid == os.geteuid()
    assert str(prepared['root']) not in repr(result)
    assert prepared['intent'].ownership_nonce not in repr(result)
    assert marker.read_bytes() == before


def test_missing_path_is_observed_without_creating_even_its_namespace(prepared):
    assert inspect(prepared).state == 'missing'
    assert list(prepared['root'].iterdir()) == []


def test_marker_absence_is_conflict_but_bound_marker_with_missing_leaf_is_partial(prepared):
    _, marker, raw = make_tree(prepared)
    marker.unlink()
    assert inspect(prepared).state == 'conflict'
    marker.write_bytes(raw)
    marker.chmod(0o600)
    leaf = next(path for path in prepared['envelope'].iterdir() if path.is_dir())
    leaf.rmdir()
    assert inspect(prepared).state == 'partial'


@pytest.mark.parametrize('target', ['namespace', 'envelope', 'leaf', 'marker'])
def test_symlinks_never_follow_foreign_files_or_directories(prepared, target, tmp_path):
    make_tree(prepared)
    envelope = prepared['envelope']
    path = {'namespace': prepared['root'] / 'larenor-managed-v1', 'envelope': envelope,
            'leaf': envelope / 'config', 'marker': envelope / '.larenor-owner-v1.json'}[target]
    original = path.with_name(path.name + '.original')
    path.rename(original)
    path.symlink_to(original, target_is_directory=target != 'marker')
    assert inspect(prepared).state == 'conflict'
    assert path.is_symlink()


@pytest.mark.parametrize('target,mode', [('namespace', 0o755), ('envelope', 0o750), ('leaf', 0o755), ('marker', 0o640)])
def test_nonprivate_namespace_envelope_marker_or_leaf_is_rejected(prepared, target, mode):
    _, marker, _ = make_tree(prepared)
    path = {'namespace': prepared['root'] / 'larenor-managed-v1', 'envelope': prepared['envelope'],
            'leaf': prepared['envelope'] / 'config', 'marker': marker}[target]
    path.chmod(mode)
    assert inspect(prepared).state == 'conflict'
    assert stat.S_IMODE(path.stat().st_mode) == mode


def test_hardlinked_marker_and_unexpected_envelope_entries_are_foreign(prepared, tmp_path):
    _, marker, _ = make_tree(prepared)
    alias = tmp_path / 'alias'
    os.link(marker, alias)
    assert inspect(prepared).state == 'conflict'
    alias.unlink()
    other = prepared['envelope'] / 'foreign'
    other.write_bytes(b'secret')
    assert inspect(prepared).state == 'conflict' and other.read_bytes() == b'secret'


@pytest.mark.parametrize('field', ['journal_id', 'ownership_nonce', 'specification_digest', 'resource', 'receipt'])
def test_forged_intent_cannot_use_an_owned_marker(prepared, field):
    make_tree(prepared)
    intent = prepared['intent']
    changes = {
        'journal_id': 'f' * 32, 'ownership_nonce': 'f' * 32, 'specification_digest': 'f' * 64,
        'resource': intent.resource.model_copy(update={'rootId': 'elsewhere'}),
        'receipt': replace(intent.receipt, plan_hash='f' * 64),
    }
    forged = replace(intent, **{field: changes[field]})
    if field in ('journal_id', 'ownership_nonce'):
        assert AppdataInspector(prepared['lease']).inspect(prepared['binding'], forged).state == 'conflict'
    else:
        with pytest.raises(AppdataError, match='^invalid_appdata_binding$'):
            AppdataInspector(prepared['lease']).inspect(prepared['binding'], forged)


@pytest.mark.parametrize('damage', ['duplicate', 'unknown', 'bool', 'truncated', 'oversized', 'noncanonical', 'inode', 'target', 'policy'])
def test_malformed_or_foreign_marker_never_matches(prepared, damage):
    _, marker, raw = make_tree(prepared)
    value = json.loads(raw)
    if damage == 'duplicate':
        raw = raw[:-1] + b',"schemaVersion":1}'
    elif damage == 'truncated':
        raw = raw[:-3]
    elif damage == 'oversized':
        raw += b' ' * 4096
    elif damage == 'noncanonical':
        raw = json.dumps(value, indent=2).encode()
    else:
        if damage == 'unknown':
            value['secret'] = 'not-valid'
        elif damage == 'bool':
            value['schemaVersion'] = True
        elif damage == 'inode':
            value['identity']['root']['inode'] += 1
        elif damage == 'target':
            value['mounts'][0]['target'] = '/etc'
        else:
            value['workerPolicyDigest'] = 'f' * 64
        raw = json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    marker.write_bytes(raw)
    assert inspect(prepared).state == 'conflict'


def test_cloned_marker_cannot_adopt_a_replacement_envelope(prepared):
    _, _, raw = make_tree(prepared)
    original = prepared['envelope']
    original.rename(original.with_name('previous'))
    make_tree(prepared)
    (original / '.larenor-owner-v1.json').write_bytes(raw)
    assert inspect(prepared).state == 'conflict'


@pytest.mark.parametrize('proof', [False, None, 1, 'true'])
def test_unavailable_or_nonliteral_lease_proof_never_reports_owned(prepared, proof):
    make_tree(prepared)
    prepared['proof']['valid'] = proof
    assert inspect(prepared).state == 'unavailable'


def test_mount_id_change_fails_even_when_device_and_inode_are_unchanged(prepared):
    make_tree(prepared)
    prepared['proof']['mount'] = 14
    assert inspect(prepared).state == 'unavailable'


def test_binding_rederivation_rejects_foreign_kind_or_unsafe_model_copy(prepared):
    source = prepared['source']
    for resource in (source['plan'].resources[0].resourceId, 'f' * 32):
        with pytest.raises(AppdataError, match='^invalid_appdata_binding$'):
            appdata_binding(**source, resource_id=resource)
    changed = {**source, 'plan': source['plan'].model_copy(update={'workerPolicyVersion': True})}
    with pytest.raises(AppdataError, match='^invalid_appdata_binding$'):
        appdata_binding(**changed, resource_id=prepared['binding'].resource.resourceId)


def test_inspection_only_opens_names_relative_to_held_descriptors_and_never_mutates(prepared, monkeypatch):
    make_tree(prepared)
    import socket
    import subprocess
    real_open = os.open
    opened = []
    def check_open(path, flags, *args, **kwargs):
        assert type(path) is str and '/' not in path
        assert type(kwargs.get('dir_fd')) is int
        assert flags & os.O_NOFOLLOW and flags & os.O_CLOEXEC
        assert not flags & (os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_RDWR)
        opened.append(path)
        return real_open(path, flags, *args, **kwargs)
    def forbidden(*args, **kwargs):
        pytest.fail('read-only observation attempted a mutation or network operation')
    for name in ('mkdir', 'makedirs', 'chown', 'fchown', 'chmod', 'fchmod', 'rename', 'replace', 'unlink', 'remove', 'rmdir'):
        monkeypatch.setattr(os, name, forbidden)
    monkeypatch.setattr(socket, 'socket', forbidden)
    monkeypatch.setattr(subprocess, 'Popen', forbidden)
    monkeypatch.setattr(os, 'open', check_open)
    assert inspect(prepared).state == 'matched'
    assert '.larenor-owner-v1.json' in opened and 'config' in opened


def test_binding_and_marker_helpers_are_pure_without_filesystem_observation(prepared, monkeypatch):
    identity, _, raw = make_tree(prepared)
    def forbidden(*args, **kwargs):
        pytest.fail('pure marker or binding helper observed host state')
    for name in ('open', 'read', 'stat', 'fstat', 'scandir'):
        monkeypatch.setattr(os, name, forbidden)
    assert appdata_binding(**prepared['source'], resource_id=prepared['binding'].resource.resourceId) == prepared['binding']
    assert build_appdata_marker(prepared['binding'], prepared['intent'], prepared['lease'], identity) == raw
    assert validate_appdata_marker(raw, prepared['binding'], prepared['intent'], prepared['lease']) == identity


@pytest.mark.parametrize('target', ['namespace', 'envelope', 'marker'])
def test_named_path_replacement_during_marker_read_is_not_certified_by_old_fd(prepared, monkeypatch, target):
    _, marker, raw = make_tree(prepared)
    read = os.read
    changed = False
    def swapping(fd, maximum):
        nonlocal changed
        data = read(fd, maximum)
        if not changed:
            changed = True
            path = prepared['root'] / 'larenor-managed-v1' if target == 'namespace' else prepared['envelope'] if target == 'envelope' else marker
            path.rename(path.with_name(path.name + '.previous'))
            if target == 'marker':
                marker.write_bytes(raw)
                marker.chmod(0o600)
            else:
                make_tree(prepared)
        return data
    monkeypatch.setattr(os, 'read', swapping)
    assert inspect(prepared).state == 'conflict'


def test_root_path_replacement_invalidates_callers_named_root_proof(prepared):
    make_tree(prepared)
    root = prepared['root']
    root.rename(root.with_name('old-root'))
    root.mkdir(mode=0o700)
    prepared['proof']['valid'] = False
    assert inspect(prepared).state == 'unavailable'
    assert list(root.iterdir()) == []


def test_same_device_leaf_bind_mount_change_is_rejected(prepared):
    identity, _, _ = make_tree(prepared)
    lease = prepared['lease']
    lease._mount_id = lambda fd, deadline: 14 if os.fstat(fd).st_ino == identity.mounts[0].inode else 13
    assert inspect(prepared).state == 'conflict'


def test_leaf_contents_are_not_enumerated_or_used_as_ownership_proof(prepared):
    make_tree(prepared)
    private = prepared['envelope'] / 'config' / 'private.db'
    private.write_bytes(b'not a directory ownership marker')
    assert inspect(prepared).state == 'matched'
    assert private.read_bytes() == b'not a directory ownership marker'


def test_byte_limit_checked_before_reading_an_oversized_or_special_marker(prepared, monkeypatch):
    _, marker, _ = make_tree(prepared)
    marker.write_bytes(b'x' * 8192)
    reads = []
    original = os.read
    def read(fd, count):
        reads.append(count)
        return original(fd, count)
    monkeypatch.setattr(os, 'read', read)
    assert inspect(prepared).state == 'conflict' and not reads
    marker.unlink()
    os.mkfifo(marker, 0o600)
    assert inspect(prepared).state == 'conflict' and not reads


def test_marker_reads_use_small_chunks_and_never_exceed_bound(prepared, monkeypatch):
    _, marker, _ = make_tree(prepared)
    marker.write_bytes(b'{' + b' ' * 4094 + b'}')
    reads = []
    original = os.read
    def read(fd, count):
        reads.append(count)
        return original(fd, count)
    monkeypatch.setattr(os, 'read', read)
    assert inspect(prepared).state == 'conflict'
    assert max(reads) <= 1024 and sum(reads) <= 4097


@pytest.mark.parametrize('change', ['before', 'after_read', 'proof_error', 'mount_error'])
def test_deadline_and_provider_errors_are_bounded_static_observations(prepared, monkeypatch, change):
    make_tree(prepared)
    import larenor_server.plugins.appdata_resources as module
    now = [0.0]
    monkeypatch.setattr(module.time, 'monotonic', lambda: now[0])
    def failing(*_):
        raise OSError('private hostname and secret path')
    if change == 'before':
        def proof(deadline):
            now[0] = 3.0
            return True
        prepared['lease']._revalidate = proof
    elif change == 'after_read':
        read = os.read
        def slow(fd, count):
            now[0] = 3.0
            return read(fd, count)
        monkeypatch.setattr(os, 'read', slow)
    elif change == 'proof_error':
        prepared['lease']._revalidate = failing
    else:
        prepared['lease']._mount_id = failing
    result = inspect(prepared)
    assert result.state == 'unavailable' and 'secret' not in repr(result)


def test_close_during_inspection_retains_fd_and_cross_thread_lease_is_unavailable(prepared):
    make_tree(prepared)
    lease = prepared['lease']
    def proof(deadline):
        with pytest.raises(AppdataError, match='^appdata_lease_busy$'):
            lease.close()
        return True
    lease._revalidate = proof
    assert inspect(prepared).state == 'matched'
    with ThreadPoolExecutor(max_workers=1) as executor:
        assert executor.submit(inspect, prepared).result().state == 'unavailable'
    lease.close()
    lease.close()
    assert inspect(prepared).state == 'unavailable'


def test_restart_intent_revision_changes_do_not_rewrite_a_valid_marker(prepared):
    expected, _, raw = make_tree(prepared)
    intent = replace(prepared['intent'], receipt=replace(prepared['intent'].receipt,
        state='uncertain', revision=3, code='effect_uncertain'))
    assert validate_appdata_marker(raw, prepared['binding'], intent, prepared['lease']) == expected
    assert AppdataInspector(prepared['lease']).inspect(prepared['binding'], intent).state == 'matched'


@pytest.mark.parametrize('kind', ['directory', 'mapping', 'binding', 'receipt'])
def test_constructed_boolean_or_hidden_dataclass_values_do_not_coerce(prepared, kind):
    identity, _, _ = make_tree(prepared)
    if kind == 'directory':
        identity = replace(identity, root=replace(identity.root, inode=True))
        with pytest.raises(AppdataError, match='^invalid_appdata_marker$'):
            build_appdata_marker(prepared['binding'], prepared['intent'], prepared['lease'], identity)
    elif kind == 'mapping':
        object.__setattr__(prepared['lease'].mapping, 'host_uid', True)
        with pytest.raises(AppdataError, match='^invalid_appdata_binding$'):
            inspect(prepared)
    elif kind == 'binding':
        binding = replace(prepared['binding'], policy_version=True)
        with pytest.raises(AppdataError, match='^invalid_appdata_binding$'):
            AppdataInspector(prepared['lease']).inspect(binding, prepared['intent'])
    else:
        intent = replace(prepared['intent'], receipt=replace(prepared['intent'].receipt, revision=True))
        with pytest.raises(AppdataError, match='^invalid_appdata_binding$'):
            AppdataInspector(prepared['lease']).inspect(prepared['binding'], intent)


@pytest.mark.parametrize('timeout', [True, 0, -1, 2.1, float('inf'), float('nan'), '1'])
def test_inspection_limit_is_strict(prepared, timeout):
    with pytest.raises(AppdataError, match='^invalid_appdata_limits$'):
        AppdataInspector(prepared['lease'], timeout=timeout)


@pytest.mark.parametrize('damage', ['fd', 'identity', 'mapping', 'root_id', 'policy', 'proof', 'mount', 'owner'])
def test_lease_constructor_cannot_turn_unverified_or_foreign_values_into_observed_grants(prepared, damage):
    current = prepared['lease']
    args = dict(root_fd=current._fd, root_id=current.root_id, worker_uid=current.worker_uid,
        policy_digest=current.policy_digest, root_identity=current.root_identity, mount_id=13,
        mapping=current.mapping, revalidate=lambda _: True, mount_id_provider=lambda *_: 13)
    field, value = {
        'fd': ('root_fd', -1), 'identity': ('root_identity', replace(current.root_identity, inode=999999)),
        'mapping': ('mapping', object()), 'root_id': ('root_id', '../appdata'),
        'policy': ('policy_digest', 'secret'), 'proof': ('revalidate', True),
        'mount': ('mount_id', True), 'owner': ('worker_uid', current.worker_uid + 1),
    }[damage]
    args[field] = value
    with pytest.raises(AppdataError, match='^invalid_appdata_lease$'):
        AppdataRootLease(**args)


def test_inspector_closes_every_opened_descriptor_on_marker_error(prepared, monkeypatch):
    _, marker, _ = make_tree(prepared)
    marker.write_bytes(b'invalid')
    outstanding = set()
    opened, close = os.open, os.close
    def track_open(*args, **kwargs):
        fd = opened(*args, **kwargs)
        outstanding.add(fd)
        return fd
    def track_close(fd):
        outstanding.discard(fd)
        return close(fd)
    monkeypatch.setattr(os, 'open', track_open)
    monkeypatch.setattr(os, 'close', track_close)
    assert inspect(prepared).state == 'conflict'
    assert not outstanding


def test_marker_changed_after_validation_cannot_reset_the_observed_fingerprint(prepared, monkeypatch):
    _, marker, _ = make_tree(prepared)
    import larenor_server.plugins.appdata_resources as module
    validate = module.validate_appdata_marker
    def changed(*args):
        result = validate(*args)
        marker.write_bytes(b'invalidated-after-read')
        return result
    monkeypatch.setattr(module, 'validate_appdata_marker', changed)
    assert inspect(prepared).state == 'conflict'


def test_missing_child_of_replaced_parent_is_not_reported_as_current_tree_missing(prepared, monkeypatch):
    namespace = prepared['root'] / 'larenor-managed-v1'
    namespace.mkdir(mode=0o700)
    real_open = os.open
    changed = False
    def replace_before_child_lookup(path, flags, *args, **kwargs):
        nonlocal changed
        if not changed and path == prepared['source']['stack'].coreId:
            changed = True
            namespace.rename(namespace.with_name('retired-namespace'))
            # The named, current tree is complete. Only the old held parent
            # lacks this child, so its ENOENT is not a current-path observation.
            make_tree(prepared)
        return real_open(path, flags, *args, **kwargs)
    monkeypatch.setattr(os, 'open', replace_before_child_lookup)
    assert inspect(prepared).state == 'conflict'
    assert inspect(prepared).state == 'matched'
    assert list(namespace.with_name('retired-namespace').iterdir()) == []


def test_missing_child_under_unchanged_existing_parent_remains_missing(prepared):
    (prepared['root'] / 'larenor-managed-v1').mkdir(mode=0o700)
    assert inspect(prepared).state == 'missing'
