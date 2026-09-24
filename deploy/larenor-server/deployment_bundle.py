#!/usr/bin/env python3
"""Pure CasaOS and Docker Compose bundle planner for Larenor Server.

The default command only renders canonical JSON to stdout. It never connects to
Docker, creates directories, changes a daemon, pulls an image or starts a
container. Installation code must separately consume a successful preflight.
"""

import argparse
import copy
import hashlib
import importlib.util
import json
import os
import platform
import re
import stat
from pathlib import Path, PurePosixPath


HERE = Path(__file__).resolve().parent
CANONICAL_ROOT = "/var/lib/larenor-server"
SETTING_KEYS = (
    "LARENOR_DATA_ROOT", "LARENOR_TIMEZONE", "LARENOR_LOCALE", "LARENOR_CORE_PORT",
)
ARCHITECTURES = ("amd64", "arm64")
CORE_VERSION = "0.1.0"
ROOT_RE = re.compile(r"/[A-Za-z0-9._ -]+(?:/[A-Za-z0-9._ -]+)*\Z")
TIMEZONE_RE = re.compile(r"(?:Etc|[A-Za-z_][A-Za-z0-9_+-]*)/[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*\Z")
LOCALE_RE = re.compile(r"[a-z]{2}_[A-Z]{2}\.UTF-8\Z")
REVISION_RE = re.compile(r"[a-f0-9]{40}\Z")
DIGEST_RE = re.compile(r"[a-f0-9]{64}\Z")
PRIVATE_RE = re.compile(r"token|api.?key|password|credential|authorization|secret", re.I)
MAX_DOCUMENT_BYTES = 1024 * 1024
MAX_INSTALLATION_RECEIPT_BYTES = 4096
INSTALLATION_RECEIPT_NAME = ".larenor-installation.json"
INSTALLATION_ID_RE = re.compile(r"[a-f0-9]{32}\Z")
VERSION_RE = re.compile(
    r"(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\."
    r"(?:0|[1-9][0-9]{0,8})\Z"
)


class BundleError(ValueError):
    CODES = {
        "bundle_settings_invalid", "bundle_source_invalid", "bundle_canonical_invalid",
        "bundle_private_value", "bundle_invalid", "bundle_operation_invalid",
        "bundle_host_inspection_invalid",
    }

    def __init__(self, code):
        safe = code if code in self.CODES else "bundle_invalid"
        self.code = safe
        super().__init__(safe)


def _canonical(value):
    try:
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    except (TypeError, ValueError, OverflowError):
        raise BundleError("bundle_invalid") from None
    if len(encoded.encode("ascii")) > MAX_DOCUMENT_BYTES:
        raise BundleError("bundle_invalid")
    return encoded


def _digest(value):
    return hashlib.sha256(_canonical(value).encode("ascii")).hexdigest()


def _has_private_key(value):
    if isinstance(value, dict):
        return any(PRIVATE_RE.search(str(key)) or _has_private_key(item)
                   for key, item in value.items())
    if isinstance(value, list):
        return any(_has_private_key(item) for item in value)
    return False


def _duplicate_safe(text):
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError("duplicate_key")
            result[key] = value
        return result

    return json.loads(text, object_pairs_hook=pairs)


def _directory_identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_gid,
        stat.S_IFMT(value.st_mode),
        stat.S_IMODE(value.st_mode),
    )


def _file_identity(value):
    return _directory_identity(value) + (
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _directory_content_identity(value):
    return _directory_identity(value) + (
        value.st_nlink,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


class _DirectoryTree:
    """Retain and revalidate one no-symlink absolute directory tree."""

    def __init__(self):
        self._descriptors = {}
        self._identities = {}

    def _remember(self, path, descriptor):
        info = os.fstat(descriptor)
        if not stat.S_ISDIR(info.st_mode) or info.st_nlink < 1:
            raise OSError()
        self._descriptors[path] = descriptor
        self._identities[path] = _directory_identity(info)

    def open(self, value):
        path = PurePosixPath(str(value))
        if not path.is_absolute() or str(path) != str(value):
            raise OSError()
        root = PurePosixPath("/")
        if root not in self._descriptors:
            descriptor = os.open(
                "/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                self._remember(root, descriptor)
            except Exception:
                os.close(descriptor)
                raise
        current = root
        for part in path.parts[1:]:
            child = current / part
            if child not in self._descriptors:
                descriptor = os.open(
                    part,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=self._descriptors[current],
                )
                try:
                    self._remember(child, descriptor)
                    entry = os.stat(
                        part,
                        dir_fd=self._descriptors[current],
                        follow_symlinks=False,
                    )
                    if _directory_identity(entry) != self._identities[child]:
                        raise OSError()
                except Exception:
                    self._descriptors.pop(child, None)
                    self._identities.pop(child, None)
                    os.close(descriptor)
                    raise
            current = child
        return self._descriptors[path]

    def revalidate(self):
        for path, descriptor in self._descriptors.items():
            if _directory_identity(os.fstat(descriptor)) != self._identities[path]:
                raise OSError()
            if path != PurePosixPath("/"):
                entry = os.stat(
                    path.name,
                    dir_fd=self._descriptors[path.parent],
                    follow_symlinks=False,
                )
                if _directory_identity(entry) != self._identities[path]:
                    raise OSError()

    def close(self):
        for path in sorted(self._descriptors, key=lambda item: len(item.parts), reverse=True):
            os.close(self._descriptors[path])
        self._descriptors.clear()
        self._identities.clear()


class LocalHostFacts:
    """Read-only local facts for one operator-selected deployment root."""

    def __init__(self, data_root, *, expected_uid=10001, architecture=None):
        root = Path(data_root)
        if (not root.is_absolute() or str(root) != str(PurePosixPath(str(root)))
                or type(expected_uid) is not int or expected_uid < 0):
            raise BundleError("bundle_host_inspection_invalid")
        self.root = root
        self.expected_uid = expected_uid
        self._architecture = architecture

    def architecture(self):
        return self._architecture or platform.machine().lower()

    def inspect(self, path):
        tree = _DirectoryTree()
        try:
            candidate = Path(path)
            if not candidate.is_absolute() or str(candidate) != str(PurePosixPath(str(candidate))):
                raise OSError()
            descriptor = tree.open(candidate)
            info = os.fstat(descriptor)
            volume = os.fstatvfs(descriptor)
            if not stat.S_ISDIR(info.st_mode) or info.st_nlink < 1:
                raise OSError()
            tree.revalidate()
            return {
                "kind": "directory", "ownerUid": info.st_uid,
                "mode": stat.S_IMODE(info.st_mode), "device": info.st_dev,
                "availableMiB": volume.f_bavail * volume.f_frsize // 1048576,
            }
        except (OSError, TypeError, ValueError):
            raise BundleError("bundle_host_inspection_invalid") from None
        finally:
            tree.close()

    def _read_receipt(self, root_descriptor):
        descriptor = os.open(
            INSTALLATION_RECEIPT_NAME,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=root_descriptor,
        )
        try:
            before = os.fstat(descriptor)
            if (not stat.S_ISREG(before.st_mode)
                    or before.st_uid != self.expected_uid
                    or stat.S_IMODE(before.st_mode) != 0o600
                    or before.st_nlink != 1
                    or not 2 <= before.st_size <= MAX_INSTALLATION_RECEIPT_BYTES):
                raise ValueError()
            raw = bytearray()
            while len(raw) <= MAX_INSTALLATION_RECEIPT_BYTES:
                chunk = os.read(descriptor, min(
                    1024, MAX_INSTALLATION_RECEIPT_BYTES + 1 - len(raw)))
                if not chunk:
                    break
                raw.extend(chunk)
            after = os.fstat(descriptor)
            entry = os.stat(
                INSTALLATION_RECEIPT_NAME,
                dir_fd=root_descriptor,
                follow_symlinks=False,
            )
            if (len(raw) != before.st_size
                    or len(raw) > MAX_INSTALLATION_RECEIPT_BYTES
                    or _file_identity(before) != _file_identity(after)
                    or _file_identity(after) != _file_identity(entry)):
                raise ValueError()
            return bytes(raw), _file_identity(after)
        finally:
            os.close(descriptor)

    def installation(self):
        tree = _DirectoryTree()
        try:
            root_descriptor = tree.open(self.root)
        except FileNotFoundError:
            tree.close()
            return None
        except OSError:
            tree.close()
            raise BundleError("bundle_host_inspection_invalid") from None
        try:
            root_before = os.fstat(root_descriptor)
            if (not stat.S_ISDIR(root_before.st_mode)
                    or root_before.st_uid != self.expected_uid
                    or stat.S_IMODE(root_before.st_mode) & 0o077
                    or root_before.st_nlink < 1):
                raise ValueError()
            try:
                first_raw, first_identity = self._read_receipt(root_descriptor)
            except FileNotFoundError:
                tree.revalidate()
                return None
            second_raw, second_identity = self._read_receipt(root_descriptor)
            tree.revalidate()
            if (first_raw != second_raw
                    or first_identity != second_identity
                    or _directory_identity(root_before)
                    != _directory_identity(os.fstat(root_descriptor))):
                raise ValueError()
            text = second_raw.decode("ascii")
            value = _duplicate_safe(text)
            if (not isinstance(value, dict)
                    or text != _canonical(value) + "\n"):
                raise ValueError()
            return value
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
            raise BundleError("bundle_host_inspection_invalid") from None
        finally:
            tree.close()

    def clean(self, paths):
        tree = _DirectoryTree()
        try:
            if (not isinstance(paths, (tuple, list)) or not 1 <= len(paths) <= 256
                    or any(type(item) is not str for item in paths)):
                raise ValueError()
            normalized = tuple(PurePosixPath(item) for item in paths)
            if (len(set(normalized)) != len(normalized)
                    or any(not item.is_absolute() or str(item) != raw
                           for item, raw in zip(normalized, paths))):
                raise ValueError()
            expected_children = {
                item: {candidate.name for candidate in normalized if candidate.parent == item}
                for item in normalized
            }
            for item in normalized:
                tree.open(item)
            target_identities = {
                item: _directory_content_identity(os.fstat(tree.open(item)))
                for item in normalized
            }
            for item in normalized:
                entries = set()
                with os.scandir(tree.open(item)) as iterator:
                    for index, entry in enumerate(iterator, start=1):
                        if index > 256:
                            return False
                        if entry.name in entries:
                            return False
                        entries.add(entry.name)
                if entries != expected_children[item]:
                    return False
            if any(
                _directory_content_identity(os.fstat(tree.open(item)))
                != target_identities[item]
                for item in normalized
            ):
                raise OSError()
            tree.revalidate()
            return True
        except (OSError, TypeError, ValueError):
            raise BundleError("bundle_host_inspection_invalid") from None
        finally:
            tree.close()


def read_settings(path):
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        raise BundleError("bundle_settings_invalid") from None
    if not raw or len(raw.encode("utf-8")) > 4096:
        raise BundleError("bundle_settings_invalid")
    result = {}
    for line in raw.splitlines():
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise BundleError("bundle_settings_invalid")
        key, value = line.split("=", 1)
        if key in result or key not in SETTING_KEYS or not value:
            raise BundleError("bundle_settings_invalid")
        result[key] = value
    if set(result) != set(SETTING_KEYS):
        raise BundleError("bundle_settings_invalid")
    return result


class _CanonicalBackend:
    def config(self, path, revision):
        try:
            raw = Path(path).read_text(encoding="utf-8")
            raw = raw.replace(
                "${LARENOR_SOURCE_REVISION:?exact source revision required}", revision)
            raw = raw.replace("${LARENOR_SOURCE_REVISION}", revision)
            return json.loads(raw)
        except (OSError, UnicodeError, json.JSONDecodeError):
            raise BundleError("bundle_canonical_invalid") from None


class DeploymentBundlePlanner:
    def __init__(self, *, compose_path, catalog_path, env_example_path):
        self.compose_path = Path(compose_path)
        self.catalog_path = Path(catalog_path)
        self.env_example_path = Path(env_example_path)
        spec = importlib.util.spec_from_file_location(
            "larenor_unified_package_for_bundle", HERE / "unified_package.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.package = module

    def _settings(self, values):
        if (not isinstance(values, dict) or set(values) != set(SETTING_KEYS)
                or any(not isinstance(value, str) for value in values.values())):
            raise BundleError("bundle_settings_invalid")
        root = values["LARENOR_DATA_ROOT"]
        path = PurePosixPath(root)
        try:
            port = int(values["LARENOR_CORE_PORT"])
        except (TypeError, ValueError):
            raise BundleError("bundle_settings_invalid") from None
        if (not ROOT_RE.fullmatch(root) or str(path) != root or ".." in path.parts
                or root in {"/", "/var", "/etc", "/home", "/DATA"}
                or len(root.encode("utf-8")) > 256
                or not TIMEZONE_RE.fullmatch(values["LARENOR_TIMEZONE"])
                or not LOCALE_RE.fullmatch(values["LARENOR_LOCALE"])
                or not re.fullmatch(r"[1-9][0-9]{3,4}", values["LARENOR_CORE_PORT"])
                or not 1024 <= port <= 65535):
            raise BundleError("bundle_settings_invalid")
        return dict(values), port

    def _canonical_inputs(self, revision):
        if not isinstance(revision, str) or not REVISION_RE.fullmatch(revision):
            raise BundleError("bundle_source_invalid")
        try:
            planner = self.package.UnifiedPackagePlanner(
                compose_path=self.compose_path, catalog_path=self.catalog_path)
            manifest = planner.preview(revision, _CanonicalBackend())
            compose = _CanonicalBackend().config(self.compose_path, revision)
        except Exception:
            raise BundleError("bundle_canonical_invalid") from None
        return manifest, compose

    def _configured_compose(self, canonical, settings, port):
        value = copy.deepcopy(canonical)
        root = settings["LARENOR_DATA_ROOT"]
        for name, service in value["services"].items():
            environment = service.setdefault("environment", {})
            environment["TZ"] = settings["LARENOR_TIMEZONE"]
            environment["LANG"] = settings["LARENOR_LOCALE"]
            environment["LC_ALL"] = settings["LARENOR_LOCALE"]
            for mount in service.get("volumes", []):
                source = mount.get("source", "")
                if not source.startswith(CANONICAL_ROOT + "/"):
                    raise BundleError("bundle_canonical_invalid")
                mount["source"] = root + source[len(CANONICAL_ROOT):]
            if name == "larenor-core":
                service["ports"] = [str(port) + ":8098"]
                service.pop("build", None)
            elif "ports" in service:
                raise BundleError("bundle_canonical_invalid")
            if service.get("network_mode") == "host" and name != "larenor-music-assistant":
                raise BundleError("bundle_canonical_invalid")
        return value

    def _manifest(self, canonical_manifest, compose, casaos_compose, settings,
                  settings_schema_digest, port):
        root = settings["LARENOR_DATA_ROOT"]
        owned = []
        for item in canonical_manifest["directoryRequirements"]:
            owned.append({
                "path": root + item["path"][len(CANONICAL_ROOT):],
                "ownerUid": item["ownerUid"], "requiredMiB": item["requiredMiB"],
                "private": item["private"],
            })
        minimum = sum(item["requiredMiB"] for item in owned)
        recovery_budget = max(minimum, 1024)
        root_path = PurePosixPath(root)
        backup_target = str(root_path.parent / (root_path.name + "-backups"))
        rollback_target = str(root_path.parent / (root_path.name + "-rollback"))
        structural = {root}
        for item in tuple(owned):
            parent = PurePosixPath(item["path"]).parent
            while str(parent).startswith(root + "/"):
                structural.add(str(parent))
                parent = parent.parent
        structural.difference_update(item["path"] for item in owned)
        owned.extend({"path": path, "ownerUid": 10001,
                      "requiredMiB": 0, "private": True}
                     for path in sorted(structural))
        owned.extend([
            {"path": backup_target, "ownerUid": 10001,
             "requiredMiB": recovery_budget, "private": True},
            {"path": rollback_target, "ownerUid": 10001,
             "requiredMiB": recovery_budget, "private": True},
        ])
        owned.sort(key=lambda item: item["path"])
        components = [{"serviceId": item["serviceId"], "image": item["image"]}
                      for item in canonical_manifest["components"]]
        value = {
            "schemaVersion": 1,
            "sourceRevision": canonical_manifest["sourceRevision"],
            "architectures": list(ARCHITECTURES),
            "entrypoint": {"service": "larenor-core", "hostPort": port,
                           "containerPort": 8098},
            "coreImage": compose["services"]["larenor-core"]["image"],
            "components": components,
            "ownedPaths": owned,
            "requiredDiskMiB": sum(item["requiredMiB"] for item in owned),
            "backupTarget": backup_target,
            "rollbackTarget": rollback_target,
            "composeDigest": _digest(compose),
            "casaOsComposeDigest": _digest(casaos_compose),
            "settingsSchemaDigest": settings_schema_digest,
            "releaseVersion": CORE_VERSION,
        }
        value["manifestDigest"] = _digest(value)
        return value

    def _validate_casaos(self, value, revision, port):
        metadata = value.get("x-casaos") if isinstance(value, dict) else None
        expected_keys = {
            "id", "main", "index", "port_map", "scheme", "icon", "title",
            "tagline", "description", "author", "developer", "category",
            "architectures", "version", "repo", "docs",
        }
        icon = ("https://raw.githubusercontent.com/ersingundem/larenor/" + revision
                + "/deploy/larenor-server/icon.png")
        if (not isinstance(metadata, dict) or set(metadata) != expected_keys
                or metadata.get("id") != "com.larenor.core"
                or metadata.get("main") != "larenor-core"
                or metadata["main"] not in value.get("services", {})
                or metadata.get("index") != "/" or metadata.get("scheme") != "http"
                or metadata.get("port_map") != str(port)
                or metadata.get("icon") != icon
                or metadata.get("architectures") != list(ARCHITECTURES)
                or metadata.get("version") != CORE_VERSION
                or metadata.get("category") != "Media"
                or not isinstance(metadata.get("title"), dict)
                or set(metadata["title"]) != {"en_US", "tr_TR"}):
            raise BundleError("bundle_canonical_invalid")

    def _build(self, revision, values):
        settings, port = self._settings(values)
        example, _ = self._settings(read_settings(self.env_example_path))
        settings_schema_digest = _digest({"keys": sorted(SETTING_KEYS), "example": example})
        canonical_manifest, canonical_compose = self._canonical_inputs(revision)
        docker_compose = self._configured_compose(canonical_compose, settings, port)
        casaos_compose = copy.deepcopy(docker_compose)
        casaos_compose["x-casaos"] = {
            "id": "com.larenor.core",
            "main": "larenor-core",
            "architectures": list(ARCHITECTURES),
            "title": {"en_US": "Larenor Core", "tr_TR": "Larenor Core"},
            "tagline": {"en_US": "Unus Lar, omnem domum servat.",
                        "tr_TR": "Unus Lar, omnem domum servat."},
            "description": {
                "en_US": "One Larenor Core entry point with six managed media services.",
                "tr_TR": "Altı yönetilen medya servisi için tek Larenor Core giriş noktası.",
            },
            "author": "Larenor", "developer": "Larenor", "category": "Media",
            "scheme": "http", "port_map": str(port), "index": "/",
            "icon": ("https://raw.githubusercontent.com/ersingundem/larenor/" + revision
                     + "/deploy/larenor-server/icon.png"),
            "version": CORE_VERSION,
            "repo": "https://github.com/ersingundem/larenor",
            "docs": "https://github.com/ersingundem/larenor/blob/main/README.md",
        }
        self._validate_casaos(casaos_compose, revision, port)
        manifest = self._manifest(
            canonical_manifest, docker_compose, casaos_compose, settings,
            settings_schema_digest, port)
        result = {
            "schemaVersion": 1, "settings": settings,
            "dockerCompose": docker_compose, "casaOsCompose": casaos_compose,
            "deploymentManifest": manifest,
        }
        if _has_private_key(result):
            raise BundleError("bundle_private_value")
        result["bundleDigest"] = _digest(result)
        return result

    def plan(self, source_revision, settings):
        return self._build(source_revision, settings)

    def installed_state_receipt(self, bundle, *, installation_id, architecture):
        manifest = self._validate_bundle(bundle)
        if (type(installation_id) is not str
                or not INSTALLATION_ID_RE.fullmatch(installation_id)
                or type(architecture) is not str
                or architecture not in ARCHITECTURES):
            raise BundleError("bundle_host_inspection_invalid")
        value = {
            "schemaVersion": 1,
            "state": "installed",
            "installationId": installation_id,
            "sourceRevision": manifest["sourceRevision"],
            "releaseVersion": manifest["releaseVersion"],
            "manifestDigest": manifest["manifestDigest"],
            "bundleDigest": bundle["bundleDigest"],
            "architecture": architecture,
            "dataRoot": bundle["settings"]["LARENOR_DATA_ROOT"],
            "entrypoint": manifest["entrypoint"],
            "settingsSchemaDigest": manifest["settingsSchemaDigest"],
        }
        value["receiptDigest"] = _digest(value)
        return value

    def _validate_bundle(self, value):
        if (not isinstance(value, dict) or set(value) != {
                "schemaVersion", "settings", "dockerCompose", "casaOsCompose",
                "deploymentManifest", "bundleDigest"}
                or value.get("schemaVersion") != 1
                or not isinstance(value.get("deploymentManifest"), dict)):
            raise BundleError("bundle_invalid")
        revision = value["deploymentManifest"].get("sourceRevision")
        expected = self._build(revision, value.get("settings"))
        if value != expected:
            raise BundleError("bundle_invalid")
        return value["deploymentManifest"]

    def preflight(self, bundle, operation, host):
        if operation not in {"install", "upgrade"}:
            raise BundleError("bundle_operation_invalid")
        manifest = self._validate_bundle(bundle)
        checks = []
        try:
            architecture = host.architecture()
        except Exception:
            architecture = "unknown"
        architecture = ({"x86_64": "amd64", "aarch64": "arm64"}.get(
            architecture, architecture) if isinstance(architecture, str) else "unknown")
        if architecture not in ARCHITECTURES:
            checks.append({"subject": "architecture", "state": "failed",
                           "code": "architecture_unsupported"})
        else:
            checks.append({"subject": "architecture", "state": "passed",
                           "code": "architecture_supported"})
        installed_revision = None
        try:
            installed = host.installation()
        except Exception:
            installed = "invalid"
        installation_code = "installation_state_verified"
        if operation == "install":
            if installed is not None:
                installation_code = "installation_already_exists"
            else:
                try:
                    clean = host.clean(tuple(
                        item["path"] for item in manifest["ownedPaths"]))
                except Exception:
                    clean = False
                if clean is not True:
                    installation_code = "installation_not_clean"
        elif installed is None:
            installation_code = "installation_missing"
        elif (not isinstance(installed, dict) or set(installed) != {
                "schemaVersion", "state", "installationId", "sourceRevision",
                "releaseVersion", "manifestDigest", "bundleDigest", "architecture",
                "dataRoot", "entrypoint", "settingsSchemaDigest", "receiptDigest"}
                or type(installed.get("schemaVersion")) is not int
                or installed["schemaVersion"] != 1
                or installed.get("state") != "installed"
                or type(installed.get("installationId")) is not str
                or not INSTALLATION_ID_RE.fullmatch(installed["installationId"])
                or not isinstance(installed.get("sourceRevision"), str)
                or not REVISION_RE.fullmatch(installed["sourceRevision"])
                or type(installed.get("releaseVersion")) is not str
                or not VERSION_RE.fullmatch(installed["releaseVersion"])
                or not isinstance(installed.get("manifestDigest"), str)
                or not DIGEST_RE.fullmatch(installed["manifestDigest"])
                or not isinstance(installed.get("bundleDigest"), str)
                or not DIGEST_RE.fullmatch(installed["bundleDigest"])
                or installed.get("architecture") not in ARCHITECTURES
                or type(installed.get("dataRoot")) is not str
                or type(installed.get("entrypoint")) is not dict
                or type(installed.get("settingsSchemaDigest")) is not str
                or not DIGEST_RE.fullmatch(installed["settingsSchemaDigest"])
                or type(installed.get("receiptDigest")) is not str
                or not DIGEST_RE.fullmatch(installed["receiptDigest"])
                or installed["receiptDigest"] != _digest({
                    key: value for key, value in installed.items()
                    if key != "receiptDigest"})):
            installation_code = "installation_receipt_invalid"
        elif installed["architecture"] != architecture:
            installation_code = "installation_architecture_mismatch"
        elif (installed["dataRoot"] != bundle["settings"]["LARENOR_DATA_ROOT"]
                or installed["entrypoint"] != manifest["entrypoint"]
                or installed["settingsSchemaDigest"] != manifest["settingsSchemaDigest"]):
            installation_code = "installation_foreign"
        elif installed["sourceRevision"] == manifest["sourceRevision"]:
            installation_code = "installation_already_current"
        elif tuple(map(int, installed["releaseVersion"].split("."))) > tuple(
                map(int, manifest["releaseVersion"].split("."))):
            installation_code = "installation_not_upgradeable"
        else:
            installed_revision = installed["sourceRevision"]
        checks.append({
            "subject": "installation",
            "state": "passed" if installation_code == "installation_state_verified" else "failed",
            "code": installation_code,
        })
        devices = {}
        for requirement in manifest["ownedPaths"]:
            code = "owned_path_verified"
            try:
                fact = host.inspect(requirement["path"])
                if (not isinstance(fact, dict) or set(fact) != {
                        "kind", "ownerUid", "mode", "device", "availableMiB"}
                        or type(fact.get("ownerUid")) is not int
                        or type(fact.get("mode")) is not int
                        or type(fact.get("device")) is not int
                        or type(fact.get("availableMiB")) is not int):
                    code = "owned_path_invalid"
                elif fact["kind"] != "directory" or fact["ownerUid"] != requirement["ownerUid"]:
                    code = "owned_path_invalid"
                elif fact["mode"] < 0 or fact["mode"] > 0o7777 or fact["mode"] & 0o022:
                    code = "owned_path_permissions_invalid"
                elif requirement["private"] and fact["mode"] & 0o077:
                    code = "owned_path_permissions_invalid"
                elif fact["device"] < 0 or fact["availableMiB"] < 0:
                    code = "owned_path_invalid"
                else:
                    device = devices.setdefault(fact["device"], {
                        "available": fact["availableMiB"], "required": 0, "indexes": []})
                    device["available"] = min(device["available"], fact["availableMiB"])
                    device["required"] += requirement["requiredMiB"]
                    device["indexes"].append(len(checks))
            except Exception:
                code = "owned_path_invalid"
            checks.append({"subject": _digest(requirement)[:16],
                           "state": "passed" if code == "owned_path_verified" else "failed",
                           "code": code})
        for device in devices.values():
            if device["available"] < device["required"]:
                for index in device["indexes"]:
                    checks[index] = {**checks[index], "state": "failed",
                                     "code": "storage_capacity_insufficient"}
        ready = all(item["state"] == "passed" for item in checks)
        return {
            "schemaVersion": 1, "operation": operation, "ready": ready,
            "state": "passed" if ready else "failed", "architecture": architecture,
            "manifestDigest": manifest["manifestDigest"], "checks": checks,
            "backupTarget": manifest["backupTarget"],
            "rollbackTarget": manifest["rollbackTarget"],
            "installedRevision": installed_revision,
            "targetRevision": manifest["sourceRevision"],
        }


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--env-file", type=Path, default=HERE / ".env.example")
    parser.add_argument("--format", choices=("manifest", "docker-compose", "casaos"),
                        default="manifest")
    parser.add_argument("--operation", choices=("install", "upgrade"))
    args = parser.parse_args(arguments)
    try:
        planner = DeploymentBundlePlanner(
            compose_path=HERE / "unified.compose.yaml",
            catalog_path=HERE.parents[1] / "server/larenor_server/plugins/packagedcatalog.json",
            env_example_path=args.env_file,
        )
        value = planner.plan(args.source_revision, read_settings(args.env_file))
        selected = (planner.preflight(
            value,
            args.operation,
            LocalHostFacts(value["settings"]["LARENOR_DATA_ROOT"]),
        ) if args.operation else {
            "manifest": value["deploymentManifest"],
            "docker-compose": value["dockerCompose"],
            "casaos": value["casaOsCompose"],
        }[args.format])
        print(json.dumps(selected, sort_keys=True, indent=2, ensure_ascii=True))
    except BundleError as error:
        parser.exit(2, error.code + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
