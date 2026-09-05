"""Private READ-ONLY appdata binding, marker and descriptor observations.

No mkdir, ownership change, publish, repair, delete, Docker call or authorization
grant exists here. Root leases are supplied by a trusted in-process worker
broker, never decoded from API/IPC data. That broker must prove the approved
named root, native host/daemon mount and process-root context, and the exact
container-to-host UID/GID mapping. A policy digest alone proves none of these.
The existing default API container and DockerProbe.during callback cannot issue
such a mutation grant. Real native-host/root or remap proof remains a separate
runtime requirement; synthetic providers are only trusted test dependencies.

Markers bind the journal intent to actual directory identities. Mount IDs are
checked on held descriptors during a lease, not stored as stable reboot IDs.
Matching is a bounded historical observation, never permission to create or
resume partial staging. Only leaf directories are observed; their contents are
not enumerated. Marker/OS/configuration values never appear in diagnostics.
"""

from contextlib import contextmanager
from dataclasses import asdict, dataclass, field, fields
import errno
import hashlib
import json
import math
import os
import re
import stat
import threading
import time

from .resource_journal import AppdataIdentity, DirectoryIdentity, ResourceIntent, ResourceReceipt
from .resource_models import PrepareAppdataResource
from .resource_plan import _wire, verify_resource_plan


MAX_MARKER_BYTES = 4096
MARKER_NAME = '.larenor-owner-v1.json'
_ID = re.compile(r'[0-9a-f]{32}\Z')
_HASH = re.compile(r'[0-9a-f]{64}\Z')
_ROOT = re.compile(r'[a-z][a-z0-9_-]{0,31}\Z')
_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_CODES = {'invalid_appdata_binding', 'invalid_appdata_marker', 'invalid_appdata_lease',
          'invalid_appdata_limits', 'appdata_lease_busy'}


class AppdataError(Exception):
    def __init__(self, code='invalid_appdata_binding'):
        self.code = code if code in _CODES else 'invalid_appdata_binding'
        super().__init__(self.code)


def _require(condition):
    if not condition:
        raise ValueError()


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {item.name for item in fields(cls)}


def _matches(value, pattern):
    return type(value) is str and pattern.fullmatch(value) is not None


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'),
                      ensure_ascii=False, allow_nan=False).encode('utf-8')


def _identity(value):
    _require(_exact(value, DirectoryIdentity))
    _require(all(type(number) is int and 0 <= number <= 2**63 - 1 for number in (value.device, value.inode)))
    _require(value.inode > 0 and all(type(number) is int and 0 <= number < 2**31 for number in (value.uid, value.gid)))
    _require(type(value.mode) is int and 0 <= value.mode <= 0o7777)
    return value


def _fd_identity(fd):
    value = os.fstat(fd)
    _require(stat.S_ISDIR(value.st_mode))
    return _identity(DirectoryIdentity(value.st_dev, value.st_ino, value.st_uid, value.st_gid,
                                     stat.S_IMODE(value.st_mode)))


@dataclass(frozen=True, repr=False)
class AppdataBinding:
    """Re-derived catalog proposal, not a host path or filesystem capability."""

    resource: PrepareAppdataResource
    container_uid: int
    container_gid: int
    plan_hash: str
    stack_plan_hash: str
    policy_version: int
    policy_digest: str
    core_id: str
    home_id: str
    preparation_id: str
    source: tuple = field(compare=False)


def appdata_binding(plan, stack, catalog, policy, resource_id):
    try:
        _require(_matches(resource_id, _ID))
        verified = verify_resource_plan(plan, stack, catalog, policy)
        resource = next((item for item in verified.resources if item.resourceId == resource_id), None)
        _require(type(resource) is PrepareAppdataResource)
        child = next(item for item in stack.components if item.installationId == resource.installationId)
        user = child.plan.security.user
        _require(user in ('0:0', '1000:1000'))
        uid, gid = (int(part) for part in user.split(':'))
        return AppdataBinding(resource, uid, gid, verified.planHash, stack.planHash,
            verified.workerPolicyVersion, verified.workerPolicyDigest, verified.coreId,
            verified.homeId, verified.preparationId, (verified, stack, catalog, policy))
    except (ValueError, TypeError, AttributeError, StopIteration, RecursionError):
        raise AppdataError('invalid_appdata_binding') from None


def _binding(value):
    _require(_exact(value, AppdataBinding) and type(value.source) is tuple and len(value.source) == 4)
    expected = appdata_binding(*value.source, value.resource.resourceId)
    # Equality alone would allow True == 1 in copied dataclass integer fields.
    _require(type(value.container_uid) is int and type(value.container_gid) is int
             and type(value.policy_version) is int and value == expected)
    _require(_wire(value.resource) == _wire(expected.resource))
    return expected


@dataclass(frozen=True, repr=False)
class AppdataIdMapping:
    """Already proven mapping supplied by the caller; this is not discovery."""

    container_uid: int
    container_gid: int
    host_uid: int
    host_gid: int

    def __post_init__(self):
        if any(type(number) is not int or not 0 <= number < 2**31 for number in vars(self).values()):
            raise AppdataError('invalid_appdata_lease')


class _InspectionFailure(Exception):
    def __init__(self, state):
        self.state = state


def _check(condition, state='conflict'):
    if not condition:
        raise _InspectionFailure(state)


class AppdataRootLease:
    """Private caller capability, tied to this native thread and borrowed root.

    Owns a duplicate FD; the original remains caller-owned. ``revalidate`` must
    return literal True only while named-root, daemon and ID-mapping proofs are
    current. The mount provider must measure this thread's actual descriptor
    mount identity. Neither callback is a wire field or a production fallback.
    All inspector operations are read-only, including on a synthetic test lease.
    """

    def __init__(self, root_fd, *, root_id, worker_uid, policy_digest, root_identity,
                 mount_id, mapping, revalidate, mount_id_provider):
        self._fd = -1
        self._mutex = threading.Lock()
        self._pid, self._thread = os.getpid(), threading.get_ident()
        try:
            _require(type(root_fd) is int and root_fd >= 0 and _matches(root_id, _ROOT))
            _require(type(worker_uid) is int and worker_uid == os.geteuid()
                     and _matches(policy_digest, _HASH))
            _identity(root_identity)
            _require(root_identity.uid in {0, worker_uid} and not root_identity.mode & 0o022)
            _require(type(mount_id) is int and 0 < mount_id <= 2**63 - 1)
            _require(_exact(mapping, AppdataIdMapping))
            AppdataIdMapping(**vars(mapping))
            _require(callable(revalidate) and callable(mount_id_provider))
            self._fd = os.dup(root_fd)
            os.set_inheritable(self._fd, False)
            _require(_fd_identity(self._fd) == root_identity)
            self.root_id, self.worker_uid, self.policy_digest = root_id, worker_uid, policy_digest
            self.root_identity, self.mount_id, self.mapping = root_identity, mount_id, mapping
            self._revalidate, self._mount_id = revalidate, mount_id_provider
        except (OSError, ValueError, TypeError, AttributeError, AppdataError):
            if self._fd >= 0:
                os.close(self._fd)
                self._fd = -1
            raise AppdataError('invalid_appdata_lease') from None

    def __repr__(self):
        return 'AppdataRootLease(<private>)'

    def _check(self, deadline):
        _check(self._fd >= 0 and self._pid == os.getpid() and self._thread == threading.get_ident(), 'unavailable')
        _check(time.monotonic() < deadline, 'unavailable')
        _check(self._revalidate(deadline) is True, 'unavailable')
        _check(_fd_identity(self._fd) == self.root_identity, 'unavailable')
        self._check_mount(self._fd, deadline, 'unavailable')
        _check(time.monotonic() < deadline, 'unavailable')

    def _check_mount(self, fd, deadline, failure='conflict'):
        _check(time.monotonic() < deadline, 'unavailable')
        value = self._mount_id(fd, deadline)
        _check(type(value) is int and value == self.mount_id, failure)
        _check(time.monotonic() < deadline, 'unavailable')

    @contextmanager
    def _held(self, deadline):
        _check(self._mutex.acquire(blocking=False), 'unavailable')
        try:
            self._check(deadline)
            yield self._fd
            self._check(deadline)
        finally:
            self._mutex.release()

    def close(self):
        if not self._mutex.acquire(blocking=False):
            raise AppdataError('appdata_lease_busy')
        try:
            if self._fd >= 0:
                os.close(self._fd)
                self._fd = -1
        finally:
            self._mutex.release()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def _validate_inputs(binding, intent, lease):
    try:
        selected = _binding(binding)
        _require(type(lease) is AppdataRootLease and lease.root_id == selected.resource.rootId
                 and lease.policy_digest == selected.policy_digest)
        _identity(lease.root_identity)
        _require(_exact(lease.mapping, AppdataIdMapping))
        AppdataIdMapping(**vars(lease.mapping))
        _require((lease.mapping.container_uid, lease.mapping.container_gid)
                 == (selected.container_uid, selected.container_gid))
        _require(_exact(intent, ResourceIntent) and _matches(intent.journal_id, _ID)
                 and _matches(intent.ownership_nonce, _ID) and _matches(intent.specification_digest, _HASH))
        _require(type(intent.resource) is PrepareAppdataResource and _wire(intent.resource) == _wire(selected.resource))
        expected_spec = hashlib.sha256(_canonical(selected.resource.model_dump(mode='json'))).hexdigest()
        _require(intent.specification_digest == expected_spec)
        receipt = intent.receipt
        _require(_exact(receipt, ResourceReceipt) and type(receipt.revision) is int
                 and 2 <= receipt.revision <= 2**63 - 2)
        _require((receipt.resource_id, receipt.preparation_id, receipt.kind, receipt.plan_hash, receipt.worker_policy_digest)
                 == (selected.resource.resourceId, selected.preparation_id, 'prepare_appdata', selected.plan_hash, selected.policy_digest))
        codes = {'mutating': {'effect_started'}, 'uncertain': {'effect_uncertain', 'observation_unavailable'},
                 'ready': {'resource_matched'}, 'needs_attention': {'resource_missing', 'resource_conflict',
                 'resource_multiple', 'observation_invalid'}}
        _require(type(receipt.state) is str and receipt.state in codes
                 and type(receipt.code) is str and receipt.code in codes[receipt.state])
        _require((receipt.state == 'mutating') == (receipt.revision == 2))
        return selected
    except (ValueError, TypeError, AttributeError, AppdataError, RecursionError):
        raise AppdataError('invalid_appdata_binding') from None


def _appdata_identity(value, binding, lease):
    _require(_exact(value, AppdataIdentity) and type(value.mounts) is tuple
             and len(value.mounts) == len(binding.resource.mounts))
    for item in (value.root, *value.mounts):
        _identity(item)
        _require(item.device == lease.root_identity.device and item.mode == 0o700)
    _require(value.root.uid == lease.worker_uid)
    _require(all((item.uid, item.gid) == (lease.mapping.host_uid, lease.mapping.host_gid) for item in value.mounts))
    identities = [(item.device, item.inode) for item in (lease.root_identity, value.root, *value.mounts)]
    _require(len(identities) == len(set(identities)))


def build_appdata_marker(binding, intent, lease, identity):
    """Encode a bounded expected marker; never writes or grants ownership."""
    selected = _validate_inputs(binding, intent, lease)
    try:
        _appdata_identity(identity, selected, lease)
        data = dict(schemaVersion=1, coreId=selected.core_id, homeId=selected.home_id,
            preparationId=selected.preparation_id, installationId=selected.resource.installationId,
            operationId=selected.resource.operationId, resourceId=selected.resource.resourceId,
            journalId=intent.journal_id, ownershipNonce=intent.ownership_nonce,
            specificationDigest=intent.specification_digest, planHash=selected.plan_hash,
            stackPlanHash=selected.stack_plan_hash, workerPolicyVersion=selected.policy_version,
            workerPolicyDigest=selected.policy_digest, rootId=selected.resource.rootId,
            relativePath=selected.resource.relativePath, approvedRootIdentity=asdict(lease.root_identity),
            idMapping=asdict(lease.mapping), identity=asdict(identity),
            mounts=[dict(name=mount.proposedRelativePath.rsplit('/', 1)[1], target=mount.target,
                         requestedRelativePath=mount.requestedRelativePath,
                         proposedRelativePath=mount.proposedRelativePath) for mount in selected.resource.mounts])
        raw = _canonical(data)
        _require(len(raw) <= MAX_MARKER_BYTES)
        return raw
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise AppdataError('invalid_appdata_marker') from None


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result)
        result[key] = value
    return result


def validate_appdata_marker(raw, binding, intent, lease):
    """Strict canonical comparison also rejects unknown and duplicated fields."""
    _validate_inputs(binding, intent, lease)
    try:
        _require(type(raw) is bytes and len(raw) <= MAX_MARKER_BYTES)
        value = json.loads(raw, object_pairs_hook=_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        _require(type(value) is dict and type(value.get('schemaVersion')) is int and value['schemaVersion'] == 1)
        identity = value['identity']
        _require(type(identity) is dict and set(identity) == {'root', 'mounts'}
                 and type(identity['root']) is dict and type(identity['mounts']) is list and len(identity['mounts']) <= 3)
        parsed = AppdataIdentity(DirectoryIdentity(**identity['root']),
                                tuple(DirectoryIdentity(**item) for item in identity['mounts']))
        _require(build_appdata_marker(binding, intent, lease, parsed) == raw)
        return parsed
    except (ValueError, TypeError, KeyError, AttributeError, AppdataError, RecursionError):
        raise AppdataError('invalid_appdata_marker') from None


@dataclass(frozen=True, repr=False)
class AppdataInspection:
    """Internal result; partial means a bound marker exists but a leaf is absent."""

    state: str
    identity: AppdataIdentity | None = field(default=None, repr=False)


def _fingerprint(info):
    content = (info.st_size, info.st_mtime_ns, info.st_ctime_ns) if stat.S_ISREG(info.st_mode) else None
    return info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode, info.st_nlink, content


class AppdataInspector:
    def __init__(self, lease, *, timeout=2.0):
        if (type(lease) is not AppdataRootLease or type(timeout) not in (int, float)
                or not math.isfinite(timeout) or not 0 < timeout <= 2):
            raise AppdataError('invalid_appdata_limits')
        self._lease, self._timeout = lease, timeout

    def inspect(self, binding, intent):
        selected = _validate_inputs(binding, intent, self._lease)
        deadline = time.monotonic() + self._timeout
        try:
            with self._lease._held(deadline) as root:
                result = self._inspect(root, selected, intent, deadline)
            return result
        except _InspectionFailure as error:
            return AppdataInspection(error.state)
        except (OSError, ValueError, TypeError, RuntimeError, AttributeError, AppdataError):
            return AppdataInspection('unavailable')

    def _inspect(self, root, binding, intent, deadline):
        opened, links = [], []
        try:
            parent = root
            for part in binding.resource.relativePath.split('/'):
                self._lease._check(deadline)
                try:
                    child = os.open(part, _FLAGS, dir_fd=parent)
                except FileNotFoundError:
                    return AppdataInspection('missing')
                except OSError as error:
                    if error.errno in (errno.ELOOP, errno.ENOTDIR):
                        raise _InspectionFailure('conflict') from None
                    raise
                opened.append(child)
                identity = _fd_identity(child)
                _check(identity.uid == self._lease.worker_uid and identity.mode == 0o700)
                self._lease._check_mount(child, deadline)
                links.append((parent, part, child, _fingerprint(os.fstat(child))))
                parent = child
            envelope = parent
            marker, expected, marker_before = self._marker(envelope, binding, intent, deadline)
            opened.append(marker)
            links.append((envelope, MARKER_NAME, marker, marker_before))
            _check(_fd_identity(envelope) == expected.root)
            names = {MARKER_NAME} | {mount.proposedRelativePath.rsplit('/', 1)[1] for mount in binding.resource.mounts}
            self._names(envelope, names, deadline)
            absent = False
            for mount, wanted in zip(binding.resource.mounts, expected.mounts):
                name = mount.proposedRelativePath.rsplit('/', 1)[1]
                try:
                    child = os.open(name, _FLAGS, dir_fd=envelope)
                except FileNotFoundError:
                    absent = True
                    continue
                except OSError as error:
                    if error.errno in (errno.ELOOP, errno.ENOTDIR):
                        raise _InspectionFailure('conflict') from None
                    raise
                opened.append(child)
                _check(_fd_identity(child) == wanted)
                self._lease._check_mount(child, deadline)
                links.append((envelope, name, child, _fingerprint(os.fstat(child))))
            # Re-open names through their held parents. An old descriptor alone
            # must not certify a directory that has been renamed/replaced.
            for parent, name, descriptor, before in links:
                self._lease._check(deadline)
                after = os.stat(name, dir_fd=parent, follow_symlinks=False)
                _check(_fingerprint(after) == before == _fingerprint(os.fstat(descriptor)))
                self._lease._check_mount(descriptor, deadline)
            self._names(envelope, names, deadline)
            return AppdataInspection('partial' if absent else 'matched', None if absent else expected)
        finally:
            for descriptor in reversed(opened):
                os.close(descriptor)

    def _names(self, envelope, expected, deadline):
        with os.scandir(envelope) as entries:
            for count, entry in enumerate(entries, 1):
                _check(time.monotonic() < deadline, 'unavailable')
                _check(count <= len(expected) and entry.name in expected)

    def _marker(self, envelope, binding, intent, deadline):
        descriptor = -1
        try:
            descriptor = os.open(MARKER_NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                                 dir_fd=envelope)
            before = os.fstat(descriptor)
            _check(stat.S_ISREG(before.st_mode) and before.st_uid == self._lease.worker_uid
                   and stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1
                   and 0 < before.st_size <= MAX_MARKER_BYTES)
            self._lease._check_mount(descriptor, deadline)
            raw = bytearray()
            while len(raw) <= MAX_MARKER_BYTES:
                _check(time.monotonic() < deadline, 'unavailable')
                part = os.read(descriptor, min(1024, MAX_MARKER_BYTES + 1 - len(raw)))
                if not part:
                    break
                raw.extend(part)
            after = os.fstat(descriptor)
            _check(len(raw) == before.st_size and _fingerprint(before) == _fingerprint(after)
                   and (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                   == (after.st_size, after.st_mtime_ns, after.st_ctime_ns))
            parsed = validate_appdata_marker(bytes(raw), binding, intent, self._lease)
            transferred, descriptor = descriptor, -1
            return transferred, parsed, _fingerprint(before)
        except FileNotFoundError:
            raise _InspectionFailure('conflict') from None
        except AppdataError:
            raise _InspectionFailure('conflict') from None
        except OSError as error:
            if error.errno in (errno.ELOOP, errno.ENOTDIR):
                raise _InspectionFailure('conflict') from None
            raise
        finally:
            if descriptor >= 0:
                os.close(descriptor)
