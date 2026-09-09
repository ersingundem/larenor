#!/usr/bin/env python3
"""Native image/network acceptance over one owned ephemeral Engine.

This fixture can pull the catalog-pinned Jellyfin image and create the single
internal control network. It cannot create, start or execute containers, manage
volumes, attach endpoints, or delete/prune Engine resources. The public receipt
contains only a hash of the freshly inspected network identity.
"""

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import stat
import threading
from types import MappingProxyType

from tool import jellyfin_storage_smoke as owned


REPOSITORY = Path(__file__).resolve().parents[1]
_COMMIT = re.compile(r"[0-9a-f]{40}\Z")
_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
_SOURCE_FILES = (
    ".github/workflows/media-resource-characterization.yml",
    "tool/media_resource_smoke.py",
    "tool/media_resource_ci.py",
    "tool/jellyfin_storage_smoke.py",
    "server/larenor_server/plugins/packagedcatalog.json",
    "server/larenor_server/context.py",
    "server/larenor_server/services/transport.py",
    "server/larenor_server/plugins/catalog.py",
    "server/larenor_server/plugins/stack_plan.py",
    "server/larenor_server/plugins/resource_models.py",
    "server/larenor_server/plugins/resource_plan.py",
    "server/larenor_server/plugins/resource_journal.py",
    "server/larenor_server/plugins/worker.py",
    "server/larenor_server/plugins/daemon_context.py",
    "server/larenor_server/plugins/docker_probe.py",
    "server/larenor_server/plugins/engine_http.py",
    "server/larenor_server/plugins/image_resources.py",
    "server/larenor_server/plugins/image_preparation.py",
    "server/larenor_server/plugins/network_resources.py",
    "server/larenor_server/plugins/network_transport.py",
    "server/larenor_server/plugins/network_effects.py",
    "server/larenor_server/plugins/network_preparation.py",
)


class ResourceAcceptanceError(Exception):
    """Static fixture failure without resource identities or Engine output."""


def _require(value, code="resource_characterization_failed"):
    if not value:
        raise ResourceAcceptanceError(code)


@dataclass(frozen=True)
class SelectedResources:
    image: object
    network: object


def select_resources(source):
    """Select the one catalog-pinned Jellyfin image and one control network."""
    try:
        images = [item for item in source.plan.resources
                  if item.kind == "ensure_image" and item.serviceId == "jellyfin"]
        networks = [item for item in source.plan.resources
                    if item.kind == "prepare_control_network"]
        _require(len(images) == len(networks) == 1, "resource_selection_invalid")
        _require(images[0].image.platform == source.plan.platform,
                 "resource_selection_invalid")
        _require(images[0].resourceId != networks[0].resourceId,
                 "resource_selection_invalid")
        return SelectedResources(images[0], networks[0])
    except ResourceAcceptanceError:
        raise
    except Exception:
        raise ResourceAcceptanceError("resource_selection_invalid") from None


class _RecordingReader:
    def __init__(self, delegate):
        self.delegate = delegate
        self.binding = self.intent = None

    def list(self, binding, intent, *, cancelled):
        self.binding, self.intent = binding, intent
        return self.delegate.list(binding, intent, cancelled=cancelled)

    def inspect(self, binding, intent, network_id, *, cancelled):
        self.binding, self.intent = binding, intent
        return self.delegate.inspect(binding, intent, network_id, cancelled=cancelled)


class _RecordingCreator:
    def __init__(self, delegate):
        self.delegate = delegate
        self.network_id = None

    def create(self, binding, intent, *, before_dispatch, cancelled):
        acknowledgement = self.delegate.create(
            binding, intent, before_dispatch=before_dispatch, cancelled=cancelled)
        self.network_id = getattr(acknowledgement, "network_id", None)
        return acknowledgement


class _NoImageIO:
    def inspect(self, *_args, **_kwargs):
        raise ResourceAcceptanceError("resource_restart_unverified")

    def pull(self, *_args, **_kwargs):
        raise ResourceAcceptanceError("resource_restart_unverified")


class _NoNetworkIO:
    def list(self, *_args, **_kwargs):
        raise ResourceAcceptanceError("resource_restart_unverified")

    def inspect(self, *_args, **_kwargs):
        raise ResourceAcceptanceError("resource_restart_unverified")

    def create(self, *_args, **_kwargs):
        raise ResourceAcceptanceError("resource_restart_unverified")


def characterize_resources(root, source, images, network_reader, network_creator):
    """Prepare exactly two resources, re-read them, then reopen the journal."""
    from larenor_server.plugins.image_preparation import JournaledImageOperations
    from larenor_server.plugins.image_resources import ImageObservation, image_binding
    from larenor_server.plugins.network_preparation import JournaledNetworkOperations
    from larenor_server.plugins.network_resources import NetworkListObservation
    from larenor_server.plugins.resource_journal import NetworkIdentity, ResourceJournal

    selected = select_resources(source)
    directory = Path(root) / "resource-journal"
    reader, creator = _RecordingReader(network_reader), _RecordingCreator(network_creator)
    arguments = dict(plan=source.plan, stack=source.stack,
                     catalog=source.catalog, policy=source.policy)
    event = threading.Event()
    try:
        with ResourceJournal(directory, initialize=True) as journal:
            image_receipt = JournaledImageOperations(journal, images).apply(
                **arguments, resource_id=selected.image.resourceId,
                authorize_pull=lambda: True, cancelled=event)
            network_receipt = JournaledNetworkOperations(journal, reader, creator).apply(
                **arguments, resource_id=selected.network.resourceId,
                authorize_create=lambda: True, cancelled=event)
        _require(image_receipt.state == "ready", "resource_state_unverified")
        _require(network_receipt.state == "ready", "resource_identity_unverified")

        bound_image = image_binding(**arguments, resource_id=selected.image.resourceId)
        image_observation = images.inspect(bound_image, cancelled=event)
        _require(type(image_observation) is ImageObservation
                 and image_observation.image_id == bound_image.config_digest,
                 "resource_image_unverified")
        _require(reader.binding is not None and reader.intent is not None,
                 "resource_identity_unverified")
        listed = network_reader.list(reader.binding, reader.intent, cancelled=event)
        _require(type(listed) is NetworkListObservation and listed.state == "candidate"
                 and type(listed.network_id) is str
                 and _DIGEST.fullmatch(listed.network_id) is not None,
                 "resource_identity_unverified")
        _require(creator.network_id is None or creator.network_id == listed.network_id,
                 "resource_identity_unverified")
        identity = network_reader.inspect(
            reader.binding, reader.intent, listed.network_id, cancelled=event)
        _require(type(identity) is NetworkIdentity
                 and identity.network_id == listed.network_id,
                 "resource_identity_unverified")

        with ResourceJournal(directory) as restarted:
            reopened_image = JournaledImageOperations(restarted, _NoImageIO()).apply(
                **arguments, resource_id=selected.image.resourceId,
                authorize_pull=lambda: False, cancelled=event)
            no_network = _NoNetworkIO()
            reopened_network = JournaledNetworkOperations(
                restarted, no_network, no_network).apply(
                **arguments, resource_id=selected.network.resourceId,
                authorize_create=lambda: False, cancelled=event)
        _require(reopened_image == image_receipt and reopened_network == network_receipt,
                 "resource_restart_unverified")
        return {
            "imageState": "ready",
            "networkState": "ready",
            "journalRestartCount": 1,
            "networkIdentitySha256": hashlib.sha256(identity.network_id.encode("ascii")).hexdigest(),
        }
    except ResourceAcceptanceError:
        raise
    except Exception:
        raise ResourceAcceptanceError("resource_characterization_failed") from None


def build_receipt(source, commit, selected_platform, observed, hashes):
    selected = select_resources(source)
    expected_observed = {"imageState", "networkState", "journalRestartCount",
                         "networkIdentitySha256"}
    _require(type(commit) is str and _COMMIT.fullmatch(commit) is not None
             and selected_platform in ("linux/amd64", "linux/arm64")
             and source.plan.platform == selected_platform
             and type(observed) is dict and set(observed) == expected_observed
             and observed["imageState"] == observed["networkState"] == "ready"
             and type(observed["journalRestartCount"]) is int
             and observed["journalRestartCount"] == 1
             and type(observed["networkIdentitySha256"]) is str
             and _DIGEST.fullmatch(observed["networkIdentitySha256"]) is not None
             and type(hashes) is dict and hashes
             and all(type(key) is str and type(value) is str
                     and _DIGEST.fullmatch(value) is not None for key, value in hashes.items()),
             "resource_receipt_invalid")
    return {
        "schemaVersion": 1,
        "result": "resources_ready",
        "platform": selected_platform,
        "sourceCommit": commit,
        "catalogDigest": source.catalog.digest,
        "imageConfigDigest": selected.image.image.configDigest,
        **observed,
        "resourceKinds": ["ensure_image", "prepare_control_network"],
        "resourceCount": 2,
        "containerOperations": 0,
        "installAvailable": False,
        "sourceHashes": dict(hashes),
    }


def _source_bytes(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        with os.fdopen(descriptor, "rb") as source:
            _require(stat.S_ISREG(os.fstat(source.fileno()).st_mode), "resource_source_changed")
            value = source.read(1048577)
        _require(len(value) <= 1048576, "resource_source_changed")
        return value
    except ResourceAcceptanceError:
        raise
    except OSError:
        raise ResourceAcceptanceError("resource_source_changed") from None


def source_hashes():
    return {name: hashlib.sha256(_source_bytes(REPOSITORY / name)).hexdigest()
            for name in _SOURCE_FILES}


def verify_checkout(commit):
    _require(type(commit) is str and _COMMIT.fullmatch(commit) is not None,
             "resource_source_changed")
    command = ["/usr/bin/git", "-c", "safe.directory=" + str(REPOSITORY),
               "-C", str(REPOSITORY)]
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
    head = owned.bounded_command(command + ["rev-parse", "HEAD"],
                                 environment=environment, limit=64).decode().strip()
    _require(head == commit, "resource_source_changed")
    owned.bounded_command(command + ["ls-files", "--error-unmatch", "--", *_SOURCE_FILES],
                          environment=environment, limit=4096)
    owned.bounded_command(command + ["diff", "--exit-code", "HEAD", "--", *_SOURCE_FILES],
                          environment=environment, limit=256)


def capture_source(commit):
    verify_checkout(commit)
    binding = commit, MappingProxyType(source_hashes())
    check_source(binding)
    return binding


def check_source(binding):
    commit, hashes = binding
    verify_checkout(commit)
    _require(source_hashes() == hashes, "resource_source_changed")


def characterize(daemon, *, checkout_binding=None):
    from larenor_server.plugins.docker_probe import DockerEndpoint
    from larenor_server.plugins.image_resources import UnixImageEngine
    from larenor_server.plugins.network_effects import UnixNetworkCreator
    from larenor_server.plugins.network_transport import UnixNetworkEngine

    binding = capture_source(os.environ["GITHUB_SHA"]) if checkout_binding is None else checkout_binding
    check_source(binding)
    source = owned.fixture_source(daemon.platform)
    endpoint = DockerEndpoint(str(daemon.root / "engine.sock"), owner_uid=0)
    observed = characterize_resources(
        daemon.root, source, UnixImageEngine(endpoint),
        UnixNetworkEngine(endpoint), UnixNetworkCreator(endpoint))
    check_source(binding)
    return build_receipt(source, binding[0], daemon.platform, observed, dict(binding[1]))
