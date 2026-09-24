#!/usr/bin/env python3
"""Native, opt-in acceptance for the exact unified media stack package.

The workflow runs on GitHub-hosted Linux amd64 and arm64 runners. This tool
never publishes credentials, environment, URLs, host paths, logs or raw Docker
identifiers. A fresh fixed root and project are required; cleanup is allowed
only when a private external ownership receipt and root identity agree.
"""

import argparse
import copy
import functools
import hashlib
import importlib.util
import json
import os
import platform
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
COMPOSE = REPOSITORY / "deploy/larenor-server/unified.compose.yaml"
CATALOG = REPOSITORY / "server/larenor_server/plugins/packagedcatalog.json"
PACKAGE_PATH = REPOSITORY / "deploy/larenor-server/unified_package.py"
SPEC = importlib.util.spec_from_file_location("larenor_unified_package", PACKAGE_PATH)
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)
COMPONENTS = package.COMPONENTS
SERVICE_NAMES = package.SERVICE_NAMES
ROOT = Path("/var/lib/larenor-server")
NETWORK = "larenor-server-control-v1"
OWNED_UID = 10001
MAX_OUTPUT = 512 * 1024
MAX_CLEANUP_ENTRIES = 100000
SOURCE_FILES = (
    ".github/workflows/unified-media-stack-managed.yml",
    "deploy/larenor-server/unified.compose.yaml",
    "deploy/larenor-server/unified_package.py",
    "deploy/larenor-server/deployment_bundle.py",
    "deploy/larenor-server/.env.example",
    "server/larenor_server/plugins/packagedcatalog.json",
    "tool/unified_media_stack_managed_ci.py",
    "tool/tests/unified_media_stack_deployment_test.py",
    "tool/tests/unified_media_stack_runtime_test.py",
    "tool/tests/unified_media_stack_bundle_test.py",
    "tool/tests/unified_media_stack_managed_ci_test.py",
    "tool/tests/unified_media_stack_managed_workflow_test.py",
    "tool/tests/unified_media_stack_install_upgrade_acceptance_test.py",
)


def _external_owned_roots():
    return (
        ROOT.parent / (ROOT.name + "-backups"),
        ROOT.parent / (ROOT.name + "-rollback"),
    )

_PUBLIC_HEALTH_PROBE = r'''import http.client,json,sys
connection=None
try:
 profile,host,port_text,path=sys.argv[1:]
 assert profile in {'jellyfin_public','seerr_public','sonarr_public','radarr_public','qbittorrent_web','music_assistant_info'}
 assert host in {'jellyfin','seerr','sonarr','radarr','qbittorrent','host.docker.internal'}
 assert port_text.isascii() and port_text.isdigit() and 1 <= int(port_text) <= 65535
 assert path.startswith('/') and len(path) <= 256 and '//' not in path and '?' not in path and '#' not in path
 caps={'jellyfin_public':256,'sonarr_public':256,'radarr_public':256,'seerr_public':65536,'qbittorrent_web':65536,'music_assistant_info':65536}
 cap=caps[profile]
 connection=http.client.HTTPConnection(host,int(port_text),timeout=5)
 connection.request('GET',path,headers={'Accept':'*/*','Connection':'close'})
 response=connection.getresponse()
 length=response.getheader('Content-Length')
 assert length is None or (length.isascii() and length.isdigit() and int(length) <= cap)
 assert response.getheader('Location') is None and not 300 <= response.status < 400
 raw=response.read(cap+1)
 assert response.status == 200 and 0 < len(raw) <= cap
 content_type=(response.getheader('Content-Type') or '').split(';',1)[0].strip().lower()
 if profile == 'jellyfin_public':
  assert raw.strip() == b'Healthy'
 elif profile == 'qbittorrent_web':
  assert content_type == 'text/html' and b'<html' in raw[:4096].lower()
 else:
  assert content_type in {'application/json','text/json'}
  def unique(pairs):
   value={}
   for key,item in pairs:
    assert key not in value
    value[key]=item
   return value
  value=json.loads(raw.decode('utf-8'),object_pairs_hook=unique,parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
  assert type(value) is dict
  if profile == 'seerr_public':
   assert type(value.get('initialized')) is bool and type(value.get('applicationTitle')) is str and 1 <= len(value['applicationTitle']) <= 64 and type(value.get('mediaServerType')) is int and 0 <= value['mediaServerType'] <= 16
  elif profile in {'sonarr_public','radarr_public'}:
   assert value == {'status':'OK'}
  elif profile == 'music_assistant_info':
   assert set(value) <= {'server_id','server_version','schema_version','min_supported_schema_version','name','base_url','internal_url','external_url','has_remote_access','homeassistant_addon','onboard_done','status'} and type(value.get('server_id')) is str and 1 <= len(value['server_id']) <= 128 and type(value.get('server_version')) is str and 1 <= len(value['server_version']) <= 32 and type(value.get('schema_version')) is int and value['schema_version'] > 0
   assert 'min_supported_schema_version' not in value or (type(value['min_supported_schema_version']) is int and value['min_supported_schema_version'] > 0)
   assert 'name' not in value or (type(value['name']) is str and 1 <= len(value['name']) <= 128)
   assert all(key not in value or value[key] is None or (type(value[key]) is str and len(value[key]) <= 512) for key in {'base_url','internal_url','external_url'})
   assert all(key not in value or type(value[key]) is bool for key in {'has_remote_access','homeassistant_addon','onboard_done'})
   assert 'status' not in value or (type(value['status']) is str and 1 <= len(value['status']) <= 32)
 print('healthy')
except Exception:
 sys.exit(1)
finally:
 if connection is not None:
  try: connection.close()
  except Exception: pass
'''
_CODES = {
    "unified_characterization_evidence_invalid",
    "unified_launch_invalid",
    "unified_source_invalid",
    "unified_native_runtime_failed",
    "unified_manifest_invalid",
    "unified_preflight_failed",
    "unified_pull_receipt_invalid",
    "unified_container_receipt_invalid",
    "unified_readiness_invalid",
    "unified_health_probe_failed",
    "unified_installation_receipt_invalid",
    "unified_private_state_changed",
    "unified_install_reconcile_failed",
    "unified_upgrade_reconcile_failed",
    "unified_upgrade_reconcile_invalid",
    "unified_upgrade_recovery_pending",
    "unified_foreign_resource",
    "unified_cleanup_not_owned",
    "unified_cleanup_failed",
    "unified_pull_runtime_failed",
    "unified_build_runtime_failed",
    "unified_create_runtime_failed",
    "unified_start_runtime_failed",
    "unified_restart_runtime_failed",
    "unified_core_runtime_unready",
    "unified_dns_runtime_failed",
    "unified_dns_resolver_unavailable",
    "unified_dns_core_service_failed",
    "unified_dns_peer_service_failed",
}


class ManagedStackCIError(Exception):
    """A bounded diagnostic whose text is always an allowlisted code."""

    def __init__(self, code, *, preserve_resources=False):
        safe = code if (code in _CODES or re.fullmatch(
            r"unified_dns_peers_failed_[01]{10}", str(code))) else (
                "unified_native_runtime_failed")
        self.code = safe
        self.preserve_resources = preserve_resources
        super().__init__(safe)


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _digest(value):
    return hashlib.sha256(_canonical(value).encode("ascii")).hexdigest()


def _source_bytes(path):
    try:
        value = path.read_bytes()
    except OSError:
        raise ManagedStackCIError("unified_source_invalid") from None
    if not value or len(value) > 2 * 1024 * 1024:
        raise ManagedStackCIError("unified_source_invalid")
    return value


def acceptance_source_hashes():
    return {name: hashlib.sha256(_source_bytes(REPOSITORY / name)).hexdigest()
            for name in SOURCE_FILES}


def _command(arguments, *, environment, timeout=120, output=True, allow_failure=False):
    try:
        result = subprocess.run(arguments, cwd=REPOSITORY, env=environment,
                                stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE if output else subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ManagedStackCIError("unified_native_runtime_failed") from None
    if result.returncode and not allow_failure:
        raise ManagedStackCIError("unified_native_runtime_failed")
    value = result.stdout if output else b""
    if len(value) > MAX_OUTPUT:
        raise ManagedStackCIError("unified_native_runtime_failed")
    return result.returncode, value


def verify_checkout(commit):
    if not isinstance(commit, str) or not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ManagedStackCIError("unified_source_invalid")
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
    _, head = _command(["/usr/bin/git", "rev-parse", "HEAD"], environment=env)
    if head.decode("ascii", "strict").strip() != commit:
        raise ManagedStackCIError("unified_source_invalid")
    _command(["/usr/bin/git", "ls-files", "--error-unmatch", "--", *SOURCE_FILES],
             environment=env)
    _command(["/usr/bin/git", "diff", "--exit-code", "HEAD", "--", *SOURCE_FILES],
             environment=env, output=False)
    _command(["/usr/bin/git", "diff", "--exit-code", "HEAD", "--", "."],
             environment=env, output=False)
    _, untracked = _command(
        ["/usr/bin/git", "ls-files", "--others", "--exclude-standard"],
        environment=env)
    if untracked:
        raise ManagedStackCIError("unified_source_invalid")
    acceptance_source_hashes()


def _source_tree(commit):
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
    try:
        _, raw = _command(
            ["/usr/bin/git", "rev-parse", commit + "^{tree}"],
            environment=env)
        value = raw.decode("ascii", "strict").strip()
    except (UnicodeError, ValueError):
        raise ManagedStackCIError("unified_source_invalid") from None
    if not re.fullmatch(r"[a-f0-9]{40}", value):
        raise ManagedStackCIError("unified_source_invalid")
    return value


def _git_blob(commit, name, *, allow_absent=False):
    if (not re.fullmatch(r"[a-f0-9]{40}", commit)
            or name not in SOURCE_FILES):
        raise ManagedStackCIError("unified_source_invalid")
    if allow_absent:
        status, _ = _command(
            ["/usr/bin/git", "cat-file", "-e", commit + ":" + name],
            environment={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"},
            output=False, allow_failure=True)
        if status != 0:
            return None
    try:
        _, value = _command(
            ["/usr/bin/git", "show", commit + ":" + name],
            environment={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
    except ManagedStackCIError:
        raise ManagedStackCIError("unified_source_invalid") from None
    if not value or len(value) > 2 * 1024 * 1024:
        raise ManagedStackCIError("unified_source_invalid")
    return value


def _source_evidence(commit):
    def source_hash(name):
        value = _git_blob(
            commit, name,
            allow_absent=(
                name == "tool/tests/"
                "unified_media_stack_install_upgrade_acceptance_test.py"),
        )
        return None if value is None else hashlib.sha256(value).hexdigest()

    return {
        "sourceRevision": commit,
        "treeObject": _source_tree(commit),
        "sourceHashes": {name: source_hash(name) for name in SOURCE_FILES},
    }


@functools.lru_cache(maxsize=4)
def _revision_contract(commit):
    """Render one revision from its exact Git blobs with reviewed planner code."""
    required = (
        "deploy/larenor-server/unified.compose.yaml",
        "deploy/larenor-server/unified_package.py",
        "deploy/larenor-server/.env.example",
        "server/larenor_server/plugins/packagedcatalog.json",
    )
    with tempfile.TemporaryDirectory(prefix="larenor-native-source-") as raw_root:
        root = Path(raw_root)
        for name in required:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(_git_blob(commit, name))
        bundle_spec = importlib.util.spec_from_file_location(
            "larenor_revision_bundle_" + commit,
            REPOSITORY / "deploy/larenor-server/deployment_bundle.py")
        bundle_module = importlib.util.module_from_spec(bundle_spec)
        bundle_spec.loader.exec_module(bundle_module)
        bundle_module.HERE = root / "deploy/larenor-server"
        planner = bundle_module.DeploymentBundlePlanner(
            compose_path=root / "deploy/larenor-server/unified.compose.yaml",
            catalog_path=root / "server/larenor_server/plugins/packagedcatalog.json",
            env_example_path=root / "deploy/larenor-server/.env.example")
        settings = {
            "LARENOR_DATA_ROOT": str(ROOT),
            "LARENOR_TIMEZONE": "Europe/Istanbul",
            "LARENOR_LOCALE": "tr_TR.UTF-8",
            "LARENOR_CORE_PORT": "18098",
        }
        try:
            bundle = planner.plan(commit, settings)
        except Exception:
            raise ManagedStackCIError("unified_source_invalid") from None
        return copy.deepcopy(bundle)


def _revision_manifest(commit):
    _revision_contract(commit)
    try:
        with tempfile.TemporaryDirectory(prefix="larenor-native-manifest-") as raw_root:
            root = Path(raw_root)
            compose = root / "unified.compose.yaml"
            catalog = root / "packagedcatalog.json"
            compose.write_bytes(_git_blob(
                commit, "deploy/larenor-server/unified.compose.yaml"))
            catalog.write_bytes(_git_blob(
                commit, "server/larenor_server/plugins/packagedcatalog.json"))
            archived_package = root / "unified_package.py"
            archived_package.write_bytes(_git_blob(
                commit, "deploy/larenor-server/unified_package.py"))
            archived_spec = importlib.util.spec_from_file_location(
                "larenor_archived_package_" + commit, archived_package)
            archived = importlib.util.module_from_spec(archived_spec)
            archived_spec.loader.exec_module(archived)
            return archived.UnifiedPackagePlanner(
                compose_path=compose, catalog_path=catalog).preview(
                    commit, SourceConfig())
    except Exception:
        raise ManagedStackCIError("unified_source_invalid") from None


def validate_launch(environment=None):
    env = os.environ if environment is None else environment
    machine = platform.machine().lower()
    selected = {"x86_64": "linux/amd64", "amd64": "linux/amd64",
                "aarch64": "linux/arm64", "arm64": "linux/arm64"}.get(machine)
    expected_arch = {"linux/amd64": "X64", "linux/arm64": "ARM64"}.get(selected)
    event = env.get("GITHUB_EVENT_NAME")
    repository = env.get("GITHUB_REPOSITORY")
    manual = (
        event == "workflow_dispatch"
        and env.get("GITHUB_REF") == "refs/heads/main"
        and env.get("GITHUB_BASE_REF", "") == ""
        and env.get("PR_HEAD_REPOSITORY", "") == ""
    )
    pull_request = (
        event == "pull_request"
        and re.fullmatch(r"refs/pull/[1-9][0-9]*/merge", env.get("GITHUB_REF", ""))
        and env.get("GITHUB_BASE_REF") == "main"
        and env.get("PR_HEAD_REPOSITORY") == repository
    )
    if not (
        platform.system() == "Linux"
        and os.geteuid() == 0
        and selected is not None
        and env.get("EXPECTED_PLATFORM") == selected
        and env.get("RUNNER_ARCH") == expected_arch
        and env.get("RUNNER_ENVIRONMENT") == "github-hosted"
        and (manual or pull_request)
        and repository == "ersingundem/larenor"
        and env.get("GITHUB_WORKFLOW_SHA") == env.get("GITHUB_SHA")
        and env.get("CI") == "true" and env.get("GITHUB_ACTIONS") == "true"
    ):
        raise ManagedStackCIError("unified_launch_invalid")
    return selected


def validate_upgrade_chain(commit, environment=None):
    env = os.environ if environment is None else environment
    base = env.get("UPGRADE_SOURCE_SHA", "")
    reviewed = env.get("REVIEWED_HEAD_SHA", "")
    if (not re.fullmatch(r"[a-f0-9]{40}", base)
            or not re.fullmatch(r"[a-f0-9]{40}", reviewed)
            or len({base, reviewed, commit}) < 2):
        raise ManagedStackCIError("unified_launch_invalid")
    git_env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
    status, _ = _command(
        ["/usr/bin/git", "merge-base", "--is-ancestor", base, commit],
        environment=git_env, output=False, allow_failure=True)
    try:
        _, raw = _command(
            ["/usr/bin/git", "rev-list", "--parents", "-n", "1", commit],
            environment=git_env)
        parents = raw.decode("ascii", "strict").strip().split()
    except (UnicodeError, ValueError):
        raise ManagedStackCIError("unified_launch_invalid") from None
    event = env.get("GITHUB_EVENT_NAME")
    if status != 0 or parents[0:1] != [commit]:
        raise ManagedStackCIError("unified_launch_invalid")
    if event == "pull_request":
        valid = parents == [commit, base, reviewed]
    else:
        valid = parents == [commit, base] and reviewed == commit
    if not valid:
        raise ManagedStackCIError("unified_launch_invalid")
    return base, reviewed


class SourceConfig:
    def config(self, path, revision):
        try:
            text = Path(path).read_text()
            text = text.replace(
                "${LARENOR_SOURCE_REVISION:?exact source revision required}", revision)
            text = text.replace("${LARENOR_SOURCE_REVISION}", revision)
            return json.loads(text)
        except (OSError, json.JSONDecodeError):
            raise ManagedStackCIError("unified_manifest_invalid") from None


def expected_manifest(commit):
    try:
        return package.UnifiedPackagePlanner(
            compose_path=COMPOSE, catalog_path=CATALOG).preview(commit, SourceConfig())
    except Exception:
        raise ManagedStackCIError("unified_manifest_invalid") from None


def _container_receipts(values, manifest):
    expected = {item["serviceId"]: item for item in manifest["components"]}
    if not isinstance(values, list) or len(values) != len(COMPONENTS):
        raise ManagedStackCIError("unified_container_receipt_invalid")
    result = {}
    for value in values:
        if not isinstance(value, dict) or set(value) != {
                "serviceId", "containerName", "image", "containerId", "state",
                "dns", "network", "mounts", "tmpfs"}:
            raise ManagedStackCIError("unified_container_receipt_invalid")
        service_id = value.get("serviceId")
        wanted = expected.get(service_id)
        wanted_mounts = ([{"target": item["target"], "readOnly": item["readOnly"]}
                          for item in wanted["mounts"]] if wanted else None)
        wanted_network = "host" if service_id == "music_assistant" else NETWORK
        wanted_dns = "host_network" if service_id == "music_assistant" else "verified"
        if (wanted is None or service_id in result
                or value.get("containerName") != wanted["containerName"]
                or value.get("image") != wanted["image"]
                or not isinstance(value.get("containerId"), str)
                or not re.fullmatch(r"[a-f0-9]{64}", value["containerId"])
                or value.get("state") != "running"
                or value.get("dns") != wanted_dns
                or value.get("network") != wanted_network
                or value.get("mounts") != wanted_mounts
                or value.get("tmpfs") != wanted["tmpfs"]):
            raise ManagedStackCIError("unified_container_receipt_invalid")
        result[service_id] = value
    if tuple(result) != COMPONENTS:
        raise ManagedStackCIError("unified_container_receipt_invalid")
    return result


def _pull_receipts(values, manifest):
    try:
        return package.UnifiedPackagePlanner(
            compose_path=COMPOSE, catalog_path=CATALOG)._receipts(
                values, {item["serviceId"]: item for item in manifest["components"]}, "pull")
    except Exception:
        raise ManagedStackCIError("unified_pull_receipt_invalid") from None


def _public_container(value):
    return {
        "containerName": value["containerName"],
        "containerIdentityDigest": hashlib.sha256(
            ("larenor-container-v1\0" + value["containerId"]).encode("ascii")).hexdigest(),
        "state": value["state"],
        "dns": value["dns"],
        "network": value["network"],
        "mounts": value["mounts"],
        "tmpfs": value["tmpfs"],
    }


def _public_health_receipts(driver, manifest, phase, commit, selected_platform):
    if phase not in {"initial", "restart"}:
        raise ManagedStackCIError("unified_health_probe_failed")
    result = {}
    for component in manifest["components"]:
        try:
            value = driver.public_health(
                component, phase, commit, manifest["manifestDigest"], selected_platform)
        except Exception:
            raise ManagedStackCIError("unified_health_probe_failed") from None
        wanted = {
            "serviceId": component["serviceId"],
            "profile": component["health"]["profile"],
            "phase": phase,
            "sourceRevision": commit,
            "manifestDigest": manifest["manifestDigest"],
            "platform": selected_platform,
            "state": "healthy",
            "code": "public_probe_verified",
        }
        if value != wanted or component["serviceId"] in result:
            raise ManagedStackCIError("unified_health_probe_failed")
        result[component["serviceId"]] = value
    if tuple(result) != COMPONENTS:
        raise ManagedStackCIError("unified_health_probe_failed")
    return result


def _installation_receipt(value, revision, selected_platform):
    if (not isinstance(value, dict) or set(value) != {
            "schemaVersion", "state", "installationId", "sourceRevision",
            "releaseVersion", "manifestDigest", "bundleDigest", "architecture",
            "dataRoot", "entrypoint", "settingsSchemaDigest", "receiptDigest"}
            or type(value.get("schemaVersion")) is not int
            or value.get("schemaVersion") != 1
            or value.get("state") != "installed"
            or not isinstance(value.get("installationId"), str)
            or not re.fullmatch(r"[a-f0-9]{32}", value["installationId"])
            or value.get("sourceRevision") != revision
            or not isinstance(value.get("releaseVersion"), str)
            or not re.fullmatch(r"(?:0|[1-9][0-9]{0,8})(?:\.(?:0|[1-9][0-9]{0,8})){2}",
                                value["releaseVersion"])
            or any(not isinstance(value.get(key), str)
                   or not re.fullmatch(r"[a-f0-9]{64}", value[key])
                   for key in ("manifestDigest", "bundleDigest", "settingsSchemaDigest"))
            or value.get("architecture") != selected_platform.removeprefix("linux/")
            or not isinstance(value.get("dataRoot"), str)
            or value["dataRoot"] != str(ROOT)
            or not isinstance(value.get("entrypoint"), dict)
            or not isinstance(value.get("receiptDigest"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", value["receiptDigest"])
            or value["receiptDigest"] != _digest({
                key: item for key, item in value.items() if key != "receiptDigest"
            })):
        raise ManagedStackCIError("unified_installation_receipt_invalid")
    bundle = _revision_contract(revision)
    try:
        manifest = bundle["deploymentManifest"]
        expected = {
            "schemaVersion": 1,
            "state": "installed",
            "installationId": value["installationId"],
            "sourceRevision": manifest["sourceRevision"],
            "releaseVersion": manifest["releaseVersion"],
            "manifestDigest": manifest["manifestDigest"],
            "bundleDigest": bundle["bundleDigest"],
            "architecture": selected_platform.removeprefix("linux/"),
            "dataRoot": bundle["settings"]["LARENOR_DATA_ROOT"],
            "entrypoint": manifest["entrypoint"],
            "settingsSchemaDigest": manifest["settingsSchemaDigest"],
        }
        expected["receiptDigest"] = _digest(expected)
    except (KeyError, TypeError):
        raise ManagedStackCIError("unified_installation_receipt_invalid") from None
    if value != expected:
        raise ManagedStackCIError("unified_installation_receipt_invalid")
    return value


def _persistent_mounts(manifest):
    values = [("core", item["target"])
              for item in manifest["core"]["mounts"] if item["readOnly"] is False]
    values.extend((component["serviceId"], item["target"])
                  for component in manifest["components"]
                  for item in component["mounts"] if item["readOnly"] is False)
    if len(values) != len(set(values)) or not values:
        raise ManagedStackCIError("unified_private_state_changed")
    return set(values)


def _same_private_state(before, after, expected=None):
    def normalize(values):
        if not isinstance(values, list) or not values:
            raise ManagedStackCIError("unified_private_state_changed")
        result = {}
        for value in values:
            if (not isinstance(value, dict) or set(value) != {
                    "serviceId", "containerTarget", "digest"}
                    or value.get("serviceId") not in {"core", *COMPONENTS}
                    or not isinstance(value.get("containerTarget"), str)
                    or not value["containerTarget"].startswith("/")
                    or not isinstance(value.get("digest"), str)
                    or not re.fullmatch(r"[a-f0-9]{64}", value["digest"])):
                raise ManagedStackCIError("unified_private_state_changed")
            key = (value["serviceId"], value["containerTarget"])
            if key in result:
                raise ManagedStackCIError("unified_private_state_changed")
            result[key] = value["digest"]
        return result

    first, second = normalize(before), normalize(after)
    if first != second or (expected is not None and set(first) != set(expected)):
        raise ManagedStackCIError("unified_private_state_changed")
    return [{"serviceId": service_id, "containerTarget": target,
             "digest": digest, "preserved": True}
            for (service_id, target), digest in sorted(first.items())]


def _runtime_receipt(value, revision):
    manifest = _revision_manifest(revision)
    expected = {item["serviceId"]: item["image"] for item in manifest["components"]}
    if (not isinstance(value, dict) or set(value) != {
            "schemaVersion", "sourceRevision", "manifestDigest", "core", "services"}
            or type(value.get("schemaVersion")) is not int
            or value.get("schemaVersion") != 1
            or value.get("sourceRevision") != revision
            or value.get("manifestDigest") != manifest["manifestDigest"]
            or not isinstance(value.get("services"), list)
            or len(value["services"]) != len(COMPONENTS)):
        raise ManagedStackCIError("unified_container_receipt_invalid")
    core = value.get("core")
    if (not isinstance(core, dict) or set(core) != {
            "image", "containerIdentityDigest", "state"}
            or core.get("image") != manifest["core"]["image"]
            or not isinstance(core.get("containerIdentityDigest"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", core["containerIdentityDigest"])
            or len(set(core["containerIdentityDigest"])) == 1
            or core.get("state") != "running"):
        raise ManagedStackCIError("unified_container_receipt_invalid")
    seen = set()
    for service in value["services"]:
        if (not isinstance(service, dict) or set(service) != {
                "serviceId", "image", "containerIdentityDigest", "state"}
                or service.get("serviceId") not in expected
                or service["serviceId"] in seen
                or service.get("image") != expected[service["serviceId"]]
            or not isinstance(service.get("containerIdentityDigest"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", service["containerIdentityDigest"])
            or len(set(service["containerIdentityDigest"])) == 1
            or service.get("state") != "running"):
            raise ManagedStackCIError("unified_container_receipt_invalid")
        seen.add(service["serviceId"])
    if seen != set(COMPONENTS):
        raise ManagedStackCIError("unified_container_receipt_invalid")
    return value


def _effect_receipt(value, revision, selected_platform):
    if not isinstance(value, dict) or set(value) != {
            "installationReceipt", "runtimeReceipt"}:
        raise ManagedStackCIError("unified_upgrade_reconcile_invalid")
    return {
        "installationReceipt": _installation_receipt(
            value["installationReceipt"], revision, selected_platform),
        "runtimeReceipt": _runtime_receipt(value["runtimeReceipt"], revision),
    }


def _apply_or_reconcile(driver, operation, revision, selected_platform):
    try:
        value = getattr(driver, "apply_" + operation)(revision)
    except Exception:
        try:
            recovery_pending = driver.recovery_pending()
        except Exception:
            recovery_pending = True
        try:
            value = driver.reconcile_upgrade(revision, operation)
        except Exception:
            raise ManagedStackCIError(
                "unified_" + operation + "_reconcile_failed",
                preserve_resources=recovery_pending,
            ) from None
        if (operation == "upgrade" and isinstance(value, dict)
                and set(value) == {"baseEffect", "currentEffect", "privateState"}):
            value = value["currentEffect"]
        try:
            return _effect_receipt(value, revision, selected_platform)
        except ManagedStackCIError:
            raise ManagedStackCIError(
                "unified_" + operation + "_reconcile_failed",
                preserve_resources=recovery_pending,
            ) from None
    return _effect_receipt(value, revision, selected_platform)


def _install_upgrade(driver, base_commit, commit, selected_platform,
                     expected_private):
    base_source = driver.materialize_base(base_commit)
    exact_source = _source_evidence(base_commit)
    if (not isinstance(base_source, dict) or set(base_source) != {
            "sourceRevision", "treeObject", "sourceHashes"}
            or base_source != exact_source):
        raise ManagedStackCIError("unified_source_invalid")

    # A retained post-effect journal wins over starting the installation again.
    base_receipt = None
    private_before = None
    recovering = driver.recovery_pending()
    did_recover = recovering
    if recovering:
        operation = None
        try:
            operation = driver.recovery_operation()
            if operation == "install":
                recovered_base = driver.reconcile_upgrade(base_commit, "install")
                base_receipt = _effect_receipt(
                    recovered_base, base_commit, selected_platform)
                try:
                    stored = driver.installation_receipt()
                except FileNotFoundError:
                    stored = None
                if stored is None:
                    driver.persist_installation_receipt(
                        base_receipt["installationReceipt"])
                    stored = driver.installation_receipt()
                installed = _installation_receipt(
                    stored, base_commit, selected_platform)
                if installed != base_receipt["installationReceipt"]:
                    raise ManagedStackCIError(
                        "unified_installation_receipt_invalid")
                private_before = driver.private_state()
                recovering = False
            elif operation != "upgrade":
                raise ManagedStackCIError("unified_upgrade_reconcile_failed")
            if operation == "install":
                recovered = None
            else:
                recovered = driver.reconcile_upgrade(commit, "upgrade")
        except ManagedStackCIError as error:
            code = ("unified_install_reconcile_failed"
                    if operation == "install" else error.code)
            if code == "unified_upgrade_reconcile_failed":
                try:
                    stored = driver.installation_receipt()
                except Exception:
                    stored = None
                if stored is None:
                    code = "unified_install_reconcile_failed"
            raise ManagedStackCIError(
                code, preserve_resources=True) from None
        except Exception:
            try:
                stored = driver.installation_receipt()
            except Exception:
                stored = None
            raise ManagedStackCIError(
                ("unified_upgrade_reconcile_failed" if stored is not None
                 else "unified_install_reconcile_failed"),
                preserve_resources=True) from None
        if recovered is not None:
            try:
                if not isinstance(recovered, dict) or set(recovered) != {
                        "baseEffect", "currentEffect", "privateState"}:
                    raise ManagedStackCIError("unified_upgrade_reconcile_failed")
                base_receipt = _effect_receipt(
                    recovered["baseEffect"], base_commit, selected_platform)
                current = _effect_receipt(
                    recovered["currentEffect"], commit, selected_platform)
                private_before = recovered["privateState"]
                _same_private_state(
                    private_before, driver.private_state(), expected_private)
                driver.persist_installation_receipt(current["installationReceipt"])
                if driver.installation_receipt() != current["installationReceipt"]:
                    raise ManagedStackCIError("unified_installation_receipt_invalid")
                return (base_source, base_receipt, current, private_before, True)
            except ManagedStackCIError as error:
                code = ("unified_install_reconcile_failed"
                        if operation == "install" else error.code)
                raise ManagedStackCIError(
                    code, preserve_resources=True) from None
            except Exception:
                raise ManagedStackCIError(
                    "unified_upgrade_reconcile_failed", preserve_resources=True) from None

    if base_receipt is None:
        install = driver.deployment_preflight(base_commit, "install")
        if (not isinstance(install, dict) or install.get("ready") is not True
                or install.get("operation") != "install"
                or install.get("installedRevision") is not None
                or install.get("targetRevision") != base_commit):
            if (isinstance(install, dict)
                    and install.get("installedRevision") == base_commit):
                raise ManagedStackCIError(
                    "unified_upgrade_reconcile_failed", preserve_resources=True)
            raise ManagedStackCIError("unified_preflight_failed")
        base_receipt = _apply_or_reconcile(
            driver, "install", base_commit, selected_platform)
        driver.persist_installation_receipt(base_receipt["installationReceipt"])
        installed = _installation_receipt(
            driver.installation_receipt(), base_commit, selected_platform)
        if installed != base_receipt["installationReceipt"]:
            raise ManagedStackCIError("unified_installation_receipt_invalid")
        private_before = driver.private_state()

    upgrade = driver.deployment_preflight(commit, "upgrade")
    if (not isinstance(upgrade, dict) or upgrade.get("ready") is not True
            or upgrade.get("operation") != "upgrade"
            or upgrade.get("installedRevision") != base_commit
            or upgrade.get("targetRevision") != commit):
        raise ManagedStackCIError("unified_preflight_failed")
    current_receipt = _apply_or_reconcile(
        driver, "upgrade", commit, selected_platform)
    driver.persist_installation_receipt(current_receipt["installationReceipt"])
    installed = _installation_receipt(
        driver.installation_receipt(), commit, selected_platform)
    if installed != current_receipt["installationReceipt"]:
        raise ManagedStackCIError("unified_installation_receipt_invalid")
    _same_private_state(private_before, driver.private_state(), expected_private)
    return (base_source, base_receipt, current_receipt, private_before,
            did_recover)


def run_native(commit, selected_platform, driver, *, base_commit=None,
               reviewed_head_commit=None):
    if (not isinstance(commit, str) or not re.fullmatch(r"[a-f0-9]{40}", commit)
            or selected_platform not in {"linux/amd64", "linux/arm64"}):
        raise ManagedStackCIError("unified_launch_invalid")
    if base_commit is not None and (
            not isinstance(base_commit, str)
            or not re.fullmatch(r"[a-f0-9]{40}", base_commit)
            or base_commit == commit):
        raise ManagedStackCIError("unified_launch_invalid")
    if reviewed_head_commit is None:
        reviewed_head_commit = commit
    if (not isinstance(reviewed_head_commit, str)
            or not re.fullmatch(r"[a-f0-9]{40}", reviewed_head_commit)):
        raise ManagedStackCIError("unified_launch_invalid")
    primary = None
    result = None
    try:
        try:
            planner = package.UnifiedPackagePlanner(compose_path=COMPOSE, catalog_path=CATALOG)
            manifest = planner.preview(commit, driver)
        except Exception:
            raise ManagedStackCIError("unified_manifest_invalid") from None
        driver.prepare_owned(manifest)
        upgrade_evidence = None
        if base_commit is not None:
            expected_private = _persistent_mounts(manifest)
            if _persistent_mounts(_revision_manifest(base_commit)) != expected_private:
                raise ManagedStackCIError("unified_private_state_changed")
            upgrade_evidence = _install_upgrade(
                driver, base_commit, commit, selected_platform, expected_private)
        if upgrade_evidence is None:
            try:
                preflight = planner.preflight(manifest, driver)
            except Exception:
                raise ManagedStackCIError("unified_preflight_failed") from None
            if preflight.get("ready") is not True:
                raise ManagedStackCIError("unified_preflight_failed")
            pulls = _pull_receipts(driver.pull(manifest), manifest)
            driver.create(manifest)
            driver.start(manifest)
        else:
            pulls = _pull_receipts(
                driver.upgrade_runtime_receipts(manifest), manifest)
        initial = _container_receipts(driver.receipts(manifest, "initial"), manifest)
        initial_health = _public_health_receipts(
            driver, manifest, "initial", commit, selected_platform)
        driver.restart(manifest)
        restarted = _container_receipts(driver.receipts(manifest, "restart"), manifest)
        restart_health = _public_health_receipts(
            driver, manifest, "restart", commit, selected_platform)
        restart_runtime = None
        if upgrade_evidence is not None:
            restart_runtime = _runtime_receipt(
                driver.runtime_receipt(manifest, commit), commit)
            if restart_runtime != upgrade_evidence[2]["runtimeReceipt"]:
                raise ManagedStackCIError("unified_container_receipt_invalid")
        private_proofs = None
        if upgrade_evidence is not None:
            private_proofs = _same_private_state(
                upgrade_evidence[3], driver.private_state(), expected_private)
        services = {}
        for service_id in COMPONENTS:
            if restarted[service_id]["containerId"] != initial[service_id]["containerId"]:
                raise ManagedStackCIError("unified_container_receipt_invalid")
            try:
                readiness = driver.authenticated_readiness(service_id)
            except Exception:
                raise ManagedStackCIError("unified_readiness_invalid") from None
            if readiness != {"serviceId": service_id, "state": "not_verified",
                              "code": "bootstrap_authority_not_available"}:
                raise ManagedStackCIError("unified_readiness_invalid")
            services[service_id] = {
                "imageReceipt": pulls[service_id],
                "initialContainerReceipt": _public_container(initial[service_id]),
                "restartContainerReceipt": _public_container(restarted[service_id]),
                "initialPublicHealth": initial_health[service_id],
                "restartPublicHealth": restart_health[service_id],
                "authenticatedReadiness": readiness,
            }
        result = {
            "schemaVersion": 1,
            "result": "unified_media_stack_characterized",
            "platform": selected_platform,
            "sourceCommit": commit,
            "acceptanceSourceHashes": acceptance_source_hashes(),
            "manifestDigest": manifest["manifestDigest"],
            "composeConfigDigest": driver.config_digest,
            "ownershipReceiptDigest": driver.ownership_digest,
            "lifecycle": ["config", "pull", "create", "start", "restart"],
            "containerState": "verified",
            "publicHealthState": "verified",
            "serviceState": "not_verified",
            "automaticRetry": False,
            "cleanupState": (
                "deferred_until_verified"
                if upgrade_evidence is not None else "completed"),
            "services": services,
        }
        if upgrade_evidence is not None:
            base_source, base_receipt, current_receipt, _, _ = upgrade_evidence
            result.update({
                "upgradeSourceCommit": base_commit,
                "reviewedHeadCommit": reviewed_head_commit,
                "upgradeSourceTree": base_source["treeObject"],
                "reviewedHeadTree": _source_tree(reviewed_head_commit),
                "upgradeSourceHashes": base_source["sourceHashes"],
                "installationPhases": [
                    {"phase": "clean-install", "sourceRevision": base_commit,
                     "installationReceiptDigest":
                         base_receipt["installationReceipt"]["receiptDigest"],
                     "runtimeReceiptDigest": _digest({
                         "phase": "clean-install",
                         "runtimeReceipt": base_receipt["runtimeReceipt"]})},
                    {"phase": "upgrade", "sourceRevision": commit,
                     "installationReceiptDigest":
                         current_receipt["installationReceipt"]["receiptDigest"],
                     "runtimeReceiptDigest": _digest({
                         "phase": "upgrade",
                         "runtimeReceipt": current_receipt["runtimeReceipt"]})},
                    {"phase": "restart", "sourceRevision": commit,
                     "installationReceiptDigest":
                         current_receipt["installationReceipt"]["receiptDigest"],
                     "runtimeReceiptDigest": _digest({
                         "phase": "restart", "runtimeReceipt": restart_runtime})},
                ],
                "privateStateProofs": private_proofs,
                "recoveryState": ("post_effect_reconciled"
                                  if upgrade_evidence[4] else "not_required"),
                "effectReapplied": False,
            })
    except ManagedStackCIError as error:
        primary = error
    except Exception:
        primary = ManagedStackCIError("unified_native_runtime_failed")
    recovery_pending = bool(primary is not None and primary.preserve_resources)
    if primary is not None and base_commit is not None:
        try:
            recovery_pending = recovery_pending or driver.recovery_pending()
        except Exception:
            recovery_pending = True
    should_cleanup = (
        (result is not None and base_commit is None)
        or (primary is not None and not recovery_pending)
    )
    if should_cleanup:
        try:
            driver.cleanup()
        except Exception:
            raise ManagedStackCIError("unified_cleanup_failed") from None
    if primary is not None:
        raise primary
    return result


def _duplicate_safe(text):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError()
            value[key] = item
        return value
    return json.loads(text, object_pairs_hook=unique)


def _validate_receipt(value, commit, selected_platform, *, upgrade_source=None,
                      reviewed_head=None, expected_recovery=None):
    manifest = expected_manifest(commit)
    base_keys = {
            "schemaVersion", "result", "platform", "sourceCommit",
            "acceptanceSourceHashes", "manifestDigest", "composeConfigDigest",
            "ownershipReceiptDigest", "lifecycle", "containerState", "serviceState",
            "publicHealthState", "automaticRetry", "cleanupState", "services"}
    upgrade_keys = {
        "upgradeSourceCommit", "reviewedHeadCommit", "upgradeSourceTree",
        "reviewedHeadTree", "upgradeSourceHashes", "installationPhases",
        "privateStateProofs", "recoveryState", "effectReapplied",
    }
    expanded = isinstance(value, dict) and "upgradeSourceCommit" in value
    wanted_keys = base_keys | upgrade_keys if expanded else base_keys
    if (not isinstance(value, dict) or set(value) != wanted_keys
            or type(value.get("schemaVersion")) is not int
            or value.get("schemaVersion") != 1
            or value.get("result") != "unified_media_stack_characterized"
            or value.get("platform") != selected_platform
            or value.get("sourceCommit") != commit
            or value.get("acceptanceSourceHashes") != acceptance_source_hashes()
            or value.get("manifestDigest") != manifest["manifestDigest"]
            or not isinstance(value.get("composeConfigDigest"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", value["composeConfigDigest"])
            or not isinstance(value.get("ownershipReceiptDigest"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", value["ownershipReceiptDigest"])
            or value.get("lifecycle") != ["config", "pull", "create", "start", "restart"]
            or value.get("containerState") != "verified"
            or value.get("publicHealthState") != "verified"
            or value.get("serviceState") != "not_verified"
            or value.get("automaticRetry") is not False
            or value.get("cleanupState") != (
                "deferred_until_verified" if expanded else "completed")
            or not isinstance(value.get("services"), dict)
            or set(value["services"]) != set(COMPONENTS)):
        raise ManagedStackCIError("unified_characterization_evidence_invalid")
    if expanded:
        expected_base = upgrade_source
        expected_head = reviewed_head
        phases = value.get("installationPhases")
        private_proofs = value.get("privateStateProofs")
        base_hashes = value.get("upgradeSourceHashes")
        if (not isinstance(expected_base, str)
                or not re.fullmatch(r"[a-f0-9]{40}", expected_base)
                or expected_base == commit
                or value.get("upgradeSourceCommit") != expected_base
                or value.get("reviewedHeadCommit") != expected_head
                or expected_recovery not in {
                    "not_required", "post_effect_reconciled"}
                or value.get("recoveryState") != expected_recovery
                or value.get("effectReapplied") is not False
                or value.get("upgradeSourceTree") != _source_tree(expected_base)
                or value.get("reviewedHeadTree") != _source_tree(expected_head)
                or base_hashes != _source_evidence(expected_base)["sourceHashes"]
                or phases != [
                    {"phase": "clean-install", "sourceRevision": expected_base,
                     "installationReceiptDigest": phases[0].get(
                         "installationReceiptDigest"),
                     "runtimeReceiptDigest": phases[0].get("runtimeReceiptDigest")}
                    if isinstance(phases, list) and len(phases) == 3
                    and isinstance(phases[0], dict) else None,
                    {"phase": "upgrade", "sourceRevision": commit,
                     "installationReceiptDigest": phases[1].get(
                         "installationReceiptDigest"),
                     "runtimeReceiptDigest": phases[1].get("runtimeReceiptDigest")}
                    if isinstance(phases, list) and len(phases) == 3
                    and isinstance(phases[1], dict) else None,
                    {"phase": "restart", "sourceRevision": commit,
                     "installationReceiptDigest": phases[2].get(
                         "installationReceiptDigest"),
                     "runtimeReceiptDigest": phases[2].get("runtimeReceiptDigest")}
                    if isinstance(phases, list) and len(phases) == 3
                    and isinstance(phases[2], dict) else None,
                ]
                or any(any(not isinstance(item.get(key), str)
                           or not re.fullmatch(r"[a-f0-9]{64}", item[key])
                           for key in ("installationReceiptDigest",
                                       "runtimeReceiptDigest"))
                       for item in phases)
                or phases[1]["installationReceiptDigest"]
                   != phases[2]["installationReceiptDigest"]
                or not isinstance(private_proofs, list) or not private_proofs
                or any(not isinstance(item, dict) or set(item) != {
                           "serviceId", "containerTarget", "digest", "preserved"}
                       or item.get("serviceId") not in {"core", *COMPONENTS}
                       or not isinstance(item.get("containerTarget"), str)
                       or not item["containerTarget"].startswith("/")
                       or not isinstance(item.get("digest"), str)
                       or not re.fullmatch(r"[a-f0-9]{64}", item["digest"])
                       or item.get("preserved") is not True
                       for item in private_proofs)):
            raise ManagedStackCIError("unified_characterization_evidence_invalid")
        if {(item["serviceId"], item["containerTarget"])
                for item in private_proofs} != _persistent_mounts(manifest):
            raise ManagedStackCIError("unified_characterization_evidence_invalid")
    expected = {item["serviceId"]: item for item in manifest["components"]}
    for service_id in COMPONENTS:
        service = value["services"].get(service_id)
        if not isinstance(service, dict) or set(service) != {
                "imageReceipt", "initialContainerReceipt", "restartContainerReceipt",
                "initialPublicHealth", "restartPublicHealth", "authenticatedReadiness"}:
            raise ManagedStackCIError("unified_characterization_evidence_invalid")
        if service["imageReceipt"] != {
                "serviceId": service_id, "image": expected[service_id]["image"],
                "state": "pulled"}:
            raise ManagedStackCIError("unified_characterization_evidence_invalid")
        wanted_mounts = [{"target": item["target"], "readOnly": item["readOnly"]}
                         for item in expected[service_id]["mounts"]]
        for phase in ("initialContainerReceipt", "restartContainerReceipt"):
            container = service[phase]
            if (not isinstance(container, dict) or set(container) != {
                    "containerName", "containerIdentityDigest", "state", "dns",
                    "network", "mounts", "tmpfs"}
                    or container.get("containerName") != expected[service_id]["containerName"]
                    or not re.fullmatch(r"[a-f0-9]{64}", container.get("containerIdentityDigest", ""))
                    or container.get("state") != "running"
                    or container.get("dns") != (
                        "host_network" if service_id == "music_assistant" else "verified")
                    or container.get("network") != (
                        "host" if service_id == "music_assistant" else NETWORK)
                    or container.get("mounts") != wanted_mounts
                    or container.get("tmpfs") != expected[service_id]["tmpfs"]):
                raise ManagedStackCIError("unified_characterization_evidence_invalid")
        if (service["initialContainerReceipt"]["containerIdentityDigest"]
                != service["restartContainerReceipt"]["containerIdentityDigest"]
                or service["initialPublicHealth"] != {
                    "serviceId": service_id,
                    "profile": expected[service_id]["health"]["profile"],
                    "phase": "initial", "sourceRevision": commit,
                    "manifestDigest": manifest["manifestDigest"],
                    "platform": selected_platform, "state": "healthy",
                    "code": "public_probe_verified"}
                or service["restartPublicHealth"] != {
                    "serviceId": service_id,
                    "profile": expected[service_id]["health"]["profile"],
                    "phase": "restart", "sourceRevision": commit,
                    "manifestDigest": manifest["manifestDigest"],
                    "platform": selected_platform, "state": "healthy",
                    "code": "public_probe_verified"}
                or service["authenticatedReadiness"] != {
                    "serviceId": service_id, "state": "not_verified",
                    "code": "bootstrap_authority_not_available"}):
            raise ManagedStackCIError("unified_characterization_evidence_invalid")
    encoded = _canonical(value).lower()
    if len(encoded) > MAX_OUTPUT or any(term in encoded for term in (
            "token", "password", "credential", "authorization", "/var/lib")):
        raise ManagedStackCIError("unified_characterization_evidence_invalid")


def validate_receipt(value, commit, selected_platform, *, upgrade_source=None,
                     reviewed_head=None, expected_recovery=None):
    try:
        _validate_receipt(
            value, commit, selected_platform,
            upgrade_source=upgrade_source, reviewed_head=reviewed_head,
            expected_recovery=expected_recovery)
    except ManagedStackCIError:
        raise
    except (AttributeError, KeyError, OverflowError, TypeError, ValueError):
        raise ManagedStackCIError(
            "unified_characterization_evidence_invalid") from None


def verify(path, commit, selected_platform, *, upgrade_source=None,
           reviewed_head=None, expected_recovery=None):
    try:
        raw = Path(path).read_text()
        if len(raw.encode("utf-8")) > MAX_OUTPUT:
            raise ValueError()
        value = _duplicate_safe(raw)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        raise ManagedStackCIError("unified_characterization_evidence_invalid") from None
    validate_receipt(
        value, commit, selected_platform,
        upgrade_source=upgrade_source, reviewed_head=reviewed_head,
        expected_recovery=expected_recovery)


def _config_mounts(service):
    values = service.get("volumes", [])
    if not isinstance(values, list):
        raise ManagedStackCIError("unified_manifest_invalid")
    result = []
    for item in values:
        if not isinstance(item, dict) or item.get("type") != "bind":
            raise ManagedStackCIError("unified_manifest_invalid")
        bind = item.get("bind", {})
        if bind.get("create_host_path", False) is not False:
            raise ManagedStackCIError("unified_manifest_invalid")
        result.append({"source": item.get("source"), "target": item.get("target"),
                       "readOnly": item.get("read_only", False)})
    return sorted(result, key=lambda item: (str(item["source"]), str(item["target"])))


def _config_tmpfs(service):
    try:
        return package._tmpfs(service)
    except Exception:
        raise ManagedStackCIError("unified_manifest_invalid") from None


def _config_networks(service):
    value = service.get("networks", [])
    if isinstance(value, list):
        return set(value)
    if isinstance(value, dict):
        return set(value)
    raise ManagedStackCIError("unified_manifest_invalid")


def _network_alias(name):
    if name == package.CORE_NAME:
        return "core"
    for service_id, container_name in SERVICE_NAMES.items():
        if container_name == name:
            return service_id
    raise ManagedStackCIError("unified_manifest_invalid")


def _config_network_aliases(service, network):
    value = service.get("networks", {})
    if not isinstance(value, dict):
        return ()
    settings = value.get(network)
    if settings is None:
        return ()
    if not isinstance(settings, dict) or set(settings) - {"aliases"}:
        raise ManagedStackCIError("unified_manifest_invalid")
    aliases = settings.get("aliases", [])
    if (not isinstance(aliases, list)
            or any(not isinstance(alias, str) for alias in aliases)):
        raise ManagedStackCIError("unified_manifest_invalid")
    return tuple(aliases)


def _config_ports(service):
    result = []
    for item in service.get("ports", []):
        if isinstance(item, str):
            match = re.fullmatch(r"(?:0\.0\.0\.0:)?([0-9]+):([0-9]+)(?:/(tcp|udp))?", item)
            if not match:
                raise ManagedStackCIError("unified_manifest_invalid")
            result.append((match.group(1), int(match.group(2)), match.group(3) or "tcp"))
        elif isinstance(item, dict):
            published = item.get("published")
            target = item.get("target")
            protocol = item.get("protocol", "tcp")
            if (type(published) not in (str, int) or type(target) is not int
                    or protocol not in {"tcp", "udp"}
                    or item.get("host_ip", "0.0.0.0") not in {"", "0.0.0.0"}
                    or item.get("mode", "ingress") != "ingress"):
                raise ManagedStackCIError("unified_manifest_invalid")
            result.append((str(published), target, protocol))
        else:
            raise ManagedStackCIError("unified_manifest_invalid")
    return sorted(result)


def _config_extra_hosts(service):
    result = {}
    value = service.get("extra_hosts", [])
    if isinstance(value, dict):
        result = dict(value)
    elif isinstance(value, list):
        for item in value:
            if not isinstance(item, str) or not re.fullmatch(r"[^:=]+(?::|=)[^:=]+", item):
                raise ManagedStackCIError("unified_manifest_invalid")
            name, address = re.split(r":|=", item, maxsplit=1)
            result[name] = address
    else:
        raise ManagedStackCIError("unified_manifest_invalid")
    return result


def validate_rendered_config(rendered, expected, project_name, *, source_root=REPOSITORY):
    """Bind Docker's normalized config to every security/topology input we run."""
    if (not isinstance(rendered, dict) or not isinstance(expected, dict)
            or rendered.get("name") != project_name
            or not re.fullmatch(r"larenor-native-[a-f0-9]{32}", project_name)
            or set(rendered.get("services", {})) != set(expected.get("services", {}))
            or set(rendered.get("networks", {})) != {"control"}):
        raise ManagedStackCIError("unified_manifest_invalid")
    network = rendered["networks"]["control"]
    if (not isinstance(network, dict) or network.get("name") != NETWORK
            or network.get("driver", "bridge") != "bridge"
            or network.get("external", False) is not False
            or network.get("internal", False) is not False):
        raise ManagedStackCIError("unified_manifest_invalid")
    forbidden = re.compile(r"token|api.?key|password|credential|authorization|secret.?value", re.I)

    def private(value):
        if isinstance(value, dict):
            return any(forbidden.search(str(key)) or private(item)
                       for key, item in value.items())
        if isinstance(value, list):
            return any(private(item) for item in value)
        return False

    if private(rendered):
        raise ManagedStackCIError("unified_manifest_invalid")
    for name, wanted in expected["services"].items():
        actual = rendered["services"].get(name)
        if not isinstance(actual, dict):
            raise ManagedStackCIError("unified_manifest_invalid")
        for key in ("container_name", "image", "user", "environment", "labels",
                    "cap_drop", "cap_add", "security_opt", "restart", "logging", "init",
                    "links", "dns"):
            if actual.get(key) != wanted.get(key):
                raise ManagedStackCIError("unified_manifest_invalid")
        if (actual.get("privileged", False) is not False
                or actual.get("read_only", False) != wanted.get("read_only", False)
                or actual.get("devices", []) not in (None, [])
                or any(key in actual for key in (
                    "pid", "ipc", "uts", "cgroup", "secrets", "configs", "env_file"))
                or actual.get("command") is not None
                or actual.get("entrypoint") is not None
                or _config_mounts(actual) != _config_mounts(wanted)
                or _config_tmpfs(actual) != _config_tmpfs(wanted)
                or _config_ports(actual) != _config_ports(wanted)
                or _config_extra_hosts(actual) != _config_extra_hosts(wanted)):
            raise ManagedStackCIError("unified_manifest_invalid")
        if wanted.get("network_mode") == "host":
            if actual.get("network_mode") != "host" or _config_networks(actual):
                raise ManagedStackCIError("unified_manifest_invalid")
        elif (actual.get("network_mode") not in (None, "")
                or _config_networks(actual) != {"control"}
                or _config_network_aliases(actual, "control") != (_network_alias(name),)):
            raise ManagedStackCIError("unified_manifest_invalid")
    core_build = rendered["services"][package.CORE_NAME].get("build")
    expected_build = expected["services"][package.CORE_NAME]["build"]
    if (not isinstance(core_build, dict)
            or core_build.get("args") != expected_build["args"]
            or Path(core_build.get("context", "")).resolve() != source_root.resolve()
            or Path(core_build.get("dockerfile", "")).resolve()
            != (source_root / "server/Dockerfile").resolve()):
        raise ManagedStackCIError("unified_manifest_invalid")


class DockerDriver:
    def __init__(self, commit, selected_platform, ownership_receipt, *, operation_id=None,
                 fault_after_upgrade_journal=False):
        self.commit = commit
        self.platform = selected_platform
        self.ownership_receipt = Path(ownership_receipt)
        self.operation_id = uuid.uuid4().hex if operation_id is None else operation_id
        if not isinstance(self.operation_id, str) or not re.fullmatch(r"[a-f0-9]{32}", self.operation_id):
            raise ManagedStackCIError("unified_launch_invalid")
        self.project_name = "larenor-native-" + self.operation_id
        self.config_digest = None
        self.ownership_digest = None
        self._owned = False
        self._source_root = REPOSITORY
        self._compose_path = COMPOSE
        self._active_revision = commit
        self._base_root = None
        self._base_effect = None
        self._private_before = None
        self._journal_path = ROOT / ".native-upgrade-journal.json"
        self._installation_path = ROOT / ".larenor-installation.json"
        self._fault_after_upgrade_journal = fault_after_upgrade_journal
        self._environment = {
            "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": "/tmp",
            "LARENOR_SOURCE_REVISION": commit,
        }

    def _compose(self, *arguments, timeout=300, output=False, allow_failure=False):
        return _command(["/usr/bin/docker", "compose", "--project-name", self.project_name,
                         "-f", str(self._compose_path), *arguments],
                        environment=self._environment, timeout=timeout,
                        output=output, allow_failure=allow_failure)

    def config(self, path, revision):
        if Path(path) != COMPOSE or revision != self.commit:
            raise ManagedStackCIError("unified_manifest_invalid")
        self._compose("config", "--quiet", timeout=30)
        _, rendered = self._compose("config", "--format", "json", timeout=30, output=True)
        try:
            parsed = _duplicate_safe(rendered.decode("utf-8"))
        except (UnicodeError, ValueError, json.JSONDecodeError):
            raise ManagedStackCIError("unified_manifest_invalid") from None
        expected = SourceConfig().config(path, revision)
        validate_rendered_config(parsed, expected, self.project_name)
        self.config_digest = _digest(parsed)
        return expected

    def _activate(self, revision):
        if revision == self.commit:
            root = REPOSITORY
        elif self._base_root is not None:
            root = self._base_root
        else:
            raise ManagedStackCIError("unified_source_invalid")
        self._source_root = root
        self._compose_path = root / "deploy/larenor-server/unified.compose.yaml"
        self._active_revision = revision
        self._environment["LARENOR_SOURCE_REVISION"] = revision

    def _validate_active_config(self, revision):
        self._activate(revision)
        self._compose("config", "--quiet", timeout=30)
        _, rendered = self._compose(
            "config", "--format", "json", timeout=30, output=True)
        try:
            actual = _duplicate_safe(rendered.decode("utf-8"))
            expected = SourceConfig().config(self._compose_path, revision)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
            raise ManagedStackCIError("unified_manifest_invalid") from None
        validate_rendered_config(
            actual, expected, self.project_name, source_root=self._source_root)
        return _digest(actual)

    def materialize_base(self, revision):
        evidence = _source_evidence(revision)
        if self._base_root is not None:
            self._activate(revision)
            return evidence
        root = Path(tempfile.mkdtemp(prefix="larenor-native-base-"))
        archive = root.parent / (root.name + ".tar")
        try:
            _command(
                ["/usr/bin/git", "archive", "--format=tar", "--output", str(archive),
                 revision],
                environment={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"},
                output=False)
            total = 0
            with tarfile.open(archive, "r:") as stream:
                members = stream.getmembers()
                for member in members:
                    path = Path(member.name)
                    total += max(0, member.size)
                    if (path.is_absolute() or ".." in path.parts
                            or not (member.isdir() or member.isfile())
                            or total > 512 * 1024 * 1024):
                        raise ManagedStackCIError("unified_source_invalid")
                stream.extractall(root)
            archive.unlink()
        except (OSError, tarfile.TarError):
            shutil.rmtree(root, ignore_errors=True)
            archive.unlink(missing_ok=True)
            raise ManagedStackCIError("unified_source_invalid") from None
        self._base_root = root
        self._activate(revision)
        return evidence

    def _atomic_json(self, path, value, *, owner_uid=0):
        encoded = (_canonical(value) + "\n").encode("ascii")
        if len(encoded) > 128 * 1024:
            raise ManagedStackCIError("unified_native_runtime_failed")
        temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
        descriptor = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                os.fchown(stream.fileno(), owner_uid, owner_uid)
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise

    def _read_json(self, path, *, maximum=128 * 1024, expected_uid=0):
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(descriptor)
            if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                    or before.st_uid != expected_uid
                    or stat.S_IMODE(before.st_mode) != 0o600
                    or not 2 <= before.st_size <= maximum):
                raise ValueError()
            raw = os.read(descriptor, maximum + 1)
            after = os.fstat(descriptor)
            if (len(raw) != before.st_size or len(raw) > maximum
                    or (before.st_dev, before.st_ino, before.st_size,
                        before.st_mtime_ns, before.st_ctime_ns)
                    != (after.st_dev, after.st_ino, after.st_size,
                        after.st_mtime_ns, after.st_ctime_ns)):
                raise ValueError()
            return _duplicate_safe(raw.decode("ascii", "strict"))
        except (UnicodeError, ValueError, json.JSONDecodeError):
            raise ManagedStackCIError("unified_upgrade_reconcile_failed") from None
        finally:
            os.close(descriptor)

    def _root_identity(self):
        try:
            info = os.lstat(ROOT)
            receipt = _read_ownership(self.ownership_receipt, self.commit)
        except OSError:
            raise ManagedStackCIError("unified_upgrade_reconcile_failed") from None
        if (not stat.S_ISDIR(info.st_mode) or receipt is None
                or receipt["operationId"] != self.operation_id
                or receipt["projectName"] != self.project_name
                or receipt["rootDevice"] != info.st_dev
                or receipt["rootInode"] != info.st_ino):
            raise ManagedStackCIError("unified_upgrade_reconcile_failed")
        return hashlib.sha256((
            str(info.st_dev) + ":" + str(info.st_ino) + ":" + self.operation_id
        ).encode("ascii")).hexdigest()

    def _make_installation_receipt(self, revision):
        bundle = _revision_contract(revision)
        manifest = bundle["deploymentManifest"]
        value = {
            "schemaVersion": 1, "state": "installed",
            "installationId": self.operation_id,
            "sourceRevision": revision,
            "releaseVersion": manifest["releaseVersion"],
            "manifestDigest": manifest["manifestDigest"],
            "bundleDigest": bundle["bundleDigest"],
            "architecture": self.platform.removeprefix("linux/"),
            "dataRoot": str(ROOT), "entrypoint": manifest["entrypoint"],
            "settingsSchemaDigest": manifest["settingsSchemaDigest"],
        }
        value["receiptDigest"] = _digest(value)
        return value

    def _runtime_evidence(self, manifest, revision):
        values = self.receipts(manifest, "initial")
        by_id = _container_receipts(values, manifest)
        _, raw = _command(
            ["/usr/bin/docker", "container", "inspect", package.CORE_NAME],
            environment=self._environment, timeout=30, output=True)
        try:
            core = _duplicate_safe(raw.decode("utf-8"))[0]
            core_id = core["Id"]
            core_image = core["Config"]["Image"]
            core_running = core["State"]["Running"]
        except (UnicodeError, ValueError, json.JSONDecodeError, KeyError,
                IndexError, TypeError):
            raise ManagedStackCIError("unified_container_receipt_invalid") from None
        if (not re.fullmatch(r"[a-f0-9]{64}", core_id)
                or core_image != manifest["core"]["image"]
                or core_running is not True):
            raise ManagedStackCIError("unified_container_receipt_invalid")
        return {
            "schemaVersion": 1,
            "sourceRevision": revision,
            "manifestDigest": manifest["manifestDigest"],
            "core": {
                "image": core_image,
                "containerIdentityDigest": hashlib.sha256(
                    ("larenor-container-v1\0" + core_id).encode("ascii")).hexdigest(),
                "state": "running",
            },
            "services": [{
                "serviceId": service_id,
                "image": next(item["image"] for item in manifest["components"]
                              if item["serviceId"] == service_id),
                "containerIdentityDigest": _public_container(
                    by_id[service_id])["containerIdentityDigest"],
                "state": "running",
            } for service_id in COMPONENTS],
        }

    def _mount_specs(self, manifest):
        values = [("core", item) for item in manifest["core"]["mounts"]]
        values.extend((component["serviceId"], item)
                      for component in manifest["components"]
                      for item in component["mounts"])
        result = []
        for service_id, item in values:
            if item["readOnly"] is False:
                source = Path(item["source"])
                if ROOT not in source.parents:
                    raise ManagedStackCIError("unified_private_state_changed")
                result.append((service_id, item["target"], source))
        if {(service, target) for service, target, _ in result} != _persistent_mounts(manifest):
            raise ManagedStackCIError("unified_private_state_changed")
        return result

    def _seed_private_state(self, manifest):
        for service_id, target, source in self._mount_specs(manifest):
            name = ".native-ci-sentinel-" + hashlib.sha256(
                (service_id + "\0" + target).encode("utf-8")).hexdigest()[:16]
            path = source / name
            raw = secrets.token_bytes(32)
            descriptor = os.open(
                path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())

    def private_state(self):
        manifest = _revision_manifest(self.commit)
        result = []
        for service_id, target, source in self._mount_specs(manifest):
            name = ".native-ci-sentinel-" + hashlib.sha256(
                (service_id + "\0" + target).encode("utf-8")).hexdigest()[:16]
            path = source / name
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                info = os.fstat(descriptor)
                raw = os.read(descriptor, 33)
                after = os.fstat(descriptor)
                if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                        or info.st_size != 32 or len(raw) != 32
                        or (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_ctime_ns)
                        != (after.st_dev, after.st_ino,
                            after.st_mtime_ns, after.st_ctime_ns)):
                    raise ManagedStackCIError("unified_private_state_changed")
            finally:
                os.close(descriptor)
            result.append({"serviceId": service_id, "containerTarget": target,
                           "digest": hashlib.sha256(raw).hexdigest()})
        return result

    def _deployment_module(self):
        spec = importlib.util.spec_from_file_location(
            "larenor_native_bundle_" + self._active_revision,
            REPOSITORY / "deploy/larenor-server/deployment_bundle.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.HERE = self._source_root / "deploy/larenor-server"
        return module

    def _deployment_planner(self):
        module = self._deployment_module()
        return module.DeploymentBundlePlanner(
            compose_path=self._compose_path,
            catalog_path=self._source_root
            / "server/larenor_server/plugins/packagedcatalog.json",
            env_example_path=self._source_root
            / "deploy/larenor-server/.env.example")

    def deployment_preflight(self, revision, operation):
        if operation not in {"install", "upgrade"}:
            raise ManagedStackCIError("unified_preflight_failed")
        self._activate(revision)
        if operation == "upgrade":
            try:
                installed = self.installation_receipt()
            except FileNotFoundError:
                installed = None
            if installed is None:
                raise ManagedStackCIError("unified_preflight_failed")
            _installation_receipt(
                installed, installed.get("sourceRevision"), self.platform)
        try:
            module = self._deployment_module()
            host = module.LocalHostFacts(
                ROOT, expected_uid=OWNED_UID,
                architecture=self.platform.removeprefix("linux/"))
            result = self._deployment_planner().preflight(
                _revision_contract(revision), operation, host)
        except Exception:
            raise ManagedStackCIError("unified_preflight_failed") from None
        if not isinstance(result, dict):
            raise ManagedStackCIError("unified_preflight_failed")
        return result

    def _journal(self, operation, target, *, base_effect=None,
                 current_effect=None, private_state=None):
        return {
            "schemaVersion": 1, "operation": operation,
            "upgradeSourceCommit": (
                base_effect["installationReceipt"]["sourceRevision"]
                if base_effect is not None else target),
            "targetRevision": target,
            "rootIdentity": self._root_identity(),
            "baseEffect": copy.deepcopy(base_effect),
            "currentEffect": copy.deepcopy(current_effect),
            "privateState": copy.deepcopy(private_state),
        }

    def apply_install(self, revision):
        self._activate(revision)
        manifest = _revision_manifest(revision)
        self._validate_active_config(revision)
        self._atomic_json(
            self._journal_path, self._journal("install", revision))
        self.pull(manifest)
        self.create(manifest)
        self.start(manifest)
        _public_health_receipts(self, manifest, "initial", revision, self.platform)
        self._seed_private_state(manifest)
        effect = {"installationReceipt": self._make_installation_receipt(revision),
                  "runtimeReceipt": self._runtime_evidence(manifest, revision)}
        self._atomic_json(
            self._journal_path, self._journal(
                "install", revision, current_effect=effect,
                private_state=self.private_state()))
        self._base_effect = copy.deepcopy(effect)
        return effect

    def apply_upgrade(self, revision):
        if self._base_effect is None or self._private_before is None:
            raise ManagedStackCIError("unified_upgrade_reconcile_failed")
        self._activate(revision)
        manifest = _revision_manifest(revision)
        self.config_digest = self._validate_active_config(revision)
        self._atomic_json(
            self._journal_path, self._journal(
                "upgrade", revision, base_effect=self._base_effect,
                private_state=self._private_before))
        self.pull(manifest)
        try:
            self._compose("up", "--detach", "--no-build", "--force-recreate",
                          timeout=300)
        except ManagedStackCIError:
            raise ManagedStackCIError("unified_start_runtime_failed") from None
        _public_health_receipts(self, manifest, "initial", revision, self.platform)
        effect = {"installationReceipt": self._make_installation_receipt(revision),
                  "runtimeReceipt": self._runtime_evidence(manifest, revision)}
        self._atomic_json(
            self._journal_path, self._journal(
                "upgrade", revision, base_effect=self._base_effect,
                current_effect=effect, private_state=self._private_before))
        if self._fault_after_upgrade_journal:
            fault = (_canonical({
                "schemaVersion": 1,
                "result": "fault_injected",
                "code": "unified_upgrade_recovery_pending",
            }) + "\n").encode("ascii")
            if os.write(sys.stdout.fileno(), fault) != len(fault):
                os._exit(74)
            os.fsync(sys.stdout.fileno())
            os._exit(75)
        return effect

    def persist_installation_receipt(self, receipt):
        _installation_receipt(receipt, receipt.get("sourceRevision"), self.platform)
        self._atomic_json(self._installation_path, receipt, owner_uid=OWNED_UID)
        if receipt["sourceRevision"] == self.commit:
            self._journal_path.unlink(missing_ok=True)
        directory = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        if receipt["sourceRevision"] != self.commit:
            self._base_effect = {
                "installationReceipt": copy.deepcopy(receipt),
                "runtimeReceipt": copy.deepcopy(
                    self._base_effect["runtimeReceipt"]),
            }
            self._private_before = self.private_state()

    def installation_receipt(self):
        return self._read_json(
            self._installation_path, maximum=4096, expected_uid=OWNED_UID)

    def recovery_pending(self):
        return self._journal_path.exists() or self._journal_path.is_symlink()

    def recovery_operation(self):
        if not self.recovery_pending():
            return None
        try:
            value = self._read_json(self._journal_path)
        except Exception:
            raise ManagedStackCIError(
                "unified_upgrade_reconcile_failed", preserve_resources=True) from None
        if (not isinstance(value, dict) or type(value.get("schemaVersion")) is not int
                or value["schemaVersion"] != 1
                or value.get("operation") not in {"install", "upgrade"}):
            raise ManagedStackCIError(
                "unified_upgrade_reconcile_failed", preserve_resources=True)
        return value["operation"]

    def reconcile_upgrade(self, revision, operation):
        if not self.recovery_pending():
            return None
        try:
            value = self._read_json(self._journal_path)
        except Exception:
            raise ManagedStackCIError(
                "unified_upgrade_reconcile_failed", preserve_resources=True) from None
        if (not isinstance(value, dict) or set(value) != {
                "schemaVersion", "operation", "upgradeSourceCommit",
                "targetRevision", "rootIdentity", "baseEffect", "currentEffect",
                "privateState"}
                or type(value.get("schemaVersion")) is not int
                or value["schemaVersion"] != 1 or value.get("operation") != operation
                or value.get("targetRevision") != revision
                or value.get("rootIdentity") != self._root_identity()
                or value.get("currentEffect") is None):
            raise ManagedStackCIError(
                "unified_upgrade_reconcile_failed", preserve_resources=True)
        if operation == "install":
            if (value.get("upgradeSourceCommit") != revision
                    or value.get("baseEffect") is not None
                    or not isinstance(value.get("privateState"), list)
                    or not value["privateState"]):
                raise ManagedStackCIError(
                    "unified_install_reconcile_failed", preserve_resources=True)
            current = _effect_receipt(
                value.get("currentEffect"), revision, self.platform)
            private = value.get("privateState")
            self._activate(revision)
            actual = self._runtime_evidence(_revision_manifest(revision), revision)
            if actual != current["runtimeReceipt"]:
                raise ManagedStackCIError(
                    "unified_install_reconcile_failed", preserve_resources=True)
            _same_private_state(
                private, self.private_state(),
                _persistent_mounts(_revision_manifest(revision)))
            self._base_effect = copy.deepcopy(current)
            self._private_before = copy.deepcopy(private)
            return current
        base_revision = value.get("upgradeSourceCommit")
        base = _effect_receipt(value.get("baseEffect"), base_revision, self.platform)
        current = _effect_receipt(value.get("currentEffect"), revision, self.platform)
        private = value.get("privateState")
        self._activate(revision)
        actual = self._runtime_evidence(_revision_manifest(revision), revision)
        if actual != current["runtimeReceipt"]:
            raise ManagedStackCIError(
                "unified_upgrade_reconcile_failed", preserve_resources=True)
        _same_private_state(
            private, self.private_state(),
            _persistent_mounts(_revision_manifest(revision)))
        self._base_effect = copy.deepcopy(base)
        self._private_before = copy.deepcopy(private)
        return {"baseEffect": base, "currentEffect": current,
                "privateState": private}

    def upgrade_runtime_receipts(self, manifest):
        return [{"serviceId": item["serviceId"], "image": item["image"],
                 "state": "pulled"} for item in manifest["components"]]

    def runtime_receipt(self, manifest, revision):
        if revision != self.commit or self._active_revision != revision:
            raise ManagedStackCIError("unified_container_receipt_invalid")
        return self._runtime_evidence(manifest, revision)

    def _docker_list(self, arguments):
        _, value = _command(["/usr/bin/docker", *arguments], environment=self._environment,
                            timeout=30, output=True)
        return value.decode("ascii", "strict").strip()

    def prepare_owned(self, manifest):
        if os.geteuid() != 0:
            raise ManagedStackCIError("unified_foreign_resource")
        if ROOT.exists() or ROOT.is_symlink():
            if not self.recovery_pending():
                raise ManagedStackCIError("unified_foreign_resource")
            existing = _read_ownership(self.ownership_receipt, self.commit)
            if existing is None:
                raise ManagedStackCIError("unified_foreign_resource")
            self.operation_id = existing["operationId"]
            self.project_name = existing["projectName"]
            encoded = (_canonical(existing) + "\n").encode("ascii")
            self.ownership_digest = hashlib.sha256(encoded).hexdigest()
            self._owned = True
            self._root_identity()
            return
        _, engine_platform = _command(
            ["/usr/bin/docker", "version", "--format", "{{.Server.Os}}/{{.Server.Arch}}"],
            environment=self._environment, timeout=30, output=True)
        try:
            observed_platform = engine_platform.decode("ascii", "strict").strip()
        except UnicodeError:
            raise ManagedStackCIError("unified_native_runtime_failed") from None
        if observed_platform != self.platform:
            raise ManagedStackCIError("unified_native_runtime_failed")
        for name in (package.CORE_NAME, *SERVICE_NAMES.values()):
            if self._docker_list(["container", "ls", "-a", "--filter", "name=^/" + name + "$",
                                  "--format", "{{.ID}}"]):
                raise ManagedStackCIError("unified_foreign_resource")
        if self._docker_list(["network", "ls", "--filter", "name=^" + NETWORK + "$",
                              "--format", "{{.ID}}"]):
            raise ManagedStackCIError("unified_foreign_resource")
        if not self.ownership_receipt.is_absolute() or self.ownership_receipt.is_symlink():
            raise ManagedStackCIError("unified_foreign_resource")
        ROOT.mkdir(mode=0o700)
        os.chown(ROOT, OWNED_UID, OWNED_UID)
        requirements = _revision_contract(self.commit)[
            "deploymentManifest"]["ownedPaths"]
        for requirement in requirements:
            path = Path(requirement["path"])
            if path != ROOT and ROOT not in path.parents and path not in {
                    ROOT.parent / (ROOT.name + "-backups"),
                    ROOT.parent / (ROOT.name + "-rollback")}:
                raise ManagedStackCIError("unified_foreign_resource")
            path.mkdir(parents=True, exist_ok=True)
            os.chown(path, requirement["ownerUid"], requirement["ownerUid"])
            os.chmod(path, 0o700)
        root_info = os.lstat(ROOT)
        if (not stat.S_ISDIR(root_info.st_mode) or ROOT.is_symlink()
                or root_info.st_uid != OWNED_UID
                or stat.S_IMODE(root_info.st_mode) != 0o700):
            raise ManagedStackCIError("unified_foreign_resource")
        external = []
        for path in _external_owned_roots():
            try:
                info = os.lstat(path)
            except OSError:
                raise ManagedStackCIError("unified_foreign_resource") from None
            if (path.is_symlink() or not stat.S_ISDIR(info.st_mode)
                    or info.st_uid != OWNED_UID
                    or stat.S_IMODE(info.st_mode) != 0o700):
                raise ManagedStackCIError("unified_foreign_resource")
            external.append({
                "path": str(path), "device": info.st_dev, "inode": info.st_ino,
            })
        receipt = {"schemaVersion": 1, "operationId": self.operation_id,
                   "sourceCommit": self.commit, "root": str(ROOT),
                   "rootDevice": root_info.st_dev, "rootInode": root_info.st_ino,
                   "externalRoots": external,
                   "projectName": self.project_name}
        encoded = (_canonical(receipt) + "\n").encode("ascii")
        fd = os.open(
            self.ownership_receipt,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        parent_fd = os.open(self.ownership_receipt.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
        self.ownership_digest = hashlib.sha256(encoded).hexdigest()
        self._owned = True

    def pull(self, manifest):
        for service_id in COMPONENTS:
            try:
                self._compose("pull", "--quiet", SERVICE_NAMES[service_id], timeout=900)
            except ManagedStackCIError:
                raise ManagedStackCIError("unified_pull_runtime_failed") from None
        try:
            self._compose("build", "--pull", "larenor-core", timeout=900)
        except ManagedStackCIError:
            raise ManagedStackCIError("unified_build_runtime_failed") from None
        receipts = []
        architecture = self.platform.split("/", 1)[1]
        for item in manifest["components"]:
            _, raw = _command(["/usr/bin/docker", "image", "inspect", item["image"]],
                              environment=self._environment, timeout=30, output=True)
            try:
                values = _duplicate_safe(raw.decode("utf-8"))
                image = values[0]
                repo_digests = image["RepoDigests"]
            except (UnicodeError, ValueError, json.JSONDecodeError, KeyError, IndexError, TypeError):
                raise ManagedStackCIError("unified_pull_receipt_invalid") from None
            if (image.get("Os") != "linux" or image.get("Architecture") != architecture
                    or item["image"] not in repo_digests):
                raise ManagedStackCIError("unified_pull_receipt_invalid")
            receipts.append({"serviceId": item["serviceId"], "image": item["image"],
                             "state": "pulled"})
        return receipts

    def create(self, manifest):
        try:
            self._compose("create", "--no-build", timeout=300)
        except ManagedStackCIError:
            raise ManagedStackCIError("unified_create_runtime_failed") from None

    def start(self, manifest):
        try:
            # `compose start` only asks Engine to start containers produced by
            # the earlier create phase. On fresh GitHub-hosted daemons that
            # path left canonical service discovery absent until the project was
            # re-converged. Re-converging the exact
            # already-created project with --no-recreate keeps container
            # identity stable while Compose activates its network endpoints.
            self._compose("up", "--detach", "--no-build", "--no-recreate",
                          *SERVICE_NAMES.values(), timeout=180)
            self._compose("up", "--detach", "--no-build", "--no-recreate",
                          package.CORE_NAME, timeout=180)
        except ManagedStackCIError:
            raise ManagedStackCIError("unified_start_runtime_failed") from None

    def restart(self, manifest):
        try:
            self._compose("restart", "--timeout", "30", *SERVICE_NAMES.values(),
                          timeout=240)
            self._compose("restart", "--timeout", "30", package.CORE_NAME,
                          timeout=240)
        except ManagedStackCIError:
            raise ManagedStackCIError("unified_restart_runtime_failed") from None

    def receipts(self, manifest, phase):
        self._await_core_runtime()
        values = []
        bridge_peers = []
        for item in manifest["components"]:
            _, raw = _command(["/usr/bin/docker", "container", "inspect",
                               item["containerName"]], environment=self._environment,
                              timeout=30, output=True)
            try:
                current = _duplicate_safe(raw.decode("utf-8"))[0]
                mounts = current["Mounts"]
                network_mode = current["HostConfig"]["NetworkMode"]
                observed_tmpfs = current["HostConfig"].get("Tmpfs") or {}
                networks = current["NetworkSettings"]["Networks"]
            except (UnicodeError, ValueError, json.JSONDecodeError, KeyError, IndexError, TypeError):
                raise ManagedStackCIError("unified_container_receipt_invalid") from None
            expected_mounts = {(entry["source"], entry["target"], not entry["readOnly"])
                               for entry in item["mounts"]}
            actual_mounts = {(entry.get("Source"), entry.get("Destination"), entry.get("RW"))
                             for entry in mounts if entry.get("Type") == "bind"}
            if actual_mounts != expected_mounts or current.get("Config", {}).get("Image") != item["image"]:
                raise ManagedStackCIError("unified_container_receipt_invalid")
            try:
                normalized_tmpfs = package._tmpfs({
                    "tmpfs": [target + ":" + options
                              for target, options in observed_tmpfs.items()],
                })
            except Exception:
                raise ManagedStackCIError("unified_container_receipt_invalid") from None
            if normalized_tmpfs != item["tmpfs"]:
                raise ManagedStackCIError("unified_container_receipt_invalid")
            if current.get("State", {}).get("Running") is not True:
                raise ManagedStackCIError("unified_container_receipt_invalid")
            if item["serviceId"] == "music_assistant":
                if network_mode != "host":
                    raise ManagedStackCIError("unified_container_receipt_invalid")
                dns, network = "host_network", "host"
            else:
                aliases = networks.get(NETWORK, {}).get("Aliases", [])
                if network_mode != NETWORK or item["serviceId"] not in aliases:
                    raise ManagedStackCIError("unified_container_receipt_invalid")
                bridge_peers.append((
                    item["serviceId"], package.SERVICE_NAMES[item["serviceId"]]))
                dns, network = "verified", NETWORK
            values.append({
                "serviceId": item["serviceId"], "containerName": item["containerName"],
                "image": item["image"], "containerId": current.get("Id"),
                "state": "running",
                "dns": dns, "network": network,
                "mounts": [{"target": entry["target"], "readOnly": entry["readOnly"]}
                           for entry in item["mounts"]],
                "tmpfs": normalized_tmpfs,
            })
        self._verify_dns_peers(bridge_peers)
        return values

    def _dns_probe(self, name):
        code = "import socket,sys; assert socket.gethostbyname(sys.argv[1])"
        status, _ = _command(
            ["/usr/bin/docker", "exec", package.CORE_NAME,
             "/opt/larenor/.venv/bin/python", "-B", "-c", code, name],
            environment=self._environment, timeout=10, output=False,
            allow_failure=True,
        )
        return status == 0

    def _dns_peer_mask(self, peers):
        names = [name for pair in peers for name in pair]
        if len(names) != 10 or any(not isinstance(name, str) or not name for name in names):
            raise ManagedStackCIError("unified_manifest_invalid")
        code = (
            "import socket,sys; bits=[]; "
            "exec(\"for name in sys.argv[1:]:\\n try:\\n  "
            "socket.getaddrinfo(name,None); bits.append('0')\\n except OSError:\\n  "
            "bits.append('1')\"); "
            "print(''.join(bits))"
        )
        status, raw = _command(
            ["/usr/bin/docker", "exec", package.CORE_NAME,
             "/opt/larenor/.venv/bin/python", "-B", "-c", code, *names],
            environment=self._environment, timeout=10, output=True,
            allow_failure=True,
        )
        try:
            mask = raw.decode("ascii", "strict").strip()
        except UnicodeError:
            raise ManagedStackCIError("unified_dns_runtime_failed") from None
        if status != 0 or not re.fullmatch(r"[01]{10}", mask):
            raise ManagedStackCIError("unified_dns_runtime_failed")
        return mask

    def _embedded_dns_configured(self):
        code = ("from pathlib import Path; "
                "lines=Path('/etc/resolv.conf').read_text().splitlines(); "
                "assert any(line.split()==['nameserver','127.0.0.11'] "
                "for line in lines)")
        status, _ = _command(
            ["/usr/bin/docker", "exec", package.CORE_NAME,
             "/opt/larenor/.venv/bin/python", "-B", "-c", code],
            environment=self._environment, timeout=10, output=False,
            allow_failure=True,
        )
        return status == 0

    def _await_dns(self, name, failure_code, *, timeout, interval):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._dns_probe(name):
                return
            time.sleep(interval)
        raise ManagedStackCIError(failure_code)

    def _verify_dns_peers(self, peers, *, timeout=30, interval=2):
        if not self._embedded_dns_configured():
            raise ManagedStackCIError("unified_dns_resolver_unavailable")
        self._await_dns("core", "unified_dns_core_service_failed",
                        timeout=timeout, interval=interval)
        deadline = time.monotonic() + timeout
        mask = "1" * 10
        while time.monotonic() < deadline:
            mask = self._dns_peer_mask(peers)
            if mask == "0" * 10:
                return
            time.sleep(interval)
        raise ManagedStackCIError("unified_dns_peers_failed_" + mask)

    def _await_core_runtime(self, *, timeout=180, interval=2):
        """Wait for the package's public Core health check without reading logs."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status, raw = _command(
                ["/usr/bin/docker", "container", "inspect", "--format",
                 "{{json .State}}", package.CORE_NAME],
                environment=self._environment, timeout=10, output=True,
                allow_failure=True,
            )
            if status == 0:
                try:
                    state = _duplicate_safe(raw.decode("utf-8").strip())
                except (UnicodeError, ValueError, json.JSONDecodeError):
                    raise ManagedStackCIError("unified_core_runtime_unready") from None
                health = state.get("Health") if isinstance(state, dict) else None
                if (isinstance(health, dict) and state.get("Running") is True
                        and health.get("Status") == "healthy"):
                    return
                if (not isinstance(state, dict) or state.get("Running") is not True
                        or not isinstance(health, dict)
                        or health.get("Status") not in {"starting", "healthy"}):
                    raise ManagedStackCIError("unified_core_runtime_unready")
            time.sleep(interval)
        raise ManagedStackCIError("unified_core_runtime_unready")

    def public_health(self, component, phase, source_revision, manifest_digest,
                      selected_platform, *, timeout=90, interval=2):
        if (not isinstance(component, dict) or phase not in {"initial", "restart"}
                or component.get("serviceId") not in COMPONENTS
                or not isinstance(component.get("health"), dict)
                or source_revision != self._active_revision
                or selected_platform != self.platform
                or not re.fullmatch(r"[a-f0-9]{64}", manifest_digest)):
            raise ManagedStackCIError("unified_health_probe_failed")
        service_id = component["serviceId"]
        health = component["health"]
        expected = (expected_manifest(source_revision)
                    if source_revision == self.commit
                    and self._source_root == REPOSITORY
                    else _revision_manifest(source_revision))
        wanted = next((item for item in expected["components"]
                       if item["serviceId"] == service_id), None)
        if (wanted is None or health != wanted["health"]
                or manifest_digest != expected["manifestDigest"]):
            raise ManagedStackCIError("unified_health_probe_failed")
        host = "host.docker.internal" if service_id == "music_assistant" else service_id
        arguments = [
            "/usr/bin/docker", "exec", package.CORE_NAME,
            "/opt/larenor/.venv/bin/python", "-B", "-c", _PUBLIC_HEALTH_PROBE,
            health["profile"], host, str(health["port"]), health["path"],
        ]
        deadline = time.monotonic() + timeout
        while True:
            status, raw = _command(
                arguments, environment=self._environment, timeout=10, output=True,
                allow_failure=True,
            )
            if status == 0 and raw == b"healthy\n":
                return {
                    "serviceId": service_id, "profile": health["profile"],
                    "phase": phase, "sourceRevision": source_revision,
                    "manifestDigest": manifest_digest, "platform": selected_platform,
                    "state": "healthy", "code": "public_probe_verified",
                }
            if time.monotonic() >= deadline:
                raise ManagedStackCIError("unified_health_probe_failed")
            time.sleep(interval)

    def authenticated_readiness(self, service_id):
        if service_id not in COMPONENTS:
            raise ManagedStackCIError("unified_readiness_invalid")
        # Native package acceptance must not manufacture or print credentials.
        # S06.5 owns bootstrap. Until its retained authority is supplied, the
        # only truthful state is explicit non-verification.
        return {"serviceId": service_id, "state": "not_verified",
                "code": "bootstrap_authority_not_available"}

    def cleanup(self):
        if self.recovery_pending():
            raise ManagedStackCIError("unified_upgrade_recovery_pending")
        cleanup_owned(self.ownership_receipt, self.commit)
        self._owned = False
        if self._base_root is not None:
            shutil.rmtree(self._base_root, ignore_errors=True)
            self._base_root = None


def _read_ownership(path, commit):
    path = Path(path)
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or before.st_uid != os.geteuid()
                or stat.S_IMODE(before.st_mode) != 0o600
                or not 2 <= before.st_size <= 4096):
            raise ValueError()
        raw = os.read(descriptor, 4097)
        after = os.fstat(descriptor)
        entry = os.stat(path, follow_symlinks=False)
        identity = lambda item: (
            item.st_dev, item.st_ino, item.st_size,
            item.st_mtime_ns, item.st_ctime_ns,
        )
        if (len(raw) != before.st_size or len(raw) > 4096
                or identity(before) != identity(after)
                or identity(after) != identity(entry)):
            raise ValueError()
        value = _duplicate_safe(raw.decode("ascii", "strict"))
    except FileNotFoundError:
        if any(path.exists() or path.is_symlink()
               for path in (ROOT, *_external_owned_roots())):
            raise ManagedStackCIError("unified_cleanup_not_owned") from None
        return None
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        raise ManagedStackCIError("unified_cleanup_not_owned") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if (not isinstance(value, dict) or set(value) != {
            "schemaVersion", "operationId", "sourceCommit", "root",
            "rootDevice", "rootInode", "externalRoots", "projectName"}
            or type(value.get("schemaVersion")) is not int
            or value.get("schemaVersion") != 1
            or not re.fullmatch(r"[a-f0-9]{32}", value.get("operationId", ""))
            or value.get("sourceCommit") != commit or value.get("root") != str(ROOT)
            or type(value.get("rootDevice")) is not int
            or type(value.get("rootInode")) is not int
            or value["rootDevice"] < 0 or value["rootInode"] <= 0
            or not isinstance(value.get("externalRoots"), list)
            or len(value["externalRoots"]) != len(_external_owned_roots())
            or any(not isinstance(item, dict) or set(item) != {
                       "path", "device", "inode"}
                   or item.get("path") != str(path)
                   or type(item.get("device")) is not int
                   or type(item.get("inode")) is not int
                   or item["device"] < 0 or item["inode"] <= 0
                   for item, path in zip(
                       value["externalRoots"], _external_owned_roots()))
            or value.get("projectName") != "larenor-native-" + value.get("operationId", "")):
        raise ManagedStackCIError("unified_cleanup_not_owned")
    owned = [(ROOT, value["rootDevice"], value["rootInode"])] + [
        (Path(item["path"]), item["device"], item["inode"])
        for item in value["externalRoots"]
    ]
    for candidate, device, inode in owned:
        if not (candidate.exists() or candidate.is_symlink()):
            continue
        try:
            info = os.lstat(candidate)
        except OSError:
            raise ManagedStackCIError("unified_cleanup_not_owned") from None
        if (candidate.is_symlink() or not stat.S_ISDIR(info.st_mode)
                or info.st_dev != device or info.st_ino != inode
                or info.st_uid != OWNED_UID or info.st_nlink < 1
                or stat.S_IMODE(info.st_mode) != 0o700):
            raise ManagedStackCIError("unified_cleanup_not_owned")
    return value


def cleanup_owned(receipt_path, commit):
    value = _read_ownership(receipt_path, commit)
    if value is None:
        return
    pending = ROOT / ".native-upgrade-journal.json"
    if pending.exists() or pending.is_symlink():
        raise ManagedStackCIError("unified_cleanup_not_owned")
    installed_path = ROOT / ".larenor-installation.json"
    if installed_path.exists() or installed_path.is_symlink():
        descriptor = None
        try:
            descriptor = os.open(
                installed_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            before = os.fstat(descriptor)
            if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                    or before.st_uid != OWNED_UID
                    or stat.S_IMODE(before.st_mode) != 0o600
                    or not 2 <= before.st_size <= 4096):
                raise ValueError()
            raw = os.read(descriptor, 4097)
            after = os.fstat(descriptor)
            entry = os.stat(installed_path, follow_symlinks=False)
            identity = lambda item: (
                item.st_dev, item.st_ino, item.st_size,
                item.st_mtime_ns, item.st_ctime_ns,
            )
            if (len(raw) != before.st_size or len(raw) > 4096
                    or identity(before) != identity(after)
                    or identity(after) != identity(entry)):
                raise ValueError()
            installed = _duplicate_safe(raw.decode("ascii", "strict"))
            architecture = installed.get("architecture")
            _installation_receipt(
                installed, commit, "linux/" + architecture)
        except Exception:
            raise ManagedStackCIError("unified_cleanup_not_owned") from None
        finally:
            if descriptor is not None:
                os.close(descriptor)
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": "/tmp",
                   "LARENOR_SOURCE_REVISION": commit}
    owned = [(ROOT, value["rootDevice"], value["rootInode"])] + [
        (Path(item["path"]), item["device"], item["inode"])
        for item in value["externalRoots"]
    ]

    inventory_budget = [MAX_CLEANUP_ENTRIES]

    def inventory_tree(target, device, inode):
        if not (target.exists() or target.is_symlink()):
            return

        def scan(descriptor, root_device, depth=0):
            if depth > 64:
                raise ManagedStackCIError("unified_cleanup_not_owned")
            with os.scandir(descriptor) as entries:
                for entry in entries:
                    inventory_budget[0] -= 1
                    if inventory_budget[0] < 0:
                        raise ManagedStackCIError("unified_cleanup_not_owned")
                    before = os.stat(
                        entry.name, dir_fd=descriptor, follow_symlinks=False)
                    if stat.S_ISDIR(before.st_mode):
                        child = os.open(
                            entry.name,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor,
                        )
                        try:
                            opened = os.fstat(child)
                            if ((opened.st_dev, opened.st_ino)
                                    != (before.st_dev, before.st_ino)
                                    or opened.st_dev != root_device):
                                raise ManagedStackCIError(
                                    "unified_cleanup_not_owned")
                            scan(child, root_device, depth + 1)
                        finally:
                            os.close(child)

        parent = os.open(
            target.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            descriptor = os.open(
                target.name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent,
            )
            try:
                opened = os.fstat(descriptor)
                if ((opened.st_dev, opened.st_ino) != (device, inode)
                        or opened.st_uid != OWNED_UID or opened.st_nlink < 1
                        or stat.S_IMODE(opened.st_mode) != 0o700):
                    raise ManagedStackCIError("unified_cleanup_not_owned")
                scan(descriptor, device)
            finally:
                os.close(descriptor)
        finally:
            os.close(parent)

    for target, device, inode in owned:
        inventory_tree(target, device, inode)

    try:
        if ROOT.exists() or ROOT.is_symlink():
            _command(["/usr/bin/docker", "compose", "--project-name", value["projectName"],
                      "-f", str(COMPOSE), "down",
                      "--remove-orphans", "--timeout", "30"], environment=environment,
                     timeout=180, output=False)
        deletion_budget = [MAX_CLEANUP_ENTRIES]

        def remove_tree(target, device, inode):

            def clear(descriptor, root_device, depth=0):
                if depth > 64:
                    raise ManagedStackCIError("unified_cleanup_not_owned")
                with os.scandir(descriptor) as entries:
                    count = 0
                    for _ in entries:
                        deletion_budget[0] -= 1
                        if deletion_budget[0] < 0:
                            raise ManagedStackCIError("unified_cleanup_not_owned")
                        count += 1
                with os.scandir(descriptor) as entries:
                    for entry in entries:
                        count -= 1
                        if count < 0:
                            raise ManagedStackCIError("unified_cleanup_not_owned")
                        name = entry.name
                        before = os.stat(
                            name, dir_fd=descriptor, follow_symlinks=False)
                        if stat.S_ISDIR(before.st_mode):
                            child = os.open(
                                name,
                                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=descriptor,
                            )
                            try:
                                opened = os.fstat(child)
                                if ((opened.st_dev, opened.st_ino)
                                        != (before.st_dev, before.st_ino)
                                        or opened.st_dev != root_device):
                                    raise ManagedStackCIError(
                                        "unified_cleanup_not_owned")
                                clear(child, root_device, depth + 1)
                            finally:
                                os.close(child)
                            after = os.stat(
                                name, dir_fd=descriptor, follow_symlinks=False)
                            if ((after.st_dev, after.st_ino)
                                    != (before.st_dev, before.st_ino)):
                                raise ManagedStackCIError(
                                    "unified_cleanup_not_owned")
                            os.rmdir(name, dir_fd=descriptor)
                        else:
                            os.unlink(name, dir_fd=descriptor)
                if count != 0:
                    raise ManagedStackCIError("unified_cleanup_not_owned")

            if not (target.exists() or target.is_symlink()):
                return
            parent = os.open(
                target.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                current = os.stat(
                    target.name, dir_fd=parent, follow_symlinks=False)
                if (not stat.S_ISDIR(current.st_mode)
                        or current.st_dev != device or current.st_ino != inode
                        or current.st_uid != OWNED_UID or current.st_nlink < 1
                        or stat.S_IMODE(current.st_mode) != 0o700):
                    raise ManagedStackCIError("unified_cleanup_not_owned")
                descriptor = os.open(
                    target.name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=parent,
                )
                try:
                    opened = os.fstat(descriptor)
                    if ((opened.st_dev, opened.st_ino)
                            != (device, inode)
                            or opened.st_uid != OWNED_UID or opened.st_nlink < 1
                            or stat.S_IMODE(opened.st_mode) != 0o700):
                        raise ManagedStackCIError("unified_cleanup_not_owned")
                    clear(descriptor, device)
                finally:
                    os.close(descriptor)
                current = os.stat(
                    target.name, dir_fd=parent, follow_symlinks=False)
                if ((current.st_dev, current.st_ino) != (device, inode)):
                    raise ManagedStackCIError("unified_cleanup_not_owned")
                os.rmdir(target.name, dir_fd=parent)
                os.fsync(parent)
            finally:
                os.close(parent)

        for target, device, inode in owned:
            remove_tree(target, device, inode)
        path = Path(receipt_path)
        path.unlink()
        parent_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    except ManagedStackCIError:
        raise ManagedStackCIError("unified_cleanup_failed") from None
    except OSError:
        raise ManagedStackCIError("unified_cleanup_failed") from None


def main(arguments=None):
    parser = argparse.ArgumentParser()
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--run-native", action="store_true")
    action.add_argument("--verify-receipt")
    action.add_argument("--cleanup-owned", action="store_true")
    parser.add_argument("--ownership-receipt")
    parser.add_argument("--expected-commit")
    parser.add_argument("--expected-platform")
    parser.add_argument("--expected-upgrade-source")
    parser.add_argument("--expected-reviewed-head")
    parser.add_argument("--expected-recovery", choices=(
        "not_required", "post_effect_reconciled"))
    parser.add_argument("--fault-after-upgrade-journal", action="store_true")
    args = parser.parse_args(arguments)
    try:
        if args.run_native:
            if not args.ownership_receipt:
                raise ManagedStackCIError("unified_launch_invalid")
            selected = validate_launch()
            commit = os.environ.get("GITHUB_SHA", "")
            verify_checkout(commit)
            base, reviewed = validate_upgrade_chain(commit)
            value = run_native(commit, selected, DockerDriver(
                commit, selected, args.ownership_receipt,
                fault_after_upgrade_journal=args.fault_after_upgrade_journal),
                base_commit=base, reviewed_head_commit=reviewed)
            print(_canonical(value))
        elif args.verify_receipt:
            if args.fault_after_upgrade_journal:
                raise ManagedStackCIError("unified_launch_invalid")
            if (not args.expected_commit or not args.expected_platform
                    or not args.expected_upgrade_source
                    or not args.expected_reviewed_head
                    or not args.expected_recovery):
                raise ManagedStackCIError("unified_launch_invalid")
            verify(
                args.verify_receipt, args.expected_commit, args.expected_platform,
                upgrade_source=args.expected_upgrade_source,
                reviewed_head=args.expected_reviewed_head,
                expected_recovery=args.expected_recovery)
        else:
            if args.fault_after_upgrade_journal:
                raise ManagedStackCIError("unified_launch_invalid")
            if not args.ownership_receipt:
                raise ManagedStackCIError("unified_launch_invalid")
            cleanup_owned(args.ownership_receipt, os.environ.get("GITHUB_SHA", ""))
    except ManagedStackCIError as error:
        if args.run_native:
            print(_canonical({"schemaVersion": 1, "result": "failed", "code": error.code}))
        print(error.code, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
