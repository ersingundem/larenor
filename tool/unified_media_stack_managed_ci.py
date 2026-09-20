#!/usr/bin/env python3
"""Native, opt-in acceptance for the exact unified media stack package.

The workflow runs on GitHub-hosted Linux amd64 and arm64 runners. This tool
never publishes credentials, environment, URLs, host paths, logs or raw Docker
identifiers. A fresh fixed root and project are required; cleanup is allowed
only when a private ownership receipt and root marker agree.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid


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
MARKER = ".native-ci-owner"
MAX_OUTPUT = 512 * 1024
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
)
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
    "unified_dns_core_alias_failed",
    "unified_dns_peer_alias_failed",
}


class ManagedStackCIError(Exception):
    """A bounded diagnostic whose text is always an allowlisted code."""

    def __init__(self, code):
        safe = code if code in _CODES else "unified_native_runtime_failed"
        self.code = safe
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
    acceptance_source_hashes()


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
                "dns", "network", "mounts"}:
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
                or value.get("mounts") != wanted_mounts):
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
    }


def run_native(commit, selected_platform, driver):
    if (not isinstance(commit, str) or not re.fullmatch(r"[a-f0-9]{40}", commit)
            or selected_platform not in {"linux/amd64", "linux/arm64"}):
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
        try:
            preflight = planner.preflight(manifest, driver)
        except Exception:
            raise ManagedStackCIError("unified_preflight_failed") from None
        if preflight.get("ready") is not True:
            raise ManagedStackCIError("unified_preflight_failed")
        pulls = _pull_receipts(driver.pull(manifest), manifest)
        driver.create(manifest)
        driver.start(manifest)
        initial = _container_receipts(driver.receipts(manifest, "initial"), manifest)
        driver.restart(manifest)
        restarted = _container_receipts(driver.receipts(manifest, "restart"), manifest)
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
            "serviceState": "not_verified",
            "automaticRetry": False,
            "cleanupState": "completed",
            "services": services,
        }
    except ManagedStackCIError as error:
        primary = error
    except Exception:
        primary = ManagedStackCIError("unified_native_runtime_failed")
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


def validate_receipt(value, commit, selected_platform):
    manifest = expected_manifest(commit)
    if (not isinstance(value, dict) or set(value) != {
            "schemaVersion", "result", "platform", "sourceCommit",
            "acceptanceSourceHashes", "manifestDigest", "composeConfigDigest",
            "ownershipReceiptDigest", "lifecycle", "containerState", "serviceState",
            "automaticRetry", "cleanupState", "services"}
            or value.get("schemaVersion") != 1
            or value.get("result") != "unified_media_stack_characterized"
            or value.get("platform") != selected_platform
            or value.get("sourceCommit") != commit
            or value.get("acceptanceSourceHashes") != acceptance_source_hashes()
            or value.get("manifestDigest") != manifest["manifestDigest"]
            or not re.fullmatch(r"[a-f0-9]{64}", value.get("composeConfigDigest", ""))
            or not re.fullmatch(r"[a-f0-9]{64}", value.get("ownershipReceiptDigest", ""))
            or value.get("lifecycle") != ["config", "pull", "create", "start", "restart"]
            or value.get("containerState") != "verified"
            or value.get("serviceState") != "not_verified"
            or value.get("automaticRetry") is not False
            or value.get("cleanupState") != "completed"
            or not isinstance(value.get("services"), dict)
            or tuple(value["services"]) != COMPONENTS):
        raise ManagedStackCIError("unified_characterization_evidence_invalid")
    expected = {item["serviceId"]: item for item in manifest["components"]}
    for service_id in COMPONENTS:
        service = value["services"].get(service_id)
        if not isinstance(service, dict) or set(service) != {
                "imageReceipt", "initialContainerReceipt", "restartContainerReceipt",
                "authenticatedReadiness"}:
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
                    "network", "mounts"}
                    or container.get("containerName") != expected[service_id]["containerName"]
                    or not re.fullmatch(r"[a-f0-9]{64}", container.get("containerIdentityDigest", ""))
                    or container.get("state") != "running"
                    or container.get("dns") != (
                        "host_network" if service_id == "music_assistant" else "verified")
                    or container.get("network") != (
                        "host" if service_id == "music_assistant" else NETWORK)
                    or container.get("mounts") != wanted_mounts):
                raise ManagedStackCIError("unified_characterization_evidence_invalid")
        if (service["initialContainerReceipt"]["containerIdentityDigest"]
                != service["restartContainerReceipt"]["containerIdentityDigest"]
                or service["authenticatedReadiness"] != {
                    "serviceId": service_id, "state": "not_verified",
                    "code": "bootstrap_authority_not_available"}):
            raise ManagedStackCIError("unified_characterization_evidence_invalid")
    encoded = _canonical(value).lower()
    if len(encoded) > MAX_OUTPUT or any(term in encoded for term in (
            "token", "password", "credential", "authorization", "/var/lib")):
        raise ManagedStackCIError("unified_characterization_evidence_invalid")


def verify(path, commit, selected_platform):
    try:
        raw = Path(path).read_text()
        if len(raw.encode("utf-8")) > MAX_OUTPUT:
            raise ValueError()
        value = _duplicate_safe(raw)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        raise ManagedStackCIError("unified_characterization_evidence_invalid") from None
    validate_receipt(value, commit, selected_platform)


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


def validate_rendered_config(rendered, expected, project_name):
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
                    "dns"):
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
            or Path(core_build.get("context", "")).resolve() != REPOSITORY.resolve()
            or Path(core_build.get("dockerfile", "")).resolve()
            != (REPOSITORY / "server/Dockerfile").resolve()):
        raise ManagedStackCIError("unified_manifest_invalid")


class DockerDriver:
    def __init__(self, commit, selected_platform, ownership_receipt, *, operation_id=None):
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
        self._environment = {
            "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": "/tmp",
            "LARENOR_SOURCE_REVISION": commit,
        }

    def _compose(self, *arguments, timeout=300, output=False, allow_failure=False):
        return _command(["/usr/bin/docker", "compose", "--project-name", self.project_name,
                         "-f", str(COMPOSE), *arguments],
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

    def _docker_list(self, arguments):
        _, value = _command(["/usr/bin/docker", *arguments], environment=self._environment,
                            timeout=30, output=True)
        return value.decode("ascii", "strict").strip()

    def prepare_owned(self, manifest):
        if os.geteuid() != 0 or ROOT.exists() or ROOT.is_symlink():
            raise ManagedStackCIError("unified_foreign_resource")
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
        receipt = {"schemaVersion": 1, "operationId": self.operation_id,
                   "sourceCommit": self.commit, "root": str(ROOT),
                   "projectName": self.project_name}
        encoded = (_canonical(receipt) + "\n").encode("ascii")
        if not self.ownership_receipt.is_absolute() or self.ownership_receipt.is_symlink():
            raise ManagedStackCIError("unified_foreign_resource")
        fd = os.open(self.ownership_receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        self.ownership_digest = hashlib.sha256(encoded).hexdigest()
        ROOT.mkdir(mode=0o700)
        marker = ROOT / MARKER
        marker.write_text(self.operation_id + "\n")
        os.chmod(marker, 0o600)
        for requirement in manifest["directoryRequirements"]:
            path = Path(requirement["path"])
            if ROOT not in path.parents:
                raise ManagedStackCIError("unified_foreign_resource")
            path.mkdir(parents=True, exist_ok=True)
            os.chown(path, requirement["ownerUid"], requirement["ownerUid"])
            os.chmod(path, 0o700)
        self._owned = True

    def inspect(self, path):
        try:
            info = os.lstat(path)
            volume = os.statvfs(path)
        except OSError:
            raise ManagedStackCIError("unified_preflight_failed") from None
        return {"kind": "directory" if stat.S_ISDIR(info.st_mode) else "other",
                "ownerUid": info.st_uid, "mode": stat.S_IMODE(info.st_mode),
                "device": info.st_dev,
                "availableMiB": volume.f_bavail * volume.f_frsize // 1048576}

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
            self._compose("start", timeout=180)
        except ManagedStackCIError:
            raise ManagedStackCIError("unified_start_runtime_failed") from None

    def restart(self, manifest):
        try:
            self._compose("restart", "--timeout", "30", timeout=240)
        except ManagedStackCIError:
            raise ManagedStackCIError("unified_restart_runtime_failed") from None

    def receipts(self, manifest, phase):
        self._await_core_runtime()
        values = []
        for item in manifest["components"]:
            _, raw = _command(["/usr/bin/docker", "container", "inspect",
                               item["containerName"]], environment=self._environment,
                              timeout=30, output=True)
            try:
                current = _duplicate_safe(raw.decode("utf-8"))[0]
                mounts = current["Mounts"]
                network_mode = current["HostConfig"]["NetworkMode"]
                networks = current["NetworkSettings"]["Networks"]
            except (UnicodeError, ValueError, json.JSONDecodeError, KeyError, IndexError, TypeError):
                raise ManagedStackCIError("unified_container_receipt_invalid") from None
            expected_mounts = {(entry["source"], entry["target"], not entry["readOnly"])
                               for entry in item["mounts"]}
            actual_mounts = {(entry.get("Source"), entry.get("Destination"), entry.get("RW"))
                             for entry in mounts if entry.get("Type") == "bind"}
            if actual_mounts != expected_mounts or current.get("Config", {}).get("Image") != item["image"]:
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
                self._verify_dns(item["serviceId"])
                dns, network = "verified", NETWORK
            values.append({
                "serviceId": item["serviceId"], "containerName": item["containerName"],
                "image": item["image"], "containerId": current.get("Id"),
                "state": "running",
                "dns": dns, "network": network,
                "mounts": [{"target": entry["target"], "readOnly": entry["readOnly"]}
                           for entry in item["mounts"]],
            })
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

    def _verify_dns(self, name, *, timeout=30, interval=2):
        if not self._embedded_dns_configured():
            raise ManagedStackCIError("unified_dns_resolver_unavailable")
        self._await_dns("core", "unified_dns_core_alias_failed",
                        timeout=timeout, interval=interval)
        self._await_dns(name, "unified_dns_peer_alias_failed",
                        timeout=timeout, interval=interval)

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

    def authenticated_readiness(self, service_id):
        if service_id not in COMPONENTS:
            raise ManagedStackCIError("unified_readiness_invalid")
        # Native package acceptance must not manufacture or print credentials.
        # S06.5 owns bootstrap. Until its retained authority is supplied, the
        # only truthful state is explicit non-verification.
        return {"serviceId": service_id, "state": "not_verified",
                "code": "bootstrap_authority_not_available"}

    def cleanup(self):
        cleanup_owned(self.ownership_receipt, self.commit)
        self._owned = False


def _read_ownership(path, commit):
    path = Path(path)
    try:
        raw = path.read_text()
        value = _duplicate_safe(raw)
    except FileNotFoundError:
        if ROOT.exists() or ROOT.is_symlink():
            raise ManagedStackCIError("unified_cleanup_not_owned") from None
        return None
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        raise ManagedStackCIError("unified_cleanup_not_owned") from None
    if (not isinstance(value, dict) or set(value) != {
            "schemaVersion", "operationId", "sourceCommit", "root", "projectName"}
            or value.get("schemaVersion") != 1
            or not re.fullmatch(r"[a-f0-9]{32}", value.get("operationId", ""))
            or value.get("sourceCommit") != commit or value.get("root") != str(ROOT)
            or value.get("projectName") != "larenor-native-" + value.get("operationId", "")):
        raise ManagedStackCIError("unified_cleanup_not_owned")
    return value


def cleanup_owned(receipt_path, commit):
    value = _read_ownership(receipt_path, commit)
    if value is None:
        return
    if not ROOT.exists() and not ROOT.is_symlink():
        return
    marker = ROOT / MARKER
    try:
        if (ROOT.is_symlink() or not ROOT.is_dir() or marker.is_symlink()
                or marker.read_text() != value["operationId"] + "\n"):
            raise ManagedStackCIError("unified_cleanup_not_owned")
    except OSError:
        raise ManagedStackCIError("unified_cleanup_not_owned") from None
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": "/tmp",
                   "LARENOR_SOURCE_REVISION": commit}
    try:
        _command(["/usr/bin/docker", "compose", "--project-name", value["projectName"],
                  "-f", str(COMPOSE), "down",
                  "--remove-orphans", "--timeout", "30"], environment=environment,
                 timeout=180, output=False)
        shutil.rmtree(ROOT)
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
    args = parser.parse_args(arguments)
    try:
        if args.run_native:
            if not args.ownership_receipt:
                raise ManagedStackCIError("unified_launch_invalid")
            selected = validate_launch()
            commit = os.environ.get("GITHUB_SHA", "")
            verify_checkout(commit)
            value = run_native(commit, selected, DockerDriver(
                commit, selected, args.ownership_receipt))
            print(_canonical(value))
        elif args.verify_receipt:
            if not args.expected_commit or not args.expected_platform:
                raise ManagedStackCIError("unified_launch_invalid")
            verify(args.verify_receipt, args.expected_commit, args.expected_platform)
        else:
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
