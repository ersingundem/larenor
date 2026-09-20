#!/usr/bin/env python3
"""Fail-closed planning boundary for the unified Larenor media package.

The module performs no subprocess, network, directory creation, pull or start by
itself. Operators supply narrow adapters. That keeps preview and preflight pure,
and lets the Docker-backed adapter arrive only after the same contract has been
proved with owned fakes.
"""

import hashlib
import json
from pathlib import Path, PurePosixPath
import re


COMPONENTS = (
    "jellyfin", "seerr", "sonarr", "radarr", "qbittorrent", "music_assistant",
)
SERVICE_NAMES = {item: "larenor-" + item.replace("_", "-") for item in COMPONENTS}
CORE_NAME = "larenor-core"
REVISION = re.compile(r"[a-f0-9]{40}\Z")
CONTAINER_ID = re.compile(r"[a-f0-9]{64}\Z")
FORBIDDEN_KEY = re.compile(r"token|api.?key|password|credential|authorization|secret.?value", re.I)
MAX_CONFIG_BYTES = 512 * 1024


class PackageError(ValueError):
    """Static error codes only; adapter errors and private values stay internal."""

    _CODES = {
        "invalid_source_revision", "config_invalid", "config_identity_changed",
        "config_private_value", "manifest_invalid", "host_inspection_invalid",
        "preflight_not_passed", "pull_receipt_invalid", "container_receipt_invalid",
        "authenticated_readiness_invalid",
    }

    def __init__(self, code):
        safe = code if code in self._CODES else "config_invalid"
        self.code = safe
        super().__init__(safe)


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _digest(value):
    return hashlib.sha256(_canonical(value).encode("ascii")).hexdigest()


def _private_key(value):
    if isinstance(value, dict):
        return any(FORBIDDEN_KEY.search(str(key)) or _private_key(item)
                   for key, item in value.items())
    if isinstance(value, list):
        return any(_private_key(item) for item in value)
    return False


def _bounded_document(value):
    try:
        encoded = _canonical(value)
    except (TypeError, ValueError, OverflowError):
        raise PackageError("config_invalid") from None
    if len(encoded.encode("ascii")) > MAX_CONFIG_BYTES:
        raise PackageError("config_invalid")
    if _private_key(value):
        raise PackageError("config_private_value")
    return value


def _user_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{1,10}:[0-9]{1,10}", value):
        raise PackageError("config_identity_changed")
    uid_text, gid_text = value.split(":", 1)
    uid, gid = int(uid_text), int(gid_text)
    if uid > 2**31 - 1 or gid > 2**31 - 1:
        raise PackageError("config_identity_changed")
    return uid


def _absolute_posix_path(value, *, owned=False):
    if not isinstance(value, str) or not value.startswith("/"):
        raise PackageError("config_identity_changed")
    path = PurePosixPath(value)
    if (str(path) != value or ".." in path.parts or path == PurePosixPath("/")):
        raise PackageError("config_identity_changed")
    if owned:
        root = PurePosixPath("/var/lib/larenor-server")
        if root not in path.parents:
            raise PackageError("config_identity_changed")
    return value


def _mounts(service):
    volumes = service.get("volumes")
    if not isinstance(volumes, list) or not volumes:
        raise PackageError("config_identity_changed")
    result = []
    for mount in volumes:
        if (not isinstance(mount, dict) or set(mount) - {"type", "source", "target", "read_only", "bind"}
                or mount.get("type") != "bind"
                or mount.get("bind") != {"create_host_path": False}
                or type(mount.get("read_only", False)) is not bool):
            raise PackageError("config_identity_changed")
        source = _absolute_posix_path(mount.get("source"), owned=True)
        target = _absolute_posix_path(mount.get("target"))
        result.append({"source": source, "target": target,
                       "readOnly": mount.get("read_only", False)})
    if len({item["target"] for item in result}) != len(result):
        raise PackageError("config_identity_changed")
    return sorted(result, key=lambda item: (item["source"], item["target"]))


class UnifiedPackagePlanner:
    def __init__(self, *, compose_path, catalog_path):
        self._compose_path = Path(compose_path)
        self._catalog_path = Path(catalog_path)

    def _catalog(self):
        try:
            value = _bounded_document(json.loads(self._catalog_path.read_text()))
            entries = {item["serviceId"]: item for item in value["entries"]}
        except (OSError, json.JSONDecodeError, KeyError, TypeError, PackageError):
            raise PackageError("config_invalid") from None
        if set(entries) != set(COMPONENTS):
            raise PackageError("config_invalid")
        return entries

    def _expected(self, revision):
        try:
            raw = self._compose_path.read_text()
            raw = raw.replace("${LARENOR_SOURCE_REVISION:?exact source revision required}", revision)
            raw = raw.replace("${LARENOR_SOURCE_REVISION}", revision)
            return _bounded_document(json.loads(raw))
        except (OSError, json.JSONDecodeError, PackageError):
            raise PackageError("config_invalid") from None

    def preview(self, source_revision, backend):
        if not isinstance(source_revision, str) or not REVISION.fullmatch(source_revision):
            raise PackageError("invalid_source_revision")
        expected = self._expected(source_revision)
        try:
            rendered = _bounded_document(backend.config(self._compose_path, source_revision))
        except PackageError:
            raise
        except Exception:
            raise PackageError("config_invalid") from None
        if (not isinstance(rendered, dict) or rendered.get("name") != "larenor-server"
                or rendered != expected):
            raise PackageError("config_identity_changed")
        expected_services = expected.get("services")
        services = rendered.get("services")
        if (not isinstance(services, dict) or not isinstance(expected_services, dict)
                or set(services) != {CORE_NAME, *SERVICE_NAMES.values()}):
            raise PackageError("config_identity_changed")

        catalog = self._catalog()
        core = services[CORE_NAME]
        expected_core = expected_services[CORE_NAME]
        if any(core.get(key) != expected_core.get(key)
               for key in ("container_name", "image", "user", "networks", "extra_hosts",
                           "links", "dns", "build")):
            raise PackageError("config_identity_changed")
        core_mounts = _mounts(core)
        if core_mounts != _mounts(expected_core):
            raise PackageError("config_identity_changed")
        core_projection = {
            "containerName": CORE_NAME,
            "image": core["image"],
            "user": core["user"],
            "mounts": core_mounts,
        }

        components = []
        for service_id in COMPONENTS:
            name = SERVICE_NAMES[service_id]
            service, wanted = services[name], expected_services[name]
            entry = catalog[service_id]
            if (not isinstance(service, dict)
                    or service.get("container_name") != name
                    or service.get("image") != entry["repository"] + "@" + entry["indexDigest"]
                    or service.get("user") != entry["security"]["user"]
                    or any(service.get(key) != wanted.get(key)
                           for key in ("network_mode", "networks", "dns"))):
                raise PackageError("config_identity_changed")
            mounts = _mounts(service)
            if mounts != _mounts(wanted):
                raise PackageError("config_identity_changed")
            environment = service.get("environment", {})
            if (not isinstance(environment, dict)
                    or any(FORBIDDEN_KEY.search(str(key)) for key in environment)):
                raise PackageError("config_private_value")
            components.append({
                "serviceId": service_id,
                "containerName": name,
                "image": service["image"],
                "user": service["user"],
                "networkMode": service.get("network_mode", "bridge"),
                "networks": service.get("networks", []),
                "mounts": mounts,
            })

        requirements = self._directory_requirements(core_projection, components, catalog)
        manifest = {
            "schemaVersion": 1,
            "project": "larenor-server",
            "sourceRevision": source_revision,
            "core": core_projection,
            "components": components,
            "directoryRequirements": requirements,
        }
        manifest["manifestDigest"] = _digest(manifest)
        return manifest

    def _directory_requirements(self, core, components, catalog):
        all_services = [(CORE_NAME, core, None)] + [
            (item["serviceId"], item, catalog[item["serviceId"]]) for item in components]
        by_path = {}
        for service_id, service, entry in all_services:
            uid = _user_id(service["user"])
            writable = [mount for mount in service["mounts"] if not mount["readOnly"]]
            preferred = None
            for target in ("/data", "/config", "/app/config"):
                preferred = next((mount for mount in writable if mount["target"] == target), None)
                if preferred is not None:
                    break
            if preferred is None and writable:
                preferred = writable[0]
            for mount in service["mounts"]:
                row = by_path.setdefault(mount["source"], {
                    "path": mount["source"], "writerUids": set(), "requiredMiB": 0,
                    "private": mount["target"] == "/secrets",
                })
                row["private"] = row["private"] or mount["target"] == "/secrets"
                if not mount["readOnly"]:
                    row["writerUids"].add(uid)
                if entry is not None and mount is preferred:
                    row["requiredMiB"] += entry["resources"]["minimumDiskMiB"]
        result = []
        for path in sorted(by_path):
            row = by_path[path]
            if len(row["writerUids"]) != 1:
                raise PackageError("config_identity_changed")
            result.append({"path": path, "ownerUid": next(iter(row["writerUids"])),
                           "requiredMiB": row["requiredMiB"], "private": row["private"]})
        return result

    def _validate_manifest(self, manifest):
        if not isinstance(manifest, dict) or set(manifest) != {
                "schemaVersion", "project", "sourceRevision", "core", "components",
                "directoryRequirements", "manifestDigest"}:
            raise PackageError("manifest_invalid")
        body = dict(manifest)
        digest = body.pop("manifestDigest")
        revision = manifest.get("sourceRevision", "")
        if (not isinstance(digest, str) or not CONTAINER_ID.fullmatch(digest)
                or _digest(body) != digest
                or manifest.get("schemaVersion") != 1
                or manifest.get("project") != "larenor-server"
                or not isinstance(revision, str) or not REVISION.fullmatch(revision)
                or not isinstance(manifest.get("components"), list)
                or tuple(item.get("serviceId") for item in manifest["components"]
                         if isinstance(item, dict)) != COMPONENTS):
            raise PackageError("manifest_invalid")
        expected = self._expected(revision)
        catalog = self._catalog()
        services = expected["services"]
        wanted_core = {
            "containerName": CORE_NAME,
            "image": services[CORE_NAME]["image"],
            "user": services[CORE_NAME]["user"],
            "mounts": _mounts(services[CORE_NAME]),
        }
        wanted_components = []
        for service_id in COMPONENTS:
            name = SERVICE_NAMES[service_id]
            service = services[name]
            wanted_components.append({
                "serviceId": service_id,
                "containerName": name,
                "image": catalog[service_id]["repository"] + "@" + catalog[service_id]["indexDigest"],
                "user": service["user"],
                "networkMode": service.get("network_mode", "bridge"),
                "networks": service.get("networks", []),
                "mounts": _mounts(service),
            })
        if (manifest["core"] != wanted_core
                or manifest["components"] != wanted_components
                or manifest["directoryRequirements"] != self._directory_requirements(
                    wanted_core, wanted_components, catalog)):
            raise PackageError("manifest_invalid")

    def preflight(self, manifest, filesystem):
        self._validate_manifest(manifest)
        requirements = manifest["directoryRequirements"]
        if not isinstance(requirements, list) or not requirements:
            raise PackageError("manifest_invalid")
        checks, devices = [], {}
        failed = False
        for requirement in requirements:
            identity = _digest(requirement)[:16]
            code = "owned_directory_verified"
            try:
                fact = filesystem.inspect(requirement["path"])
                valid_shape = (isinstance(fact, dict) and set(fact) == {
                    "kind", "ownerUid", "mode", "device", "availableMiB"}
                    and fact["kind"] == "directory"
                    and type(fact["ownerUid"]) is int
                    and type(fact["mode"]) is int and 0 <= fact["mode"] <= 0o7777
                    and type(fact["device"]) is int and fact["device"] >= 0
                    and type(fact["availableMiB"]) is int and fact["availableMiB"] >= 0)
                if not valid_shape:
                    code = "directory_inspection_invalid"
                elif fact["ownerUid"] != requirement["ownerUid"]:
                    code = "directory_owner_invalid"
                elif fact["mode"] & 0o022 or requirement["private"] and fact["mode"] & 0o077:
                    code = "directory_permissions_invalid"
                else:
                    device = devices.setdefault(fact["device"], {"available": fact["availableMiB"],
                                                                  "required": 0, "checks": []})
                    device["available"] = min(device["available"], fact["availableMiB"])
                    device["required"] += requirement["requiredMiB"]
                    device["checks"].append(len(checks))
            except Exception:
                code = "directory_inspection_invalid"
            if code != "owned_directory_verified":
                failed = True
            checks.append({
                "requirementId": identity,
                "state": "passed" if code == "owned_directory_verified" else "failed",
                "code": code,
            })
        for value in devices.values():
            if value["available"] < value["required"]:
                failed = True
                for index in value["checks"]:
                    checks[index] = {**checks[index], "state": "failed", "code": "storage_capacity_insufficient"}
        return {"schemaVersion": 1, "manifestDigest": manifest["manifestDigest"],
                "ready": not failed, "state": "passed" if not failed else "failed",
                "checks": checks}

    def apply(self, manifest, preflight, runtime, readiness):
        self._validate_manifest(manifest)
        requirements = manifest["directoryRequirements"]
        checks = preflight.get("checks") if isinstance(preflight, dict) else None
        if (not isinstance(preflight, dict) or set(preflight) != {
                    "schemaVersion", "manifestDigest", "ready", "state", "checks"}
                or preflight.get("schemaVersion") != 1
                or preflight.get("manifestDigest") != manifest["manifestDigest"]
                or preflight.get("ready") is not True or preflight.get("state") != "passed"
                or not isinstance(checks, list) or len(checks) != len(requirements)):
            raise PackageError("preflight_not_passed")
        for requirement, check in zip(requirements, checks):
            if (not isinstance(check, dict)
                    or check != {"requirementId": _digest(requirement)[:16],
                                 "state": "passed", "code": "owned_directory_verified"}):
                raise PackageError("preflight_not_passed")
        expected = {item["serviceId"]: item for item in manifest["components"]}
        try:
            pulled = runtime.pull(manifest)
            started = runtime.up(manifest)
        except Exception:
            raise PackageError("container_receipt_invalid") from None
        pulls = self._receipts(pulled, expected, "pull")
        containers = self._receipts(started, expected, "container")
        services, all_ready = {}, True
        for service_id in COMPONENTS:
            try:
                result = readiness.read(service_id)
            except Exception:
                raise PackageError("authenticated_readiness_invalid") from None
            allowed = {"serviceId", "authenticated", "state", "code"}
            if (not isinstance(result, dict) or set(result) != allowed
                    or result.get("serviceId") != service_id
                    or type(result.get("authenticated")) is not bool
                    or (result["authenticated"], result.get("state"), result.get("code")) not in {
                        (True, "ready", "authenticated_readback_verified"),
                        (False, "unavailable", "authenticated_readback_unavailable"),
                    }):
                raise PackageError("authenticated_readiness_invalid")
            all_ready = all_ready and result["authenticated"]
            services[service_id] = {
                "imageReceipt": pulls[service_id],
                "containerReceipt": containers[service_id],
                "authenticatedReadiness": result,
            }
        return {"schemaVersion": 1, "manifestDigest": manifest["manifestDigest"],
                "containerState": "verified", "serviceState": "verified" if all_ready else "needs_attention",
                "automaticRetry": False, "services": services}

    def _receipts(self, values, expected, kind):
        if not isinstance(values, list) or len(values) != len(COMPONENTS):
            raise PackageError("pull_receipt_invalid" if kind == "pull" else "container_receipt_invalid")
        result = {}
        for value in values:
            if not isinstance(value, dict):
                raise PackageError("pull_receipt_invalid" if kind == "pull" else "container_receipt_invalid")
            service_id = value.get("serviceId")
            target = expected.get(service_id)
            if service_id in result or target is None:
                raise PackageError("pull_receipt_invalid" if kind == "pull" else "container_receipt_invalid")
            if kind == "pull":
                if (set(value) != {"serviceId", "image", "state"}
                        or value.get("image") != target["image"]
                        or value.get("state") != "pulled"):
                    raise PackageError("pull_receipt_invalid")
            else:
                if (set(value) != {"serviceId", "containerName", "image", "containerId", "state"}
                        or value.get("containerName") != target["containerName"]
                        or value.get("image") != target["image"]
                        or not isinstance(value.get("containerId"), str)
                        or not CONTAINER_ID.fullmatch(value["containerId"])
                        or value.get("state") != "running"):
                    raise PackageError("container_receipt_invalid")
            result[service_id] = dict(value)
        if set(result) != set(COMPONENTS):
            raise PackageError("pull_receipt_invalid" if kind == "pull" else "container_receipt_invalid")
        return result
