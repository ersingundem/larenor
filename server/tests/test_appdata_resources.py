"""Read-only owned-appdata observations against disposable local directories."""

from dataclasses import replace
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
def prepared(tmp_path):
    catalog = load_catalog()
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3, workerPolicyDigest='d' * 64)
    stack = build_media_stack_plan(catalog, {}, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    plan = build_resource_plan(stack, catalog, policy)
    source = dict(plan=plan, stack=stack, catalog=catalog, policy=policy)
    resource_id = plan.resources[1].resourceId
    binding = appdata_binding(**source, resource_id=resource_id)
    approved = tmp_path / 'approved'
    approved.mkdir(mode=0o700)
    root_fd = os.open(approved, os.O_RDONLY | os.O_DIRECTORY)
    root_identity = directory_identity(root_fd)
    proof = {'valid': True, 'mount': 13}
    # Synthetic mapping/proof is explicit: macOS UID is not a daemon userns claim.
    with AppdataRootLease(root_fd, root_id='appdata', worker_uid=os.geteuid(),
        policy_digest=policy.workerPolicyDigest, root_identity=root_identity,
        mount_id=13, mapping=AppdataIdMapping(1000, 1000, os.geteuid(), os.getegid()),
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
