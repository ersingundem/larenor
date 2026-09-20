#!/usr/bin/env python3
"""Native, opt-in acceptance for the exact unified media stack package.

The workflow is manual and runs only on owned self-hosted runners. This tool
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
    "server/larenor_server/plugins/packagedcatalog.json",
    "tool/unified_media_stack_managed_ci.py",
    "tool/tests/unified_media_stack_deployment_test.py",
    "tool/tests/unified_media_stack_runtime_test.py",
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
    if not (
        selected is not None
        and env.get("EXPECTED_PLATFORM") == selected
        and env.get("RUNNER_ARCH") == expected_arch
        and env.get("RUNNER_ENVIRONMENT") == "self-hosted"
        and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
        and env.get("GITHUB_REF") == "refs/heads/main"
        and env.get("GITHUB_REPOSITORY") == "ersingundem/larenor"
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


class DockerDriver:
    def __init__(self, commit, selected_platform, ownership_receipt):
        self.commit = commit
        self.platform = selected_platform
        self.ownership_receipt = Path(ownership_receipt)
        self.operation_id = uuid.uuid4().hex
        self.config_digest = None
        self.ownership_digest = None
        self._owned = False
        self._environment = {
            "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": "/tmp",
            "LARENOR_SOURCE_REVISION": commit,
        }

    def _compose(self, *arguments, timeout=300, output=False, allow_failure=False):
        return _command(["/usr/bin/docker", "compose", "-f", str(COMPOSE), *arguments],
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
        self.config_digest = _digest(parsed)
        return SourceConfig().config(path, revision)

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
                   "sourceCommit": self.commit, "root": str(ROOT)}
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
        self._compose("pull", "--ignore-buildable", "--quiet", timeout=900)
        self._compose("build", "--pull", "larenor-core", timeout=900)
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
        self._compose("create", "--no-build", timeout=300)

    def start(self, manifest):
        self._compose("start", timeout=180)

    def restart(self, manifest):
        self._compose("restart", "--timeout", "30", timeout=240)

    def receipts(self, manifest, phase):
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
            if item["serviceId"] == "music_assistant":
                if network_mode != "host":
                    raise ManagedStackCIError("unified_container_receipt_invalid")
                dns, network = "host_network", "host"
            else:
                aliases = networks.get(NETWORK, {}).get("Aliases", [])
                if network_mode != NETWORK or item["containerName"] not in aliases:
                    raise ManagedStackCIError("unified_container_receipt_invalid")
                self._verify_dns(item["containerName"])
                dns, network = "verified", NETWORK
            values.append({
                "serviceId": item["serviceId"], "containerName": item["containerName"],
                "image": item["image"], "containerId": current.get("Id"),
                "state": "running" if current.get("State", {}).get("Running") is True else "failed",
                "dns": dns, "network": network,
                "mounts": [{"target": entry["target"], "readOnly": entry["readOnly"]}
                           for entry in item["mounts"]],
            })
        return values

    def _verify_dns(self, name):
        code = ("import socket,sys; values=socket.getaddrinfo(sys.argv[1],1); "
                "assert values")
        _command(["/usr/bin/docker", "exec", package.CORE_NAME,
                  "/opt/larenor/.venv/bin/python", "-B", "-c", code, name],
                 environment=self._environment, timeout=15, output=False)

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
            "schemaVersion", "operationId", "sourceCommit", "root"}
            or value.get("schemaVersion") != 1
            or not re.fullmatch(r"[a-f0-9]{32}", value.get("operationId", ""))
            or value.get("sourceCommit") != commit or value.get("root") != str(ROOT)):
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
        _command(["/usr/bin/docker", "compose", "-f", str(COMPOSE), "down",
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
