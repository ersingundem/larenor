"""Private resource intents, separate from the v1 container journal.

The caller must hold ``locked()`` for its entire effect/observation lease. A
committed ``begin`` precedes an effect; a lost response permits only read-only
reconciliation. This module never creates resources, retries effects, adopts or
deletes anything. Current plan verification identifies requested policy, not an
authorization grant; the dispatcher must still check actor and runtime authority.

``ready`` is an INTERNAL historical receipt from a trusted typed observer. The
journal checks its binding and shape, not physical Docker/filesystem properties,
current availability or installation readiness. Hashes detect damaged/mismatched
local state, not malicious changes by the worker's own trusted OS identity.
No keys, credentials, host paths or environment-based authority are introduced.
"""

from contextlib import contextmanager
from dataclasses import asdict, dataclass, field, fields
import fcntl
from functools import wraps
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import threading

from .resource_models import ResourcePreparationPlan, WorkerPolicyBinding
from .resource_plan import verify_resource_plan
from .stack_plan import MediaStackPlan
from .worker import DockerWorkerError, _safe_path


MAX_RESOURCES = 3328  # 256 preparations of exactly thirteen proposals.
MAX_PAYLOAD_BYTES = 98304
_MAX_DATABASE_BYTES = 512 * 1024 * 1024
_MAX_REVISION = 2**63 - 2
_ID = re.compile(r'[0-9a-f]{32}\Z')
_DIGEST = re.compile(r'[0-9a-f]{64}\Z')
_IMAGE = re.compile(r'sha256:[0-9a-f]{64}\Z')
_STATE_CODES = {
    'prepared': {'resource_prepared'}, 'mutating': {'effect_started'},
    'ready': {'resource_matched'},
    'uncertain': {'effect_uncertain', 'observation_unavailable'},
    'needs_attention': {'resource_missing', 'resource_conflict', 'resource_multiple', 'observation_invalid'},
}
_COLUMNS = ('resource_id', 'preparation_id', 'kind', 'revision', 'state', 'code',
            'nonce', 'payload', 'observation', 'digest')
_SCHEMA = (
    'CREATE TABLE metadata(identity TEXT NOT NULL PRIMARY KEY,version INTEGER NOT NULL,'
    'count INTEGER NOT NULL,digest TEXT NOT NULL)',
    'CREATE TABLE resources(resource_id TEXT NOT NULL PRIMARY KEY,preparation_id TEXT NOT NULL,'
    'kind TEXT NOT NULL,revision INTEGER NOT NULL,state TEXT NOT NULL,code TEXT NOT NULL,'
    'nonce TEXT NOT NULL,payload TEXT NOT NULL,observation TEXT,digest TEXT NOT NULL,'
    'UNIQUE(preparation_id,resource_id,kind))',
)


class ResourceJournalError(ValueError):
    """Static diagnostic only; never contains a path, payload or raw exception."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def _require(condition, code='journal_unavailable'):
    if not condition:
        raise ResourceJournalError(code)


def _static(function):
    @wraps(function)
    def guarded(*args, **kwargs):
        try:
            return function(*args, **kwargs)
        except ResourceJournalError:
            raise
        except (OSError, ValueError, TypeError, sqlite3.Error, RecursionError):
            raise ResourceJournalError('journal_unavailable') from None
    return guarded


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode('utf-8')


def _digest(value):
    return hashlib.sha256(_canonical(value)).hexdigest()


def _matches(value, expression):
    return type(value) is str and expression.fullmatch(value) is not None


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _json(value, maximum=MAX_PAYLOAD_BYTES):
    _require(type(value) in (str, bytes) and len(value) <= maximum)
    return json.loads(value, object_pairs_hook=_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))


@dataclass(frozen=True)
class ResourceReceipt:
    """Opaque internal state; intentionally excludes paths, nonce and identities."""

    resource_id: str
    preparation_id: str
    kind: str
    plan_hash: str
    worker_policy_digest: str
    state: str
    revision: int
    code: str


@dataclass(frozen=True, repr=False)
class ResourceIntent:
    resource: object
    journal_id: str
    ownership_nonce: str
    specification_digest: str
    receipt: ResourceReceipt

    def __repr__(self):
        return 'ResourceIntent(<private>)'


@dataclass(frozen=True, repr=False)
class ImageIdentity:
    image_id: str


@dataclass(frozen=True, repr=False)
class NetworkIdentity:
    network_id: str


@dataclass(frozen=True, repr=False)
class DirectoryIdentity:
    device: int
    inode: int
    uid: int
    gid: int
    mode: int


@dataclass(frozen=True, repr=False)
class AppdataIdentity:
    root: DirectoryIdentity
    mounts: tuple[DirectoryIdentity, ...]


@dataclass(frozen=True, repr=False)
class ResourceObservation:
    """Trusted adapter output, never accepted from IPC or an external client.

    A matching label/name/empty directory alone is NOT sufficient evidence. The
    adapter must check all planned properties and ownership before returning a
    matched identity. This journal only validates the typed receipt's binding.
    """

    status: str
    resource_id: str
    journal_id: str
    ownership_nonce: str
    specification_digest: str
    identity: ImageIdentity | NetworkIdentity | AppdataIdentity | None = field(default=None, repr=False)


def _exact_dataclass(value, cls):
    return type(value) is cls and set(vars(value)) == {item.name for item in fields(cls)}


def _directory(value):
    _require(_exact_dataclass(value, DirectoryIdentity))
    _require(all(type(number) is int and 0 <= number <= 2**63 - 1
                 for number in (value.device, value.inode, value.uid, value.gid)))
    _require(value.inode > 0 and type(value.mode) is int and 0 <= value.mode <= 0o7777)


def _observation_wire(value, intent):
    _require(_exact_dataclass(value, ResourceObservation))
    _require((value.resource_id, value.journal_id, value.ownership_nonce, value.specification_digest)
             == (intent.resource.resourceId, intent.journal_id, intent.ownership_nonce, intent.specification_digest))
    _require(type(value.status) is str and value.status in {'matched', 'missing', 'conflict', 'multiple', 'unavailable'})
    identity = value.identity
    if value.status != 'matched':
        _require(identity is None)
    elif intent.resource.kind == 'ensure_image':
        _require(_exact_dataclass(identity, ImageIdentity) and _matches(identity.image_id, _IMAGE)
                 and identity.image_id == intent.resource.image.configDigest)
    elif intent.resource.kind == 'prepare_control_network':
        _require(_exact_dataclass(identity, NetworkIdentity) and _matches(identity.network_id, _DIGEST))
    else:
        _require(_exact_dataclass(identity, AppdataIdentity) and type(identity.mounts) is tuple
                 and len(identity.mounts) == len(intent.resource.mounts))
        _directory(identity.root)
        for mount in identity.mounts:
            _directory(mount)
        locations = [(node.device, node.inode) for node in (identity.root, *identity.mounts)]
        _require(len(set(locations)) == len(locations))
    return asdict(value)


def _observation_from_wire(value, intent):
    _require(type(value) is dict and set(value) == {item.name for item in fields(ResourceObservation)})
    data = dict(value)
    identity = data['identity']
    if identity is not None:
        _require(type(identity) is dict)
        if intent.resource.kind == 'ensure_image':
            identity = ImageIdentity(**identity)
        elif intent.resource.kind == 'prepare_control_network':
            identity = NetworkIdentity(**identity)
        else:
            _require(set(identity) == {'root', 'mounts'} and type(identity['mounts']) is list)
            identity = AppdataIdentity(DirectoryIdentity(**identity['root']),
                                       tuple(DirectoryIdentity(**entry) for entry in identity['mounts']))
    data['identity'] = identity
    result = ResourceObservation(**data)
    _observation_wire(result, intent)
    return result


class ResourceJournal:
    """Private process-locked intent store; only a fresh directory initializes.

    Existing missing or corrupt history is never regenerated. Every lease checks
    descriptor/path identity and the complete schema and integrity envelope.
    Close refuses an active lease instead of releasing a possibly live effect.
    """

    def __init__(self, directory, *, initialize=False):
        self._mutex = threading.Lock()
        self._owner = None
        self._pid = os.getpid()
        self._closed = True
        self._fds = {}
        self._db = None
        try:
            self.directory = Path(directory)
            _require(type(initialize) is bool and self.directory.is_absolute()
                     and '..' not in self.directory.parts, 'unsafe_worker_path')
            if not self.directory.exists() and not self.directory.is_symlink():
                _require(initialize, 'journal_unavailable')
                self._safe(self.directory.parent, directory=True)
                self.directory.mkdir(mode=0o700)
                fresh = True
            else:
                fresh = False
            self._safe(self.directory, directory=True)
            self._fds['.'] = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            if fresh:
                self.identity = secrets.token_hex(16)
                for name, content in (
                    ('journal.lock', b''), ('journal.sqlite', b''),
                    ('identity.json', _canonical({'schemaVersion': 1, 'identity': self.identity})),
                ):
                    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=self._fds['.'])
                    try:
                        if content:
                            _require(os.write(fd, content) == len(content))
                        os.fsync(fd)
                    finally:
                        os.close(fd)
                os.fsync(self._fds['.'])
            for name in ('journal.lock', 'journal.sqlite', 'identity.json'):
                _require((self.directory / name).exists() or (self.directory / name).is_symlink())
                self._safe(self.directory / name)
                self._fds[name] = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self._fds['.'])
            self._check_paths()
            identity = _json(os.pread(self._fds['identity.json'], 513, 0), 512)
            _require(type(identity) is dict and set(identity) == {'schemaVersion', 'identity'}
                     and type(identity['schemaVersion']) is int and identity['schemaVersion'] == 1
                     and _matches(identity['identity'], _ID))
            self.identity = identity['identity']
            self._closed = False
            with self._lease(validate=False):
                self._db = sqlite3.connect((self.directory / 'journal.sqlite').as_uri() + '?mode=rw',
                    uri=True, timeout=2, isolation_level=None, check_same_thread=False)
                self._db.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, MAX_PAYLOAD_BYTES + 8192)
                self._check_paths()
                self._db.execute('PRAGMA synchronous=FULL')
                _require(self._db.execute('PRAGMA journal_mode').fetchone() == ('delete',))
                if fresh:
                    with self._transaction():
                        for statement in _SCHEMA:
                            self._db.execute(statement)
                        self._db.execute('INSERT INTO metadata VALUES(?,1,0,?)',
                                         (self.identity, self._aggregate(())))
                self._validate()
        except ResourceJournalError:
            self._dispose()
            raise
        except (OSError, ValueError, TypeError, sqlite3.Error, RecursionError):
            self._dispose()
            raise ResourceJournalError('journal_unavailable') from None

    def __repr__(self):
        return 'ResourceJournal(<private>)'

    @staticmethod
    def _safe(path, *, directory=False):
        try:
            _safe_path(path, uid=os.geteuid(), kind=stat.S_ISDIR if directory else stat.S_ISREG, private=True)
            _require(stat.S_IMODE(path.lstat().st_mode) == (0o700 if directory else 0o600), 'unsafe_worker_path')
        except DockerWorkerError:
            raise ResourceJournalError('unsafe_worker_path') from None

    def _check_paths(self):
        for name, fd in self._fds.items():
            path = self.directory if name == '.' else self.directory / name
            self._safe(path, directory=name == '.')
            current, held = path.lstat(), os.fstat(fd)
            _require((current.st_dev, current.st_ino) == (held.st_dev, held.st_ino), 'unsafe_worker_path')
            if name == 'journal.sqlite':
                _require(current.st_size <= _MAX_DATABASE_BYTES)
        for suffix in ('-journal', '-wal', '-shm'):
            sidecar = self.directory / ('journal.sqlite' + suffix)
            if sidecar.exists() or sidecar.is_symlink():
                self._safe(sidecar)
        if 'identity.json' in self._fds and hasattr(self, 'identity'):
            saved = _json(os.pread(self._fds['identity.json'], 513, 0), 512)
            _require(saved == {'schemaVersion': 1, 'identity': self.identity}
                     and type(saved['schemaVersion']) is int)

    @contextmanager
    def _lease(self, *, validate=True):
        _require(not self._closed and os.getpid() == self._pid)
        _require(self._mutex.acquire(blocking=False), 'worker_busy')
        acquired = False
        try:
            self._check_paths()
            try:
                fcntl.flock(self._fds['journal.lock'], fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ResourceJournalError('worker_busy') from None
            acquired = True
            self._owner = threading.get_ident()
            self._check_paths()
            if validate:
                self._validate()
            yield self
        except (OSError, ValueError, TypeError, sqlite3.Error, RecursionError) as error:
            if isinstance(error, ResourceJournalError):
                raise
            raise ResourceJournalError('journal_unavailable') from None
        finally:
            self._owner = None
            if acquired:
                fcntl.flock(self._fds['journal.lock'], fcntl.LOCK_UN)
            self._mutex.release()

    def locked(self):
        return self._lease()

    def _locked(self):
        _require(not self._closed and os.getpid() == self._pid)
        _require(self._owner == threading.get_ident(), 'lock_required')
        self._check_paths()

    @contextmanager
    def _transaction(self):
        self._check_paths()
        self._db.execute('BEGIN IMMEDIATE')
        try:
            yield
            self._check_paths()
            self._db.execute('COMMIT')
            os.fsync(self._fds['.'])
        except BaseException:
            if self._db.in_transaction:
                self._db.execute('ROLLBACK')
            raise

    def _aggregate(self, rows):
        return _digest({'identity': self.identity, 'version': 1,
                        'rows': [(row['resource_id'], row['digest']) for row in rows]})

    def _schema(self):
        actual = self._db.execute("SELECT type,name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
        _require(actual == [('table', 'metadata'), ('table', 'resources')])
        # SQLite PRAGMAs compare semantics, not brittle CREATE SQL spelling.
        with sqlite3.connect(':memory:') as reference:
            for statement in _SCHEMA:
                reference.execute(statement)
            for table in ('metadata', 'resources'):
                _require(self._db.execute(f'PRAGMA table_info({table})').fetchall()
                         == reference.execute(f'PRAGMA table_info({table})').fetchall())
                def indexes(db):
                    result = []
                    for _, name, unique, origin, partial in db.execute(f'PRAGMA index_list({table})'):
                        _require(re.fullmatch(r'sqlite_autoindex_[a-z]+_[0-9]+', name) is not None)
                        result.append((unique, origin, partial, db.execute(f'PRAGMA index_xinfo({name})').fetchall()))
                    return sorted(result)
                _require(indexes(self._db) == indexes(reference))
                _require(not self._db.execute(f'PRAGMA foreign_key_list({table})').fetchall())

    def _rows(self, resource_id=None):
        # A cursor bounds live full-payload memory to one row. Aggregation and
        # lookup must not load every historical plan merely to update one row.
        query = 'SELECT resource_id,preparation_id,kind,revision,state,code,nonce,'
        query += (
            'CASE WHEN length(CAST(payload AS BLOB))<=? THEN payload ELSE NULL END,'
            'CASE WHEN length(CAST(observation AS BLOB))<=4096 THEN observation ELSE NULL END,digest,'
            'length(CAST(observation AS BLOB)) FROM resources ')
        parameters = [MAX_PAYLOAD_BYTES]
        if resource_id is not None:
            query += 'WHERE resource_id=? '
            parameters.append(resource_id)
        query += 'ORDER BY resource_id LIMIT ?'
        parameters.append(MAX_RESOURCES + 1)
        cursor = self._db.execute(query, parameters)
        for count, values in enumerate(cursor, 1):
            _require(count <= MAX_RESOURCES)
            _require(values[-1] is None or values[-1] <= 4096)
            yield dict(zip(_COLUMNS, values[:-1]))

    def _summaries(self):
        rows = self._db.execute('SELECT resource_id,digest FROM resources ORDER BY resource_id LIMIT ?',
                                (MAX_RESOURCES + 1,)).fetchall()
        _require(len(rows) <= MAX_RESOURCES)
        _require(all(_matches(identity, _ID) and _matches(digest, _DIGEST) for identity, digest in rows))
        return [dict(resource_id=identity, digest=digest) for identity, digest in rows]

    def _validate(self):
        self._schema()
        _require(self._db.execute('PRAGMA quick_check(1)').fetchone() == ('ok',))
        metadata = self._db.execute('SELECT identity,version,count,digest FROM metadata LIMIT 2').fetchall()
        rows = self._summaries()
        _require(metadata == [(self.identity, 1, len(rows), self._aggregate(rows))])
        for row in self._rows():
            self._decode(row)

    def _snapshot(self, plan, stack, catalog, policy, resource_id):
        try:
            _require(_matches(resource_id, _ID), 'invalid_binding')
            verified = verify_resource_plan(plan, stack, catalog, policy)
            _require(any(resource.resourceId == resource_id for resource in verified.resources), 'invalid_binding')
            result = _canonical({'plan': verified.model_dump(mode='json'), 'stack': stack.model_dump(mode='json'),
                                 'policy': policy.model_dump(mode='json'), 'resourceId': resource_id})
            _require(len(result) <= MAX_PAYLOAD_BYTES, 'invalid_binding')
            return result.decode('utf-8')
        except (ValueError, TypeError, AttributeError, RecursionError):
            raise ResourceJournalError('invalid_binding') from None

    def _decode(self, row):
        _require(_matches(row['resource_id'], _ID) and _matches(row['preparation_id'], _ID)
                 and _matches(row['nonce'], _ID) and _matches(row['digest'], _DIGEST))
        _require(type(row['revision']) is int and 1 <= row['revision'] <= _MAX_REVISION)
        _require(row['state'] in _STATE_CODES and row['code'] in _STATE_CODES[row['state']])
        _require(row['digest'] == _digest({'identity': self.identity,
                                         'row': {key: value for key, value in row.items() if key != 'digest'}}))
        saved = _json(row['payload'])
        _require(type(saved) is dict and set(saved) == {'plan', 'stack', 'policy', 'resourceId'})
        plan = ResourcePreparationPlan.model_validate_json(_canonical(saved['plan']))
        stack = MediaStackPlan.model_validate_json(_canonical(saved['stack']))
        policy = WorkerPolicyBinding.model_validate_json(_canonical(saved['policy']))
        for value in (plan, stack):
            _require(value.planHash == _digest(value.model_dump(mode='json', exclude={'planHash'})))
        _require((plan.coreId, plan.homeId, plan.preparationId, plan.platform, plan.catalogDigest, plan.stackPlanHash)
                 == (stack.coreId, stack.homeId, stack.preparationId, stack.platform, stack.catalogDigest, stack.planHash))
        _require((plan.workerPolicyVersion, plan.workerPolicyDigest)
                 == (policy.workerPolicyVersion, policy.workerPolicyDigest))
        for index, component in enumerate(stack.components):
            for proposal in plan.resources[index * 2:index * 2 + 2]:
                _require((proposal.serviceId, proposal.installationId, proposal.operationId, proposal.childPlanHash)
                         == (component.serviceId, component.installationId, component.operationId, component.plan.planHash))
        _require(saved['resourceId'] == row['resource_id'] and plan.preparationId == row['preparation_id'])
        resource = next((item for item in plan.resources if item.resourceId == row['resource_id']), None)
        _require(resource is not None and resource.kind == row['kind'])
        receipt = ResourceReceipt(row['resource_id'], row['preparation_id'], row['kind'], plan.planHash,
                                  policy.workerPolicyDigest, row['state'], row['revision'], row['code'])
        intent = ResourceIntent(resource, self.identity, row['nonce'], _digest(resource.model_dump(mode='json')), receipt)
        if row['observation'] is not None:
            observed = _observation_from_wire(_json(row['observation'], 4096), intent)
            _require((row['state'], row['code']) == self._outcome(observed.status))
        else:
            _require(row['state'] != 'ready' and row['code'] not in
                     {'resource_missing', 'resource_conflict', 'resource_multiple'})
        _require((row['revision'] == 1) == (row['state'] == 'prepared'))
        _require((row['revision'] == 2) == (row['state'] == 'mutating'))
        return intent

    def _find(self, resource_id, *, required=True):
        _require(_matches(resource_id, _ID), 'invalid_binding')
        values = next(self._rows(resource_id), None)
        _require(not required or values is not None, 'resource_not_found')
        return values

    def _write(self, row, *, insert=False):
        row['digest'] = _digest({'identity': self.identity,
                                'row': {key: value for key, value in row.items() if key != 'digest'}})
        self._decode(row)
        with self._transaction():
            if insert:
                self._db.execute('INSERT INTO resources VALUES(?,?,?,?,?,?,?,?,?,?)',
                                 tuple(row[key] for key in _COLUMNS))
            else:
                self._db.execute('UPDATE resources SET revision=?,state=?,code=?,observation=?,digest=? WHERE resource_id=?',
                    (row['revision'], row['state'], row['code'], row['observation'], row['digest'], row['resource_id']))
            rows = self._summaries()
            self._db.execute('UPDATE metadata SET count=?,digest=?', (len(rows), self._aggregate(rows)))
        return self._decode(row).receipt

    @_static
    def prepare(self, plan, stack, catalog, policy, resource_id):
        self._locked()
        payload = self._snapshot(plan, stack, catalog, policy, resource_id)
        old = self._find(resource_id, required=False)
        if old is not None:
            _require(old['payload'] == payload, 'idempotency_conflict')
            return self._decode(old).receipt
        _require(len(self._summaries()) < MAX_RESOURCES, 'journal_capacity')
        resource = next(item for item in plan.resources if item.resourceId == resource_id)
        return self._write(dict(resource_id=resource_id, preparation_id=plan.preparationId, kind=resource.kind,
            revision=1, state='prepared', code='resource_prepared', nonce=secrets.token_hex(16),
            payload=payload, observation=None), insert=True)

    @_static
    def get(self, resource_id):
        self._locked()
        return self._decode(self._find(resource_id)).receipt

    @_static
    def list(self):
        self._locked()
        return tuple(self._decode(row).receipt for row in self._rows())

    def _current(self, resource_id, expected_revision, source=None):
        self._locked()
        row = self._find(resource_id)
        self._decode(row)
        _require(type(expected_revision) is int and expected_revision == row['revision']
                 and expected_revision < _MAX_REVISION, 'revision_conflict')
        if source is not None:
            _require(row['payload'] == self._snapshot(**source, resource_id=resource_id), 'idempotency_conflict')
        return row

    @_static
    def begin(self, resource_id, expected_revision, *, plan, stack, catalog, policy):
        row = self._current(resource_id, expected_revision, dict(plan=plan, stack=stack, catalog=catalog, policy=policy))
        _require(row['state'] not in {'mutating', 'uncertain'}, 'reconciliation_required')
        _require(row['state'] == 'prepared', 'invalid_transition')
        row.update(revision=row['revision'] + 1, state='mutating', code='effect_started')
        self._write(row)
        return self._decode(row)

    @_static
    def mark_uncertain(self, resource_id, expected_revision):
        row = self._current(resource_id, expected_revision)
        _require(row['state'] == 'mutating', 'invalid_transition')
        row.update(revision=row['revision'] + 1, state='uncertain', code='effect_uncertain')
        return self._write(row)

    @staticmethod
    def _outcome(status):
        if status == 'matched':
            return 'ready', 'resource_matched'
        if status == 'unavailable':
            return 'uncertain', 'observation_unavailable'
        return 'needs_attention', 'resource_' + status

    @_static
    def reconcile(self, resource_id, expected_revision, observer, *, plan, stack, catalog, policy):
        row = self._current(resource_id, expected_revision, dict(plan=plan, stack=stack, catalog=catalog, policy=policy))
        _require(row['state'] in {'mutating', 'uncertain'}, 'invalid_transition')
        intent = self._decode(row)
        try:
            observed = observer(intent)
        except Exception:
            state, code, wire = 'uncertain', 'observation_unavailable', None
        else:
            try:
                wire = _canonical(_observation_wire(observed, intent)).decode('utf-8')
                _require(len(wire.encode('utf-8')) <= 4096)
                state, code = self._outcome(observed.status)
            except (ValueError, TypeError, AttributeError, RecursionError):
                state, code, wire = 'needs_attention', 'observation_invalid', None
        # Reentrant callback writes cannot silently overwrite a newer receipt.
        self._current(resource_id, expected_revision)
        row.update(revision=row['revision'] + 1, state=state, code=code, observation=wire)
        return self._write(row)

    def _dispose(self):
        self._closed = True
        if self._db is not None:
            self._db.close()
            self._db = None
        for fd in self._fds.values():
            os.close(fd)
        self._fds.clear()

    def close(self):
        _require(self._mutex.acquire(blocking=False), 'worker_busy')
        try:
            self._dispose()
        finally:
            self._mutex.release()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
