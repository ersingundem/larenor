"""Private, versioned volume observation history; no Engine effects or grants.

Only the resource journal's process lock, retained file descriptors, bounded
SQLite transactions and integrity envelope are reused. This domain redefines
all resource snapshots, receipts and transitions; its domain-separated metadata
rejects even an empty native journal. Existing inode records are never migrated.

A durable observation intent is NOT a creation intent. ``labels_observed`` is a
historical match by a trusted private observer, not proof of creation, exclusive
ownership, attachment safety, UID access or installation readiness. Docker
administrators can copy volume labels. The future verified Engine adapter must
bind fresh response bytes to the intended daemon and request. No reader,
creator, deleter, bootstrap, public route or runtime grant is provided here.
"""
from dataclasses import asdict, dataclass, fields
import secrets
import threading

from .models import Catalog
from .resource_journal import (
    ResourceJournal, ResourceJournalError, _canonical, _digest, _json,
    _matches, _require, _static, _ID, _DIGEST, _MAX_REVISION, MAX_PAYLOAD_BYTES,
)
from .resource_models import WorkerPolicyBinding
from .stack_plan import MediaStackPlan
from .volume_plan import VolumeStoragePlan, verify_volume_plan
from .volume_resources import (
    VolumeBinding, VolumeObservation, VolumeResourceError,
    volume_binding, volume_expected_labels,
)


MAX_VOLUMES = 1792  # 256 preparations, seven private appdata targets each.
_DOMAIN = 'larenor-volume-journal-v1'
_STATES = {
    'prepared': {'volume_prepared'},
    'observing': {'volume_observation_started'},
    'labels_observed': {'volume_labels_observed'},
    'uncertain': {'volume_observation_unavailable'},
    'needs_attention': {'volume_observation_invalid', 'volume_conflict'},
}


class VolumeJournalError(ResourceJournalError):
    """Static diagnostics; private observer exceptions are never propagated."""
    def __init__(self, code):
        super().__init__(code if code in {
            'invalid_volume_binding', 'volume_effects_disabled', 'volume_cancelled',
        } else 'journal_unavailable')


@dataclass(frozen=True, repr=False)
class VolumeReceipt:
    resource_id: str
    preparation_id: str
    operation_id: str
    plan_hash: str
    worker_policy_digest: str
    state: str
    revision: int
    code: str


@dataclass(frozen=True, repr=False)
class VolumeIntent:
    binding: VolumeBinding
    receipt: VolumeReceipt
    specification_digest: str


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {f.name for f in fields(cls)}


def _observed(value, intent):
    _require(_exact(value, VolumeObservation))
    binding = intent.binding
    expected = VolumeObservation(binding.resource_id, binding.resource.name,
        binding.source[0].planHash, _digest(volume_expected_labels(binding)))
    _require(value == expected)
    return asdict(value)


class VolumeJournal(ResourceJournal):
    """Caller-owned private lease for volume observations, never host effects.

    All public resource entry points are replaced by volume-only operations;
    ``begin`` explicitly refuses the native effect-start protocol. ``get`` and
    ``list`` use the volume decoder. The common on-disk safety shell remains
    unchanged, including corruption refusal, file identity, fsync and flock.
    """

    def __repr__(self):
        return 'VolumeJournal(<private>)'

    def _aggregate(self, rows):
        return _digest({'domain': _DOMAIN, 'identity': self.identity, 'version': 1,
                        'rows': [(r['resource_id'], r['digest']) for r in rows]})

    def _summaries(self):
        rows = super()._summaries()
        _require(len(rows) <= MAX_VOLUMES)
        return rows

    def _snapshot(self, plan, stack, catalog, policy, resource_id):
        try:
            _require(_matches(resource_id, _ID))
            verified = verify_volume_plan(plan, stack, catalog, policy)
            _require(any(r.resourceId == resource_id for r in verified.resources))
            result = _canonical({'domain': _DOMAIN, 'plan': verified.model_dump(mode='json'),
                'stack': stack.model_dump(mode='json'), 'catalog': catalog.model_dump(mode='json'),
                'policy': policy.model_dump(mode='json'), 'resourceId': resource_id})
            _require(len(result) <= MAX_PAYLOAD_BYTES)
            return result.decode('utf-8')
        except (ValueError, TypeError, AttributeError, RecursionError):
            raise VolumeJournalError('invalid_volume_binding') from None

    def _decode(self, row):
        try:
            _require(all(_matches(row[k], _ID) for k in ('resource_id', 'preparation_id', 'nonce'))
                     and _matches(row['digest'], _DIGEST))
            _require(type(row['revision']) is int and 1 <= row['revision'] <= _MAX_REVISION
                     and row['kind'] == 'managed_volume' and row['state'] in _STATES
                     and row['code'] in _STATES[row['state']])
            _require(row['digest'] == _digest({'identity': self.identity,
                'row': {k: v for k, v in row.items() if k != 'digest'}}))
            saved = _json(row['payload'])
            _require(type(saved) is dict and set(saved) == {'domain', 'plan', 'stack', 'catalog', 'policy', 'resourceId'}
                     and saved['domain'] == _DOMAIN and saved['resourceId'] == row['resource_id'])
            plan = VolumeStoragePlan.model_validate_json(_canonical(saved['plan']))
            stack = MediaStackPlan.model_validate_json(_canonical(saved['stack']))
            catalog = Catalog.model_validate_json(_canonical(saved['catalog']))
            policy = WorkerPolicyBinding.model_validate_json(_canonical(saved['policy']))
            _require(self._snapshot(plan, stack, catalog, policy, row['resource_id']) == row['payload']
                     and plan.preparationId == row['preparation_id'])
            binding = volume_binding(plan, stack, catalog, policy, row['resource_id'],
                journal_id=self.identity, ownership_nonce=row['nonce'])
            receipt = VolumeReceipt(row['resource_id'], row['preparation_id'], binding.resource.operationId,
                plan.planHash, policy.workerPolicyDigest, row['state'], row['revision'], row['code'])
            intent = VolumeIntent(binding, receipt, _digest(binding.resource.model_dump(mode='json')))
            _require((row['revision'] == 1) == (row['state'] == 'prepared')
                     and (row['revision'] == 2) == (row['state'] == 'observing'))
            if row['observation'] is not None:
                value = _json(row['observation'], 4096)
                _require(type(value) is dict)
                _observed(VolumeObservation(**value), intent)
                _require(row['state'] == 'labels_observed')
            else:
                _require(row['state'] != 'labels_observed')
            return intent
        except (ValueError, TypeError, AttributeError, RecursionError, VolumeResourceError):
            raise ResourceJournalError('journal_unavailable') from None

    @_static
    def prepare(self, plan, stack, catalog, policy, resource_id):
        self._locked()
        payload = self._snapshot(plan, stack, catalog, policy, resource_id)
        old = self._find(resource_id, required=False)
        if old is not None:
            _require(old['payload'] == payload, 'idempotency_conflict')
            return self._decode(old).receipt
        _require(len(self._summaries()) < MAX_VOLUMES, 'journal_capacity')
        return self._write(dict(resource_id=resource_id, preparation_id=plan.preparationId,
            kind='managed_volume', revision=1, state='prepared', code='volume_prepared',
            nonce=secrets.token_hex(16), payload=payload, observation=None), insert=True)

    def begin(self, *args, **kwargs):
        """The native resource effect API is never available on this journal."""
        raise VolumeJournalError('volume_effects_disabled')

    @_static
    def bind(self, resource_id, expected_revision, *, plan, stack, catalog, policy):
        row = self._current(resource_id, expected_revision,
            dict(plan=plan, stack=stack, catalog=catalog, policy=policy))
        return self._decode(row)

    @_static
    def begin_observation(self, resource_id, expected_revision, *, plan, stack, catalog, policy):
        row = self._current(resource_id, expected_revision,
            dict(plan=plan, stack=stack, catalog=catalog, policy=policy))
        _require(row['state'] not in {'observing', 'uncertain'}, 'reconciliation_required')
        _require(row['state'] == 'prepared', 'invalid_transition')
        row.update(revision=2, state='observing', code='volume_observation_started')
        self._write(row)
        return self._decode(row)

    @_static
    def mark_uncertain(self, resource_id, expected_revision):
        row = self._current(resource_id, expected_revision)
        _require(row['state'] == 'observing', 'invalid_transition')
        row.update(revision=row['revision'] + 1, state='uncertain', code='volume_observation_unavailable')
        return self._write(row)

    @_static
    def reconcile(self, resource_id, expected_revision, observer, *, plan, stack, catalog, policy, cancelled=None):
        _require(callable(observer) and (cancelled is None or type(cancelled) is threading.Event), 'invalid_binding')
        source = dict(plan=plan, stack=stack, catalog=catalog, policy=policy)
        row = self._current(resource_id, expected_revision, source)
        _require(row['state'] in {'observing', 'uncertain'}, 'invalid_transition')
        if cancelled is not None and cancelled.is_set():
            raise VolumeJournalError('volume_cancelled')
        intent = self._decode(row)
        wire = None
        try:
            result = observer(intent)
        except VolumeResourceError as error:
            state, code = ('needs_attention', 'volume_conflict') if error.code == 'volume_conflict' else (
                'uncertain', 'volume_observation_unavailable')
        except Exception:
            state, code = 'uncertain', 'volume_observation_unavailable'
        else:
            try:
                wire = _canonical(_observed(result, intent)).decode('utf-8')
                _require(len(wire.encode('utf-8')) <= 4096)
                state, code = 'labels_observed', 'volume_labels_observed'
            except (ValueError, TypeError, AttributeError, RecursionError, VolumeResourceError):
                state, code = 'needs_attention', 'volume_observation_invalid'
        # The observer can reenter or mutate alias inputs. Neither may publish
        # an old result into newer state. Re-derive the complete source again.
        self._current(resource_id, expected_revision, source)
        if cancelled is not None and cancelled.is_set():
            state, code, wire = 'uncertain', 'volume_observation_unavailable', None
        row.update(revision=row['revision'] + 1, state=state, code=code, observation=wire)
        return self._write(row)
