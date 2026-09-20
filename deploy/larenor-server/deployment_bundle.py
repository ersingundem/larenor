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
from pathlib import Path, PurePosixPath
import re


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
PRIVATE_RE = re.compile(r"token|api.?key|password|credential|authorization|secret", re.I)
MAX_DOCUMENT_BYTES = 1024 * 1024


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
        }


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--env-file", type=Path, default=HERE / ".env.example")
    parser.add_argument("--format", choices=("manifest", "docker-compose", "casaos"),
                        default="manifest")
    args = parser.parse_args(arguments)
    try:
        planner = DeploymentBundlePlanner(
            compose_path=HERE / "unified.compose.yaml",
            catalog_path=HERE.parents[1] / "server/larenor_server/plugins/packagedcatalog.json",
            env_example_path=args.env_file,
        )
        value = planner.plan(args.source_revision, read_settings(args.env_file))
        selected = {"manifest": value["deploymentManifest"],
                    "docker-compose": value["dockerCompose"],
                    "casaos": value["casaOsCompose"]}[args.format]
        print(json.dumps(selected, sort_keys=True, indent=2, ensure_ascii=True))
    except BundleError as error:
        parser.exit(2, error.code + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
