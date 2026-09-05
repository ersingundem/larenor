"""Pinned local catalog and side-effect-free installation-plan calculation.

The digest is a package integrity pin, not an upstream image signature. Updating
the catalog requires reviewing both the JSON and these pins in the same release.
No entry becomes installable merely because a manifest or plan validates.
"""

import hashlib
import json
from pathlib import Path

from .models import (
    Catalog, CatalogEntry, CatalogManifest, EnvironmentValue, InstallPlan,
    NetworkProfile, PluginManifest, PortBinding, SelectedImage, Setting,
    StorageMount, valid_setting,
)


CATALOG_DIGEST = "2f5d16e764d4b6dab968986a4723fd47996e832e4670d9f68c6a2b7807a11749"
_MANIFEST_DIGESTS = {
    "jellyfin": "5f45a6d9206d9a72517f5714d890be35a71d9544743cc755875aa554725c0eb8",
    "seerr": "c5ffd6ee0089ead9fe5de1bf20cf2768404c6900831531b9c36c3e061cdeb53a",
    "sonarr": "fff7c70598b95f1c9d3befc1b26182a76dd85fd9425693ed7108c1d9770e7edf",
    "radarr": "0cd23e0fb7916ef153299aaa8eb0a2b8a01dc2627d15a2bb8974949fe190d58c",
    "qbittorrent": "70d861e59da58953f8f95ea2806499bab5759b62d06cff2b95438dc53b3fdae8",
    "music_assistant": "20c4deb35ee6da9a697c1657f23261592643933f88e62dd3d8c8fd518df5e8c9",
}
_MAX_CATALOG_BYTES = 262144


class CatalogError(ValueError):
    """Static safe error code; never include supplied configuration in errors."""


def _canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")


def _digest(value) -> str:
    return hashlib.sha256(_canonical(value)).hexdigest()


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def _reject_number(_value):
    raise ValueError("noncanonical_number")


def catalog_bytes() -> bytes:
    """Read only the bounded packaged resource; callers cannot select a path."""
    try:
        with Path(__file__).with_name("packagedcatalog.json").open("rb") as stream:
            raw = stream.read(_MAX_CATALOG_BYTES + 1)
        if len(raw) > _MAX_CATALOG_BYTES:
            raise ValueError("catalog_size")
        return raw
    except (OSError, ValueError):
        raise CatalogError("catalog_invalid") from None


def load_catalog(raw: bytes | None = None) -> Catalog:
    """Validate package schema and canonical digest; never fetch a remote URL."""
    if raw is None:
        raw = catalog_bytes()
    try:
        if type(raw) is not bytes or len(raw) > _MAX_CATALOG_BYTES:
            raise ValueError("catalog_size")
        data = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object,
                          parse_float=_reject_number, parse_constant=_reject_number)
        canonical = _canonical(data)
        manifest = CatalogManifest.model_validate_json(canonical)
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise CatalogError("catalog_invalid") from None
    digest = hashlib.sha256(canonical).hexdigest()
    if digest != CATALOG_DIGEST:
        raise CatalogError("catalog_digest_mismatch")
    return Catalog(digest=digest, entries=tuple(
        CatalogEntry(catalogDigest=digest, manifestDigest=_digest(entry.model_dump(mode="json")), manifest=entry)
        for entry in manifest.entries
    ))


def _trusted_entry(entry: CatalogEntry) -> PluginManifest:
    try:
        if type(entry) is not CatalogEntry:
            raise ValueError("entry_type")
        # model_copy/model_construct deliberately bypass Pydantic validation.
        # Revalidate a JSON value and bind every field to the packaged digest.
        validated = CatalogEntry.model_validate_json(_canonical(entry.model_dump(mode="json")))
        manifest = validated.manifest
        digest = _digest(manifest.model_dump(mode="json"))
        if (validated.catalogDigest != CATALOG_DIGEST
                or validated.manifestDigest != digest
                or _MANIFEST_DIGESTS.get(manifest.serviceId) != digest):
            raise ValueError("entry_digest")
        return manifest
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise CatalogError("catalog_entry_untrusted") from None


def plan(entry: CatalogEntry, settings: dict, platform: str) -> InstallPlan:
    """Calculate a complete immutable request; do not inspect or mutate a host."""
    manifest = _trusted_entry(entry)
    selected = next((image for image in manifest.images if image.platform == platform), None) if type(platform) is str else None
    if selected is None:
        raise CatalogError("unsupported_platform")
    specs = {item.name: item for item in manifest.settings}
    if type(settings) is not dict or any(type(key) is not str or key not in specs for key in settings):
        raise CatalogError("invalid_settings")
    values = {}
    for name, spec in specs.items():
        value = settings.get(name, spec.default)
        if not valid_setting(spec.kind, value, spec.minimum, spec.maximum):
            raise CatalogError("invalid_settings")
        values[name] = value
    instance_name = values["instanceName"]
    mounts = []
    for mount in manifest.mounts:
        if mount.kind == "managed_appdata":
            suffix = mount.relativePath.rsplit("/", 1)[1]
            mounts.append(StorageMount(kind=mount.kind, rootId=values["dataRootId"],
                relativePath=instance_name + "/" + suffix, target=mount.target, readOnly=False))
        else:
            mounts.append(StorageMount(kind=mount.kind, rootId=values["libraryRootId"],
                relativePath="", target=mount.target, readOnly=mount.readOnly))
    optional_root = values.get("mediaRootId") or values.get("musicRootId")
    if optional_root is not None:
        mounts.append(StorageMount(kind="approved_library", rootId=optional_root,
            relativePath="", target="/media", readOnly=True))
    ports = list(manifest.ports)
    environment = {item.name: item.value for item in manifest.environment}
    network = manifest.network
    health = manifest.health
    if manifest.serviceId == "qbittorrent":
        web_port, torrent_port = values["webPort"], values["torrentPort"]
        if web_port == torrent_port:
            raise CatalogError("invalid_settings")
        ports = [PortBinding(protocol=protocol, hostIp="0.0.0.0", hostPort=port, containerPort=port)
                 for protocol, port in (("tcp", web_port), ("tcp", torrent_port), ("udp", torrent_port))]
        environment.update(WEBUI_PORT=str(web_port), TORRENTING_PORT=str(torrent_port))
        network = NetworkProfile(mode="bridge", dynamicReceiverPorts=False, listeners=tuple(
            listener.model_copy(update={"port": web_port if listener.purpose == "web" else torrent_port})
            for listener in network.listeners))
        health = health.model_copy(update={"port": web_port})
    elif ports:
        ports[0] = PortBinding(protocol=ports[0].protocol, hostIp="0.0.0.0",
            hostPort=values["webPort"], containerPort=ports[0].containerPort)
    selected_image = SelectedImage(repository=manifest.repository, tag=manifest.tag,
        platform=selected.platform, digest=selected.digest, indexDigest=manifest.indexDigest,
        reference=f"{manifest.repository}:{manifest.tag}@{selected.digest}")
    result = InstallPlan(schemaVersion=1, serviceId=manifest.serviceId, integrationRole=manifest.integrationRole, distributionId=manifest.distributionId,
        instanceName=instance_name, catalogDigest=entry.catalogDigest, manifestDigest=entry.manifestDigest,
        planHash="0" * 64, installable=False, blockers=("worker_unverified", "host_preflight_required"),
        settings=tuple(Setting(name=name, value=value) for name, value in sorted(values.items())),
        image=selected_image, security=manifest.security, network=network, mounts=tuple(mounts), ports=tuple(ports),
        tmpfs=manifest.tmpfs, environment=tuple(EnvironmentValue(name=name, value=value) for name, value in sorted(environment.items())),
        resources=manifest.resources, health=health, warnings=manifest.warnings)
    return result.model_copy(update={"planHash": _digest(result.model_dump(mode="json", exclude={"planHash"}))})


def verify_plan(value: InstallPlan, catalog: Catalog) -> InstallPlan:
    """Re-derive all effects from a worker's catalog, rejecting caller overrides.

    No policy paths are resolved here. Validity still does not permit installation.
    """
    try:
        if type(value) is not InstallPlan or type(catalog) is not Catalog or catalog.digest != CATALOG_DIGEST:
            raise ValueError("plan_type")
        validated = InstallPlan.model_validate_json(_canonical(value.model_dump(mode="json")))
        settings = {setting.name: setting.value for setting in validated.settings}
        if len(settings) != len(validated.settings):
            raise ValueError("duplicate_setting")
        entry = next(entry for entry in catalog.entries if entry.manifest.serviceId == validated.serviceId)
        expected = plan(entry, settings, validated.image.platform)
        if expected != validated:
            raise ValueError("plan_mismatch")
        return expected
    except (ValueError, TypeError, AttributeError, RecursionError, StopIteration):
        raise CatalogError("plan_untrusted") from None
