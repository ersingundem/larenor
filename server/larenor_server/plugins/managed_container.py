"""Worker-only Jellyfin container binding from fresh typed resource proofs.

The proof provider is a trusted in-process broker. It must freshly reconcile
the private image, volume, bootstrap and network journals against one Engine;
none of these proof types is an API or IPC schema. This module derives the only
accepted Docker create specification and never accepts caller Docker options.
"""

from dataclasses import dataclass, field, fields
import json
import re
import threading

from .docker_probe import DockerEndpoint
from .image_resources import ImageObservation, UnixImageEngine, image_binding
from .models import Catalog
from .network_resources import NetworkListObservation, network_binding
from .network_transport import UnixNetworkEngine
from .resource_journal import NetworkIdentity, ResourceJournal, _digest as _resource_digest
from .resource_models import WorkerPolicyBinding
from .resource_plan import build_resource_plan, _wire
from .stack_plan import MediaStackPlan, verify_media_stack_plan
from .volume_create_journal import VolumeCreateJournal
from .volume_plan import build_volume_plan
from .volume_resources import VolumeObservation, volume_expected_labels
from .volume_transport import UnixVolumeReader
from .worker import (
    _FORBIDDEN_OBSERVED, _LABELS, _REFERENCE, DockerWorkerError,
    JournaledContainerOperations, WorkerJournal, _canonical, _decode,
)


_ID = re.compile(r'[0-9a-f]{32}\Z')
_HASH = re.compile(r'[0-9a-f]{64}\Z')
_IMAGE = re.compile(r'sha256:[0-9a-f]{64}\Z')
_NETWORK = re.compile(r'larenor-control-[0-9a-f]{32}\Z')
_VOLUME = re.compile(r'larenor-appdata-v1-[0-9a-f]{32}\Z')


class ManagedContainerError(Exception):
    def __init__(self, code='resources_untrusted'):
        self.code = code if code in {
            'invalid_installation_plan', 'resources_unavailable', 'resources_untrusted',
        } else 'resources_untrusted'
        super().__init__(self.code)


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {item.name for item in fields(cls)}


def _identity(value, expression=_ID):
    return type(value) is str and expression.fullmatch(value) is not None


@dataclass(frozen=True, repr=False)
class ManagedImageProof:
    resource_id: str
    revision: int
    image_id: str
    image_configuration: bytes = field(repr=False)


@dataclass(frozen=True, repr=False)
class ManagedVolumeProof:
    resource_id: str
    operation_id: str
    revision: int
    journal_id: str
    ownership_nonce: str
    name: str
    target: str
    bootstrap_verified: bool


@dataclass(frozen=True, repr=False)
class ManagedNetworkProof:
    resource_id: str
    operation_id: str
    revision: int
    journal_id: str
    ownership_nonce: str
    name: str
    network_id: str


@dataclass(frozen=True, repr=False)
class VerifiedJellyfinResources:
    stack_plan_hash: str
    resource_plan_hash: str
    volume_plan_hash: str
    worker_policy_digest: str
    image: ManagedImageProof
    volumes: tuple[ManagedVolumeProof, ManagedVolumeProof]
    network: ManagedNetworkProof


@dataclass(frozen=True, repr=False)
class VolumeBootstrapObservation:
    """Worker-private result from the fixed helper, never an IPC value."""

    resource_id: str
    operation_id: str
    journal_id: str
    ownership_nonce: str
    revision: int
    name: str
    target: str
    state: str


class JellyfinEngineReaders:
    """Fixed read-only Engine adapters plus an endpoint-bound bootstrap reader.

    The image, volume and network transports are constructed here from the one
    operator-owned endpoint. Bootstrap remains a separate privileged helper,
    but it must retain that exact endpoint object and expose only ``verify``.
    Neither arbitrary Engine readers nor caller-selected transport methods can
    be substituted at the proof-broker boundary.
    """

    def __init__(self, endpoint, bootstrap_verifier, *, peer_uid=None):
        try:
            if (type(endpoint) is not DockerEndpoint
                    or getattr(bootstrap_verifier, '_endpoint', None) is not endpoint
                    or not callable(getattr(bootstrap_verifier, 'verify', None))
                    or peer_uid is not None and not callable(peer_uid)):
                raise ValueError()
            self._endpoint = endpoint
            self._bootstrap = bootstrap_verifier
            self._images = UnixImageEngine(endpoint, peer_uid=peer_uid)
            self._volumes = UnixVolumeReader(endpoint, peer_uid=peer_uid)
            self._networks = UnixNetworkEngine(endpoint, peer_uid=peer_uid)
        except (ValueError, TypeError, AttributeError, RecursionError):
            raise ManagedContainerError('resources_untrusted') from None

    def inspect_image(self, binding, *, cancelled):
        return self._images.inspect(binding, cancelled=cancelled)

    def inspect_volume(self, intent, *, cancelled):
        return self._volumes.inspect(intent.binding, cancelled=cancelled)

    def verify_bootstrap(self, intent, *, cancelled):
        if (getattr(self._bootstrap, '_endpoint', None) is not self._endpoint
                or not callable(getattr(self._bootstrap, 'verify', None))):
            raise ManagedContainerError('resources_unavailable')
        return self._bootstrap.verify(intent, cancelled=cancelled)

    def list_network(self, binding, intent, *, cancelled):
        return self._networks.list(binding, intent, cancelled=cancelled)

    def inspect_network(self, binding, intent, network_id, *, cancelled):
        return self._networks.inspect(
            binding, intent, network_id, cancelled=cancelled,
        )


class JellyfinResourceProofBroker:
    """Rebind retained intents and require fresh reads from one Engine seam.

    The composite reader is operator-owned and must expose one opaque endpoint
    identity plus fixed image, volume, bootstrap and network read methods. The
    broker never turns a terminal journal receipt into a current proof by
    itself; every resource is observed again while both journals stay locked.
    """

    def __init__(self, stack, catalog, policy, resource_journal, volume_journal,
                 readers, *, engine_identity):
        try:
            methods = ('inspect_image', 'inspect_volume', 'verify_bootstrap',
                       'list_network', 'inspect_network')
            if (type(stack) is not MediaStackPlan or type(catalog) is not Catalog
                    or type(policy) is not WorkerPolicyBinding
                    or type(resource_journal) is not ResourceJournal
                    or type(volume_journal) is not VolumeCreateJournal
                    or getattr(readers, '_endpoint', None) is not engine_identity
                    or not all(callable(getattr(readers, name, None)) for name in methods)):
                raise ValueError()
            self.stack = MediaStackPlan.model_validate_json(_wire(stack))
            self.catalog = Catalog.model_validate_json(_wire(catalog))
            self.policy = WorkerPolicyBinding.model_validate_json(_wire(policy))
            self.resource_journal = resource_journal
            self.volume_journal = volume_journal
            self.readers = readers
        except (ValueError, TypeError, AttributeError, RecursionError):
            raise ManagedContainerError('resources_untrusted') from None

    def __call__(self, resource_plan, volume_plan, component):
        try:
            expected_resources = build_resource_plan(self.stack, self.catalog, self.policy)
            expected_volumes = build_volume_plan(self.stack, self.catalog, self.policy)
            selected = next(item for item in self.stack.components if item.serviceId == 'jellyfin')
            if (resource_plan != expected_resources or volume_plan != expected_volumes
                    or component != selected):
                raise ValueError()
            source = dict(stack=self.stack, catalog=self.catalog, policy=self.policy)
            image_resource = next(item for item in resource_plan.resources
                                  if item.kind == 'ensure_image' and item.serviceId == 'jellyfin')
            network_resource = next(item for item in resource_plan.resources
                                    if item.kind == 'prepare_control_network')
            volume_resources = tuple(item for item in volume_plan.resources
                                     if item.serviceId == 'jellyfin')
            if len(volume_resources) != 2:
                raise ValueError()
            cancelled = threading.Event()
            with self.resource_journal.locked(), self.volume_journal.locked():
                image_receipt = self.resource_journal.get(image_resource.resourceId)
                network_receipt = self.resource_journal.get(network_resource.resourceId)
                image_intent = self.resource_journal.bind(
                    image_resource.resourceId, image_receipt.revision,
                    plan=resource_plan, **source)
                network_intent = self.resource_journal.bind(
                    network_resource.resourceId, network_receipt.revision,
                    plan=resource_plan, **source)
                volume_intents = []
                for resource in volume_resources:
                    receipt = self.volume_journal.get(resource.resourceId)
                    intent = self.volume_journal.bind(
                        resource.resourceId, receipt.revision, plan=volume_plan, **source)
                    if intent.receipt.state != 'observed_requires_bootstrap':
                        raise ValueError()
                    volume_intents.append(intent)

                selected_image = image_binding(
                    resource_plan, self.stack, self.catalog, self.policy,
                    image_resource.resourceId)
                image = self.readers.inspect_image(selected_image, cancelled=cancelled)
                if (not _exact(image, ImageObservation)
                        or image.image_id != selected_image.config_digest
                        or type(image.configuration) is not bytes):
                    raise ValueError()

                volume_proofs = []
                for intent in volume_intents:
                    observed = self.readers.inspect_volume(intent, cancelled=cancelled)
                    binding = intent.binding
                    expected_observation = VolumeObservation(
                        binding.resource_id, binding.resource.name,
                        binding.source[0].planHash,
                        _resource_digest(volume_expected_labels(binding)),
                    )
                    if not _exact(observed, VolumeObservation) or observed != expected_observation:
                        raise ValueError()
                    bootstrap = self.readers.verify_bootstrap(intent, cancelled=cancelled)
                    receipt = intent.receipt
                    expected_bootstrap = VolumeBootstrapObservation(
                        binding.resource_id, binding.resource.operationId,
                        binding.journal_id, binding.ownership_nonce, receipt.revision,
                        binding.resource.name, binding.resource.target, 'root_verified',
                    )
                    if (not _exact(bootstrap, VolumeBootstrapObservation)
                            or bootstrap != expected_bootstrap):
                        raise ValueError()
                    volume_proofs.append(ManagedVolumeProof(
                        binding.resource_id, binding.resource.operationId,
                        receipt.revision, binding.journal_id, binding.ownership_nonce,
                        binding.resource.name, binding.resource.target, True,
                    ))

                selected_network = network_binding(
                    resource_plan, self.stack, self.catalog, self.policy,
                    network_resource.resourceId)
                listed = self.readers.list_network(
                    selected_network, network_intent, cancelled=cancelled)
                if (not _exact(listed, NetworkListObservation)
                        or listed.state != 'candidate' or not _identity(listed.network_id, _HASH)):
                    raise ValueError()
                network = self.readers.inspect_network(
                    selected_network, network_intent, listed.network_id,
                    cancelled=cancelled)
                if (not _exact(network, NetworkIdentity)
                        or network.network_id != listed.network_id):
                    raise ValueError()

                # Rebind after every external read. A raw/reentrant journal
                # change cannot publish a proof from the earlier revision.
                if self.resource_journal.bind(
                        image_resource.resourceId, image_receipt.revision,
                        plan=resource_plan, **source) != image_intent:
                    raise ValueError()
                if self.resource_journal.bind(
                        network_resource.resourceId, network_receipt.revision,
                        plan=resource_plan, **source) != network_intent:
                    raise ValueError()
                for intent in volume_intents:
                    if self.volume_journal.bind(
                            intent.binding.resource_id, intent.receipt.revision,
                            plan=volume_plan, **source) != intent:
                        raise ValueError()

            return VerifiedJellyfinResources(
                stack_plan_hash=resource_plan.stackPlanHash,
                resource_plan_hash=resource_plan.planHash,
                volume_plan_hash=volume_plan.planHash,
                worker_policy_digest=self.policy.workerPolicyDigest,
                image=ManagedImageProof(
                    image_resource.resourceId, image_receipt.revision,
                    image.image_id, image.configuration),
                volumes=tuple(volume_proofs),
                network=ManagedNetworkProof(
                    network_resource.resourceId, network_resource.operationId,
                    network_receipt.revision, network_intent.journal_id,
                    network_intent.ownership_nonce, network_resource.name,
                    network.network_id),
            )
        except Exception:
            raise ManagedContainerError('resources_unavailable') from None


@dataclass(frozen=True, repr=False)
class ManagedContainerMount:
    name: str
    target: str

    def __repr__(self):
        return 'ManagedContainerMount(<private>)'


@dataclass(frozen=True, repr=False)
class ManagedContainerBinding:
    name: str
    platform: str
    image_id: str
    network_id: str
    mounts: tuple[ManagedContainerMount, ManagedContainerMount] = field(repr=False)
    specification: bytes = field(repr=False)
    image_configuration: bytes = field(repr=False)

    def __repr__(self):
        return 'ManagedContainerBinding(<private>)'

    @property
    def labels(self):
        return _decode(self.specification, 65536)['Labels']

    def payload(self):
        return {
            'name': self.name,
            'platform': self.platform,
            'image_id': self.image_id,
            'network_id': self.network_id,
            'mounts': [{'name': item.name, 'target': item.target} for item in self.mounts],
            'specification': _decode(self.specification, 65536),
            'image_configuration': _decode(self.image_configuration, 65536),
        }


def _binding_parts(value):
    if (not _exact(value, ManagedContainerBinding)
            or not _identity(value.name.removeprefix('larenor-'))
            or value.name != 'larenor-' + value.name.removeprefix('larenor-')
            or value.platform not in {'linux/amd64', 'linux/arm64'}
            or not _identity(value.image_id, _IMAGE)
            or not _identity(value.network_id, _HASH)
            or type(value.mounts) is not tuple or len(value.mounts) != 2):
        raise ValueError()
    body = _decode(value.specification, 65536)
    inherited = _configuration(value.image_configuration,
                               tuple(item.target for item in value.mounts))
    if set(body) != {'Image', 'User', 'Labels', 'Env', 'HostConfig'}:
        raise ValueError()
    host = body['HostConfig']
    labels = body['Labels']
    environment = body['Env']
    expected_host = {'Privileged', 'CapDrop', 'CapAdd', 'SecurityOpt', 'NetworkMode',
                     'Memory', 'NanoCpus', 'PidsLimit', 'ReadonlyRootfs', 'Init',
                     'Tmpfs', 'Mounts', 'RestartPolicy'}
    if (type(host) is not dict or set(host) != expected_host
            or host['Privileged'] is not False or host['CapDrop'] != ['ALL']
            or host['CapAdd'] != [] or host['SecurityOpt'] != ['no-new-privileges:true']
            or not _identity(host['NetworkMode'], _NETWORK)
            or body['User'] != '1000:1000' or type(body['Image']) is not str
            or _REFERENCE.fullmatch(body['Image']) is None
            or type(labels) is not dict or set(labels) != set(_LABELS)
            or any(type(labels[key]) is not str
                   or re.fullmatch(r'[0-9a-f]{' + str(length) + r'}', labels[key]) is None
                   for key, length in _LABELS.items())
            or labels['org.larenor.installation'] != value.name.removeprefix('larenor-')
            or type(environment) is not list or len(environment) > 4
            or not all(type(item) is str and re.fullmatch(
                r'(?:TZ|PORT|WEBUI_PORT|TORRENTING_PORT)=[A-Za-z0-9/_-]{1,80}', item)
                       for item in environment)
            or len({item.partition('=')[0] for item in environment}) != len(environment)
            or host['RestartPolicy'] != {'Name': 'no'}
            or host['ReadonlyRootfs'] is not True or type(host['Init']) is not bool):
        raise ValueError()
    for key, minimum, maximum in (
            ('Memory', 128 * 1048576, 16384 * 1048576),
            ('NanoCpus', 100000000, 16000000000), ('PidsLimit', 32, 4096)):
        if type(host[key]) is not int or not minimum <= host[key] <= maximum:
            raise ValueError()
    if type(host['Tmpfs']) is not dict:
        raise ValueError()
    for target, options in host['Tmpfs'].items():
        if (target not in {'/run', '/tmp'} or type(options) is not str
                or re.fullmatch(
                    r'rw,nosuid,nodev,(?:noexec|exec),size=[0-9]{2,3}m,'
                    r'uid=(?:0|1000),gid=(?:0|1000),mode=1777', options) is None):
            raise ValueError()
    expected_mounts = []
    for item in value.mounts:
        if (not _exact(item, ManagedContainerMount) or not _identity(item.name, _VOLUME)
                or item.target not in {'/config', '/cache'}):
            raise ValueError()
        expected_mounts.append({'Type': 'volume', 'Source': item.name, 'Target': item.target,
                                'ReadOnly': False, 'VolumeOptions': {'NoCopy': True}})
    if host['Mounts'] != expected_mounts or len({item.target for item in value.mounts}) != 2:
        raise ValueError()
    return body, inherited


def managed_container_matches(value, binding):
    """Match a fresh full-ID inspect without exposing paths or Engine values."""
    try:
        body, inherited = _binding_parts(binding)
        if (type(value) is not dict or not _identity(value.get('Id'), _HASH)
                or value.get('Name') != '/' + binding.name
                or value.get('Image') != binding.image_id):
            return False
        config, host = value.get('Config'), value.get('HostConfig')
        if type(config) is not dict or type(host) is not dict:
            return False
        expected = {key: item for key, item in body.items() if key != 'HostConfig'}
        inherited_env = {item.partition('=')[0]: item for item in inherited.get('Env') or []}
        inherited_env.update({item.partition('=')[0]: item for item in body.get('Env') or []})
        if (type(config.get('Env')) is not list
                or not all(type(item) is str for item in config['Env'])
                or sorted(config['Env']) != sorted(inherited_env.values())):
            return False
        expected['Labels'] = {**(inherited.get('Labels') or {}), **body['Labels']}
        for key, item in expected.items():
            if key != 'Env' and config.get(key) != item:
                return False
        for key in ('Cmd', 'Entrypoint', 'WorkingDir', 'Volumes', 'Healthcheck',
                    'StopSignal', 'Shell'):
            if (config.get(key) or None) != (inherited.get(key) or None):
                return False
        if any(config.get(key) not in (None, False) for key in ('Tty', 'OpenStdin', 'StdinOnce')):
            return False
        for key, item in body['HostConfig'].items():
            expected_item = {'Name': 'no', 'MaximumRetryCount': 0} if key == 'RestartPolicy' else item
            if host.get(key) != expected_item:
                return False
        if not all(host.get(key) in allowed for key, allowed in _FORBIDDEN_OBSERVED.items()
                   if key != 'Mounts'):
            return False
        observed_mounts = value.get('Mounts')
        if type(observed_mounts) is not list or len(observed_mounts) != len(binding.mounts):
            return False
        by_target = {item.target: item for item in binding.mounts}
        seen = set()
        for mount in observed_mounts:
            if type(mount) is not dict or set(mount) != {
                    'Type', 'Name', 'Source', 'Destination', 'Driver', 'Mode', 'RW', 'Propagation'}:
                return False
            expected_mount = by_target.get(mount.get('Destination'))
            if (expected_mount is None or mount.get('Type') != 'volume'
                    or mount.get('Name') != expected_mount.name or mount.get('Driver') != 'local'
                    or mount.get('RW') is not True or type(mount.get('Source')) is not str
                    or not 1 <= len(mount['Source']) <= 4096
                    or mount.get('Mode') not in ('', 'z') or mount.get('Propagation') not in ('', 'rprivate')):
                return False
            seen.add(mount['Destination'])
        if seen != set(by_target):
            return False
        networks = (value.get('NetworkSettings') or {}).get('Networks')
        if type(networks) is not dict or set(networks) != {body['HostConfig']['NetworkMode']}:
            return False
        attached = networks[body['HostConfig']['NetworkMode']]
        return type(attached) is dict and attached.get('NetworkID') == binding.network_id
    except (ValueError, TypeError, AttributeError, KeyError, RecursionError):
        return False


class ManagedWorkerJournal(WorkerJournal):
    """Version-2 container journal; legacy mount-free rows never cross domains."""

    def __init__(self, directory, *, initialize=False):
        super().__init__(directory, initialize=initialize, _version=2)

    @staticmethod
    def _stored_binding(row):
        try:
            payload = _decode(row['payload'], 65536)
            value = payload['binding']
            if type(value) is not dict or set(value) != {
                    'name', 'platform', 'image_id', 'network_id', 'mounts',
                    'specification', 'image_configuration'}:
                raise ValueError()
            mounts = value['mounts']
            if type(mounts) is not list or len(mounts) != 2:
                raise ValueError()
            binding = ManagedContainerBinding(
                value['name'], value['platform'], value['image_id'], value['network_id'],
                tuple(ManagedContainerMount(**item) for item in mounts),
                _canonical(value['specification']), _canonical(value['image_configuration']),
            )
            _binding_parts(binding)
            return binding
        except (ValueError, TypeError, AttributeError, KeyError, DockerWorkerError, RecursionError):
            raise DockerWorkerError('journal_unavailable') from None


class JournaledManagedContainerOperations(JournaledContainerOperations):
    """Create/start only exact, freshly rebuilt managed Jellyfin bindings."""

    def __init__(self, journal, engine):
        if type(journal) is not ManagedWorkerJournal:
            raise DockerWorkerError('invalid_command')
        super().__init__(journal, engine)

    @staticmethod
    def _binding(value):
        try:
            _binding_parts(value)
            return value
        except (ValueError, TypeError, AttributeError, DockerWorkerError, RecursionError):
            raise DockerWorkerError('invalid_command') from None

    @staticmethod
    def _matches(value, binding):
        return managed_container_matches(value, binding)

    def _create(self, binding):
        return self.engine.create_managed_container(binding)


def _pairs(values):
    result = {}
    for key, value in values:
        if type(key) is not str or key in result:
            raise ValueError()
        result[key] = value
    return result


def _configuration(raw, targets):
    if type(raw) is not bytes or not 2 <= len(raw) <= 65536:
        raise ValueError()
    value = json.loads(raw.decode('utf-8'), object_pairs_hook=_pairs,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    if type(value) is not dict or _canonical(value) != raw:
        raise ValueError()
    volumes = value.get('Volumes')
    if type(volumes) is not dict or set(volumes) != set(targets) or any(
            item not in (None, {}) for item in volumes.values()):
        raise ValueError()
    labels = value.get('Labels') or {}
    if type(labels) is not dict or any(type(key) is not str or type(item) is not str
                                      for key, item in labels.items()):
        raise ValueError()
    if any(key.startswith('org.larenor.') for key in labels):
        raise ValueError()
    return value


class JellyfinBindingBuilder:
    """Re-derive a private, ports-off Jellyfin binding on every worker call."""

    def __init__(self, catalog, policy, container_journal_id, proof_provider):
        try:
            if (type(catalog) is not Catalog or type(policy) is not WorkerPolicyBinding
                    or not _identity(container_journal_id) or not callable(proof_provider)):
                raise ValueError()
            self.catalog = Catalog.model_validate_json(_wire(catalog))
            self.policy = WorkerPolicyBinding.model_validate_json(_wire(policy))
            self.container_journal_id = container_journal_id
            self.proof_provider = proof_provider
        except (ValueError, TypeError, AttributeError, RecursionError):
            raise ManagedContainerError('resources_untrusted') from None

    def __call__(self, stack):
        try:
            if type(stack) is not MediaStackPlan:
                raise ValueError()
            selected = verify_media_stack_plan(stack, self.catalog)
            component = next(item for item in selected.components if item.serviceId == 'jellyfin')
            resource_plan = build_resource_plan(selected, self.catalog, self.policy)
            volume_plan = build_volume_plan(selected, self.catalog, self.policy)
        except (ValueError, TypeError, AttributeError, RecursionError, StopIteration):
            raise ManagedContainerError('invalid_installation_plan') from None

        try:
            proof = self.proof_provider(resource_plan, volume_plan, component)
        except Exception:
            raise ManagedContainerError('resources_unavailable') from None

        try:
            if (not _exact(proof, VerifiedJellyfinResources)
                    or not _identity(proof.stack_plan_hash, _HASH)
                    or not _identity(proof.resource_plan_hash, _HASH)
                    or not _identity(proof.volume_plan_hash, _HASH)
                    or not _identity(proof.worker_policy_digest, _HASH)
                    or (proof.stack_plan_hash, proof.resource_plan_hash, proof.volume_plan_hash,
                        proof.worker_policy_digest) != (
                        selected.planHash, resource_plan.planHash, volume_plan.planHash,
                        self.policy.workerPolicyDigest)):
                raise ValueError()

            image_resource = next(item for item in resource_plan.resources
                                  if item.kind == 'ensure_image' and item.serviceId == 'jellyfin')
            image = proof.image
            if (not _exact(image, ManagedImageProof) or not _identity(image.resource_id)
                    or type(image.revision) is not int or not 3 <= image.revision <= 2**63 - 2
                    or image.resource_id != image_resource.resourceId
                    or not _identity(image.image_id, _IMAGE)
                    or image.image_id != image_resource.image.configDigest):
                raise ValueError()

            expected_volumes = tuple(item for item in volume_plan.resources
                                     if item.serviceId == 'jellyfin')
            if type(proof.volumes) is not tuple or len(proof.volumes) != len(expected_volumes) != 0:
                raise ValueError()
            mounts = []
            for actual, expected in zip(proof.volumes, expected_volumes):
                if (not _exact(actual, ManagedVolumeProof)
                        or not all(_identity(value) for value in (
                            actual.resource_id, actual.operation_id, actual.journal_id,
                            actual.ownership_nonce))
                        or type(actual.revision) is not int or not 3 <= actual.revision <= 2**63 - 2
                        or actual.bootstrap_verified is not True
                        or (actual.resource_id, actual.operation_id, actual.name, actual.target) != (
                            expected.resourceId, expected.operationId, expected.name, expected.target)
                        or not _identity(actual.name, _VOLUME)):
                    raise ValueError()
                mounts.append(ManagedContainerMount(actual.name, actual.target))
            if len({item.name for item in mounts}) != len(mounts) or {
                    item.target for item in mounts} != {'/config', '/cache'}:
                raise ValueError()

            expected_network = resource_plan.resources[-1]
            network = proof.network
            if (not _exact(network, ManagedNetworkProof)
                    or not all(_identity(value) for value in (
                        network.resource_id, network.operation_id, network.journal_id,
                        network.ownership_nonce))
                    or type(network.revision) is not int or not 3 <= network.revision <= 2**63 - 2
                    or (network.resource_id, network.operation_id, network.name) != (
                        expected_network.resourceId, expected_network.operationId, expected_network.name)
                    or not _identity(network.name, _NETWORK)
                    or not _identity(network.network_id, _HASH)):
                raise ValueError()

            configuration = _configuration(image.image_configuration,
                                           tuple(item.target for item in mounts))
            child = component.plan
            labels = {
                'org.larenor.server': selected.coreId,
                'org.larenor.installation': component.installationId,
                'org.larenor.worker-journal': self.container_journal_id,
                'org.larenor.plan': selected.planHash,
                'org.larenor.catalog': selected.catalogDigest,
                'org.larenor.manifest': child.manifestDigest,
            }
            tmpfs = {item.target: 'rw,nosuid,nodev,' + ('exec' if item.executable else 'noexec')
                     + f',size={item.sizeMiB}m,uid={item.uid},gid={item.gid},mode=1777'
                     for item in child.tmpfs}
            body = {
                'Image': image_resource.image.reference,
                'User': child.security.user,
                'Labels': labels,
                'Env': [item.name + '=' + item.value for item in child.environment],
                'HostConfig': {
                    'Privileged': False,
                    'CapDrop': list(child.security.capDrop),
                    'CapAdd': list(child.security.capAdd),
                    'SecurityOpt': ['no-new-privileges:true'],
                    'NetworkMode': network.name,
                    'Memory': child.resources.memoryMiB * 1048576,
                    'NanoCpus': child.resources.cpuMillis * 1000000,
                    'PidsLimit': child.resources.pidsLimit,
                    'ReadonlyRootfs': True,
                    'Init': child.security.init,
                    'Tmpfs': tmpfs,
                    'Mounts': [
                        {'Type': 'volume', 'Source': item.name, 'Target': item.target,
                         'ReadOnly': False, 'VolumeOptions': {'NoCopy': True}}
                        for item in mounts
                    ],
                    'RestartPolicy': {'Name': 'no'},
                },
            }
            specification = _canonical(body)
            if len(specification) > 65536:
                raise ValueError()
            return ManagedContainerBinding(
                'larenor-' + component.installationId, selected.platform, image.image_id,
                network.network_id, tuple(mounts), specification, _canonical(configuration),
            )
        except (ValueError, TypeError, AttributeError, RecursionError, StopIteration):
            raise ManagedContainerError('resources_untrusted') from None
