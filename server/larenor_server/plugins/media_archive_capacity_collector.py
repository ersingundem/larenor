"""One-attempt capacity read bound to current Larenor-owned Jellyfin proofs.

This worker-only adapter receives an already verified managed-resource proof and
passes only the owned volume name and opaque identities to its bounded reader.
It never receives or discovers a host mount path, lists volumes, retries a read,
or exposes any storage mutation. The existing Core weekly trend store remains
the only snapshot journal writer.
"""

from dataclasses import dataclass, fields
import re
import time

from pydantic import Field, ValidationError, model_validator

from ..models import StrictModel
from .managed_container import ManagedVolumeProof, VerifiedJellyfinResources
from .media_archive_core_models import PrivateMediaArchiveCollection
from .media_archive_health_models import (
    ArchiveSourceBinding,
    MediaArchiveCapacityEvidence,
    MediaArchiveObservation,
)


_ID = re.compile(r'[0-9a-f]{32}\Z')
_DIGEST = re.compile(r'[0-9a-f]{64}\Z')
_TARGETS = ('/config', '/cache', '/media')


class MediaArchiveCapacityCollectorError(Exception):
    _CODES = frozenset({
        'capacity_binding_unavailable', 'capacity_authority_changed',
        'capacity_deadline_exceeded', 'capacity_cancelled',
        'capacity_result_unavailable',
    })

    def __init__(self, code='capacity_result_unavailable'):
        self.code = code if code in self._CODES else 'capacity_result_unavailable'
        super().__init__(self.code)

    def __repr__(self):
        return f'MediaArchiveCapacityCollectorError({self.code!r})'


@dataclass(frozen=True, repr=False)
class OwnedJellyfinCapacityBinding:
    installationId: str
    installationRevision: int
    serviceRecordId: str
    serviceRevision: int
    snapshotRevision: int
    volumeResourceId: str
    volumeRevision: int
    volumeName: str
    volumePlanHash: str
    workerPolicyDigest: str


class OwnedVolumeCapacitySnapshot(StrictModel):
    volumeResourceId: str = Field(pattern=r'^[0-9a-f]{32}$')
    volumeRevision: int = Field(ge=1, le=2**63 - 1)
    totalBytes: int = Field(gt=0, le=2**63 - 1)
    freeBytes: int = Field(ge=0, le=2**63 - 1)

    @model_validator(mode='after')
    def coherent(self):
        if self.freeBytes > self.totalBytes:
            raise ValueError('invalid_owned_volume_capacity')
        return self


def _exact(value, kind):
    try:
        return type(value) is kind and set(vars(value)) == {
            item.name for item in fields(kind)}
    except (TypeError, AttributeError):
        return False


def _private(value):
    if type(value) is not PrivateMediaArchiveCollection:
        raise MediaArchiveCapacityCollectorError('capacity_binding_unavailable')
    try:
        return PrivateMediaArchiveCollection.model_validate(
            value.model_dump(mode='python'))
    except (ValidationError, ValueError, TypeError, AttributeError,
            RecursionError, OverflowError):
        raise MediaArchiveCapacityCollectorError(
            'capacity_binding_unavailable') from None


def _volume(value):
    if (not _exact(value, ManagedVolumeProof)
            or _ID.fullmatch(value.resource_id) is None
            or _ID.fullmatch(value.operation_id) is None
            or _ID.fullmatch(value.journal_id) is None
            or _ID.fullmatch(value.ownership_nonce) is None
            or type(value.revision) is not int or value.revision < 1
            or value.target not in _TARGETS
            or value.bootstrap_verified is not True):
        raise MediaArchiveCapacityCollectorError(
            'capacity_binding_unavailable')
    prefix = 'library' if value.target == '/media' else 'appdata'
    if value.name != f'larenor-{prefix}-v1-{value.resource_id}':
        raise MediaArchiveCapacityCollectorError(
            'capacity_binding_unavailable')
    return value


def bind_owned_jellyfin_capacity(private, proof):
    selected = _private(private)
    if (not _exact(proof, VerifiedJellyfinResources)
            or any(_DIGEST.fullmatch(value) is None for value in (
                proof.stack_plan_hash, proof.resource_plan_hash,
                proof.volume_plan_hash, proof.worker_policy_digest))
            or type(proof.volumes) is not tuple or len(proof.volumes) != 3):
        raise MediaArchiveCapacityCollectorError(
            'capacity_binding_unavailable')
    volumes = tuple(_volume(value) for value in proof.volumes)
    if (tuple(value.target for value in volumes) != _TARGETS
            or len({value.resource_id for value in volumes}) != 3
            or len({value.operation_id for value in volumes}) != 3
            or len({value.ownership_nonce for value in volumes}) != 3
            or len({value.journal_id for value in volumes}) != 1):
        raise MediaArchiveCapacityCollectorError(
            'capacity_binding_unavailable')
    sources = [item for item in selected.authority.sources
               if item.serviceId == 'jellyfin']
    if len(sources) != 1:
        raise MediaArchiveCapacityCollectorError(
            'capacity_binding_unavailable')
    source = sources[0]
    media = volumes[-1]
    return OwnedJellyfinCapacityBinding(
        installationId=selected.authority.installationId,
        installationRevision=selected.authority.installationRevision,
        serviceRecordId=source.serviceRecordId,
        serviceRevision=source.serviceRevision,
        snapshotRevision=source.snapshotRevision,
        volumeResourceId=media.resource_id,
        volumeRevision=media.revision,
        volumeName=media.name,
        volumePlanHash=proof.volume_plan_hash,
        workerPolicyDigest=proof.worker_policy_digest,
    )


def _active(gate):
    try:
        if gate() is not True:
            raise ValueError()
    except Exception:
        raise MediaArchiveCapacityCollectorError('capacity_cancelled') from None


class MediaArchiveCapacityCollector:
    """Reads one owned volume once, then rebinds all current proof revisions."""

    def __init__(self, proof_provider, reader):
        try:
            valid = (callable(getattr(proof_provider, 'current', None))
                     and callable(getattr(reader, 'read', None)))
        except Exception:
            valid = False
        if not valid:
            raise MediaArchiveCapacityCollectorError()
        self._proof_provider = proof_provider
        self._reader = reader

    def _binding(self, private, *, changed=False):
        try:
            proof = self._proof_provider.current(
                private.authority.installationId,
                private.authority.installationRevision)
            return bind_owned_jellyfin_capacity(private, proof)
        except MediaArchiveCapacityCollectorError:
            if changed:
                raise MediaArchiveCapacityCollectorError(
                    'capacity_authority_changed') from None
            raise
        except Exception:
            code = ('capacity_authority_changed' if changed
                    else 'capacity_binding_unavailable')
            raise MediaArchiveCapacityCollectorError(code) from None

    def collect(self, private, *, deadline, gate):
        selected = _private(private)
        now = time.monotonic()
        if (type(deadline) not in (int, float) or type(deadline) is bool
                or not callable(gate) or not now < deadline <= now + 5):
            raise MediaArchiveCapacityCollectorError(
                'capacity_deadline_exceeded')
        _active(gate)
        binding = self._binding(selected)
        _active(gate)
        if time.monotonic() >= deadline:
            raise MediaArchiveCapacityCollectorError(
                'capacity_deadline_exceeded')
        try:
            value = self._reader.read(
                binding, deadline=deadline, gate=gate)
        except MediaArchiveCapacityCollectorError:
            raise
        except Exception:
            raise MediaArchiveCapacityCollectorError(
                'capacity_result_unavailable') from None
        if time.monotonic() >= deadline:
            raise MediaArchiveCapacityCollectorError(
                'capacity_deadline_exceeded')
        _active(gate)
        if self._binding(selected, changed=True) != binding:
            raise MediaArchiveCapacityCollectorError(
                'capacity_authority_changed')
        if time.monotonic() >= deadline:
            raise MediaArchiveCapacityCollectorError(
                'capacity_deadline_exceeded')
        try:
            if type(value) is not OwnedVolumeCapacitySnapshot:
                raise ValueError()
            result = OwnedVolumeCapacitySnapshot.model_validate(
                value.model_dump(mode='python'))
        except (ValidationError, ValueError, TypeError, AttributeError,
                RecursionError, OverflowError):
            raise MediaArchiveCapacityCollectorError(
                'capacity_result_unavailable') from None
        if (result.volumeResourceId != binding.volumeResourceId
                or result.volumeRevision != binding.volumeRevision):
            raise MediaArchiveCapacityCollectorError(
                'capacity_authority_changed')
        _active(gate)
        return MediaArchiveCapacityEvidence(
            source='jellyfin', serviceRevision=binding.serviceRevision,
            snapshotRevision=binding.snapshotRevision, state='verified',
            totalBytes=result.totalBytes, freeBytes=result.freeBytes)

    def __repr__(self):
        return 'MediaArchiveCapacityCollector(<private>)'


def _matches(private, observation):
    expected = {item.serviceId: item for item in private.authority.sources}
    returned = {
        item.serviceId: ArchiveSourceBinding.model_validate(item.model_dump(
            include=set(ArchiveSourceBinding.model_fields), mode='python'))
        for item in (observation.jellyfin, observation.sonarr,
                     observation.radarr, observation.qbittorrent)
    }
    return expected == returned


class CapacityEnrichedMediaArchiveCollector:
    """Decorates the existing read-only collector without changing its transport."""

    def __init__(self, archive, capacity):
        try:
            valid = (callable(getattr(archive, 'collect', None))
                     and type(capacity) is MediaArchiveCapacityCollector)
        except Exception:
            valid = False
        if not valid:
            raise MediaArchiveCapacityCollectorError()
        self._archive = archive
        self._capacity = capacity

    def open(self, deadline):
        opening = getattr(self._archive, 'open', None)
        if callable(opening):
            opening(deadline)

    def close(self):
        closing = getattr(self._archive, 'close', None)
        if callable(closing):
            closing()

    def collect(self, private, *, deadline, gate):
        selected = _private(private)
        _active(gate)
        try:
            value = self._archive.collect(
                selected, deadline=deadline, gate=gate)
            if type(value) is not MediaArchiveObservation:
                raise ValueError()
            observation = MediaArchiveObservation.model_validate(
                value.model_dump(mode='python'))
        except MediaArchiveCapacityCollectorError:
            raise
        except Exception:
            raise MediaArchiveCapacityCollectorError(
                'capacity_result_unavailable') from None
        if not _matches(selected, observation):
            raise MediaArchiveCapacityCollectorError(
                'capacity_authority_changed')
        capacity = self._capacity.collect(
            selected, deadline=deadline, gate=gate)
        _active(gate)
        try:
            return MediaArchiveObservation.model_validate({
                **observation.model_dump(mode='python'),
                'capacity': capacity.model_dump(mode='python'),
            })
        except (ValidationError, ValueError, TypeError, AttributeError,
                RecursionError, OverflowError):
            raise MediaArchiveCapacityCollectorError(
                'capacity_authority_changed') from None

    def __repr__(self):
        return 'CapacityEnrichedMediaArchiveCollector(<private>)'
