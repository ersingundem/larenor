"""Trusted Linux execution boundary for resource-governed AI jobs.

The API never supplies an executable, argument, environment value or path.
An administrator-owned catalog selects a fixed provider for each supported job
kind.  systemd creates the cgroup before exec and remains the restart-safe
source of process and terminal status.
"""

from dataclasses import dataclass
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


MAX_CONFIG_BYTES = 64 * 1024
MAX_COMMAND_OUTPUT = 16 * 1024
MAX_CONTROL_SECONDS = 10
MAX_OUTPUT_BYTES = 1024 * 1024
_ID = re.compile(r"[0-9a-f]{32}\Z")
_PROVIDER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
_KINDS = frozenset({"assistant", "vision", "embedding", "automation"})


class AiRuntimeError(RuntimeError):
    def __init__(self, code="worker_unavailable"):
        self.code = code if code in {
            "worker_unavailable", "invalid_runtime_configuration",
            "dispatch_unknown", "invalid_runtime_response",
        } else "worker_unavailable"
        super().__init__(self.code)


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _read_bounded(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ValueError()
        value = os.read(descriptor, maximum + 1)
        if len(value) != info.st_size or len(value) > maximum:
            raise ValueError()
        return value, info
    finally:
        os.close(descriptor)


def _safe_absolute(value):
    if (type(value) is not str or not value or len(value.encode()) > 4096
            or any(ord(char) < 32 or ord(char) == 127 for char in value)
            or re.fullmatch(r"/[A-Za-z0-9._/+@-]+", value) is None):
        raise ValueError()
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts or str(path) != value:
        raise ValueError()
    return path


def _safe_file(path, *, private=False, executable=False):
    info = os.stat(path, follow_symlinks=False)
    if (not stat.S_ISREG(info.st_mode)
            or info.st_uid not in {0, os.geteuid()}
            or info.st_mode & (0o077 if private else 0o022)
            or executable and not info.st_mode & 0o111):
        raise ValueError()
    return path


def _safe_directory(path):
    info = os.stat(path, follow_symlinks=False)
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_mode & 0o077):
        raise ValueError()
    return path


@dataclass(frozen=True)
class AiProvider:
    kind: str
    provider_id: str
    executable: Path
    executable_sha256: str
    arguments: tuple[str, ...]
    artifacts: tuple[tuple[Path, str], ...]


@dataclass(frozen=True, repr=False)
class AiRuntimeConfig:
    manager: str
    systemd_run: Path
    systemctl: Path
    state_root: Path
    max_runtime_seconds: int
    max_tasks: int
    providers: tuple[AiProvider, ...]

    def __repr__(self):
        return "AiRuntimeConfig(<private>)"

    @classmethod
    def load(cls, path):
        try:
            source = _safe_absolute(str(path))
            raw, info = _read_bounded(source, MAX_CONFIG_BYTES)
            if info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise ValueError()
            value = json.loads(
                raw.decode("utf-8"), object_pairs_hook=_pairs,
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
            )
            if (type(value) is not dict or set(value) != {
                    "schemaVersion", "manager", "systemdRun", "systemctl",
                    "stateRoot", "maxRuntimeSeconds", "maxTasks", "providers",
                    } or value["schemaVersion"] != 1
                    or type(value["schemaVersion"]) is not int
                    or value["manager"] not in {"system", "user"}
                    or type(value["maxRuntimeSeconds"]) is not int
                    or not 1 <= value["maxRuntimeSeconds"] <= 86_400
                    or type(value["maxTasks"]) is not int
                    or not 1 <= value["maxTasks"] <= 1024
                    or type(value["providers"]) is not list
                    or not 1 <= len(value["providers"]) <= len(_KINDS)):
                raise ValueError()
            systemd_run = _safe_file(
                _safe_absolute(value["systemdRun"]), executable=True)
            systemctl = _safe_file(
                _safe_absolute(value["systemctl"]), executable=True)
            state_root = _safe_directory(_safe_absolute(value["stateRoot"]))
            providers = []
            for item in value["providers"]:
                if (type(item) is not dict or set(item) != {
                        "kind", "providerId", "executionMode", "executable",
                        "executableSha256", "arguments", "artifacts"}
                        or item["kind"] not in _KINDS
                        or type(item["providerId"]) is not str
                        or _PROVIDER.fullmatch(item["providerId"]) is None
                        or item["executionMode"] != "standalone"
                        or type(item["executableSha256"]) is not str
                        or re.fullmatch(r"[0-9a-f]{64}", item["executableSha256"])
                        is None
                        or type(item["arguments"]) is not list
                        or len(item["arguments"]) > 32
                        or type(item["artifacts"]) is not list
                        or len(item["artifacts"]) > 8
                        or any(type(argument) is not str or not argument
                               or len(argument.encode()) > 1024
                               or any(ord(char) < 32 or ord(char) == 127
                                      for char in argument)
                               for argument in item["arguments"])):
                    raise ValueError()
                artifacts = []
                for artifact in item["artifacts"]:
                    if (type(artifact) is not dict
                            or set(artifact) != {"path", "sha256"}
                            or type(artifact["sha256"]) is not str
                            or re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"])
                            is None):
                        raise ValueError()
                    artifacts.append((
                        _safe_file(_safe_absolute(artifact["path"])),
                        artifact["sha256"],
                    ))
                providers.append(AiProvider(
                    item["kind"], item["providerId"],
                    _safe_file(_safe_absolute(item["executable"]), executable=True),
                    item["executableSha256"],
                    tuple(item["arguments"]),
                    tuple(artifacts),
                ))
            if len({item.kind for item in providers}) != len(providers):
                raise ValueError()
            return cls(
                value["manager"], systemd_run, systemctl, state_root,
                value["maxRuntimeSeconds"], value["maxTasks"],
                tuple(providers),
            )
        except Exception:
            raise AiRuntimeError("invalid_runtime_configuration") from None


@dataclass(frozen=True)
class AiDispatch:
    job_id: str
    dispatch_id: str
    request_key: str
    kind: str
    memory_mb: int
    cpu_percent: int

    def __post_init__(self):
        if (type(self.job_id) is not str or _ID.fullmatch(self.job_id) is None
                or type(self.dispatch_id) is not str
                or _ID.fullmatch(self.dispatch_id) is None
                or type(self.request_key) is not str
                or not 16 <= len(self.request_key) <= 128
                or self.kind not in _KINDS
                or type(self.memory_mb) is not int
                or not 64 <= self.memory_mb <= 1_048_576
                or type(self.cpu_percent) is not int
                or not 1 <= self.cpu_percent <= 100):
            raise AiRuntimeError("invalid_runtime_response")


@dataclass(frozen=True)
class AiRuntimeObservation:
    phase: str
    result_code: str | None = None
    exit_code: int | None = None
    memory_peak_mb: int | None = None
    cpu_millis: int | None = None
    output_sha256: str | None = None
    output_bytes: int | None = None

    def __post_init__(self):
        if (self.phase not in {
                "starting", "running", "cancel_requested", "succeeded",
                "failed", "cancelled", "unknown"}
                or self.result_code is not None
                and self.result_code not in {
                    "succeeded", "provider_failed", "resource_limit",
                    "cancelled", "runtime_lost"}
                or self.exit_code is not None
                and (type(self.exit_code) is not int or not 0 <= self.exit_code <= 255)
                or self.memory_peak_mb is not None
                and (type(self.memory_peak_mb) is not int
                     or self.memory_peak_mb < 0)
                or self.cpu_millis is not None
                and (type(self.cpu_millis) is not int or self.cpu_millis < 0)
                or self.output_sha256 is not None
                and (type(self.output_sha256) is not str
                     or re.fullmatch(r"[0-9a-f]{64}", self.output_sha256) is None)
                or self.output_bytes is not None
                and (type(self.output_bytes) is not int
                     or not 0 <= self.output_bytes <= MAX_OUTPUT_BYTES)
                or (self.output_sha256 is None) != (self.output_bytes is None)):
            raise AiRuntimeError("invalid_runtime_response")


class _SubprocessRunner:
    def __call__(self, arguments, timeout):
        return subprocess.run(
            arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, close_fds=True, timeout=timeout,
            check=False, text=True, encoding="utf-8", errors="strict",
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
        )


class UnavailableAiJobRuntime:
    enforcement = "unavailable"

    def available(self):
        return False

    def supports(self, _kind):
        return False

    def provider(self, _kind):
        return None

    def start(self, _dispatch):
        raise AiRuntimeError()

    def observe(self, _dispatch):
        return AiRuntimeObservation("unknown", "runtime_lost")

    def cancel(self, _dispatch):
        raise AiRuntimeError()

    def release(self, _dispatch):
        return None


class SystemdAiJobRuntime:
    enforcement = "systemdCgroupV2"

    def __init__(self, config, *, runner=None, platform=None):
        if type(config) is not AiRuntimeConfig:
            raise AiRuntimeError("invalid_runtime_configuration")
        self.config = config
        self._runner = runner or _SubprocessRunner()
        self._platform = sys.platform if platform is None else platform
        self._providers = {provider.kind: provider for provider in config.providers}
        self._identity_cache = {}

    def _manager(self):
        return ["--user"] if self.config.manager == "user" else []

    def _run(self, arguments):
        try:
            result = self._runner(tuple(arguments), MAX_CONTROL_SECONDS)
            output = result.stdout
            if (type(result.returncode) is not int or type(output) is not str
                    or len(output.encode("utf-8")) > MAX_COMMAND_OUTPUT):
                raise ValueError()
            return result.returncode, output
        except (OSError, ValueError, TypeError, UnicodeError,
                subprocess.SubprocessError):
            raise AiRuntimeError() from None

    def available(self):
        if self._platform != "linux":
            return False
        try:
            _safe_file(self.config.systemd_run, executable=True)
            _safe_file(self.config.systemctl, executable=True)
            code, _output = self._run([
                str(self.config.systemctl), *self._manager(),
                "show", "--property=Version",
            ])
            if code != 0:
                return False
            for provider in self.config.providers:
                self._verify_provider(provider)
            return True
        except AiRuntimeError:
            return False

    def supports(self, kind):
        return kind in self._providers

    def provider(self, kind):
        value = self._providers.get(kind)
        return None if value is None else value.provider_id

    @staticmethod
    def _unit(dispatch):
        return f"larenor-ai-{dispatch.dispatch_id}.service"

    def _descriptor(self, dispatch, provider):
        path = self.config.state_root / f"{dispatch.dispatch_id}.json"
        output = self.config.state_root / f"{dispatch.dispatch_id}.output"
        receipt = self.config.state_root / f"{dispatch.dispatch_id}.receipt"
        value = {
            "schemaVersion": 1,
            "jobId": dispatch.job_id,
            "dispatchId": dispatch.dispatch_id,
            "requestKey": dispatch.request_key,
            "kind": dispatch.kind,
            "providerId": provider.provider_id,
            "outputPath": str(output),
            "receiptPath": str(receipt),
        }
        raw = json.dumps(
            value, sort_keys=True, separators=(",", ":"),
            ensure_ascii=True, allow_nan=False,
        ).encode("ascii")
        try:
            descriptor = os.open(
                path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
            )
            try:
                written = 0
                while written < len(raw):
                    count = os.write(descriptor, raw[written:])
                    if count <= 0:
                        raise OSError()
                    written += count
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            directory = os.open(self.config.state_root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except FileExistsError:
            observed, info = _read_bounded(path, 4096)
            if info.st_uid != os.geteuid() or info.st_mode & 0o077 or observed != raw:
                raise AiRuntimeError("invalid_runtime_response") from None
        except (OSError, ValueError):
            raise AiRuntimeError() from None
        return path

    def _verify_file(self, path, expected, *, executable=False):
        try:
            info = os.stat(path, follow_symlinks=False)
            if (not stat.S_ISREG(info.st_mode)
                    or info.st_uid not in {0, os.geteuid()}
                    or info.st_mode & 0o022
                    or executable and not info.st_mode & 0o111):
                raise ValueError()
            identity = (
                info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                info.st_ctime_ns, info.st_uid, stat.S_IMODE(info.st_mode),
            )
            cached = self._identity_cache.get(path)
            if cached is not None and cached[0] == identity:
                observed = cached[1]
            else:
                digest = hashlib.sha256()
                descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    opened = os.fstat(descriptor)
                    if ((opened.st_dev, opened.st_ino) !=
                            (info.st_dev, info.st_ino)):
                        raise ValueError()
                    while True:
                        block = os.read(descriptor, 1024 * 1024)
                        if not block:
                            break
                        digest.update(block)
                finally:
                    os.close(descriptor)
                observed = digest.hexdigest()
                self._identity_cache[path] = (identity, observed)
            if not hmac.compare_digest(observed, expected):
                raise ValueError()
        except (OSError, ValueError):
            raise AiRuntimeError("invalid_runtime_configuration") from None

    def _verify_provider(self, provider):
        self._verify_file(
            provider.executable, provider.executable_sha256, executable=True,
        )
        for path, expected in provider.artifacts:
            self._verify_file(path, expected)

    def start(self, dispatch):
        if type(dispatch) is not AiDispatch:
            raise AiRuntimeError("invalid_runtime_response")
        provider = self._providers.get(dispatch.kind)
        if provider is None or not self.available():
            raise AiRuntimeError()
        self._verify_provider(provider)
        descriptor = self._descriptor(dispatch, provider)
        unit = self._unit(dispatch)
        arguments = [
            str(self.config.systemd_run), *self._manager(), "--quiet",
            f"--unit={unit}", "--property=Type=exec",
            "--property=RemainAfterExit=yes",
            f"--property=CPUQuota={dispatch.cpu_percent}%",
            f"--property=MemoryMax={dispatch.memory_mb * 1_048_576}",
            "--property=MemorySwapMax=0",
            f"--property=TasksMax={self.config.max_tasks}",
            f"--property=RuntimeMaxSec={self.config.max_runtime_seconds}",
            "--property=KillMode=control-group",
            "--property=NoNewPrivileges=yes", "--property=UMask=0077",
            "--property=ProtectSystem=strict", "--property=ProtectHome=yes",
            "--property=PrivateTmp=yes", "--property=RestrictSUIDSGID=yes",
            "--property=PrivateNetwork=yes",
            "--property=RestrictAddressFamilies=AF_UNIX",
            "--property=ProtectControlGroups=yes",
            "--property=ProtectKernelModules=yes",
            "--property=ProtectKernelTunables=yes",
            f"--property=BindPaths={self.config.state_root}",
            f"--property=BindReadOnlyPaths={provider.executable}",
            *(
                f"--property=BindReadOnlyPaths={path}"
                for path, _expected in provider.artifacts
            ),
            "--",
            str(provider.executable), *provider.arguments,
            "--larenor-job-descriptor", str(descriptor),
        ]
        code, _output = self._run(arguments)
        if code != 0:
            observed = self.observe(dispatch)
            if observed.phase == "unknown":
                raise AiRuntimeError("dispatch_unknown")
            return observed
        return self.observe(dispatch)

    @staticmethod
    def _properties(output):
        result = {}
        for line in output.splitlines():
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key in result:
                raise AiRuntimeError("invalid_runtime_response")
            result[key] = value
        expected = {
            "LoadState", "ActiveState", "SubState", "Result",
            "ExecMainStatus", "MemoryPeak", "CPUUsageNSec",
        }
        if set(result) != expected:
            raise AiRuntimeError("invalid_runtime_response")
        return result

    @staticmethod
    def _metric(value, divisor):
        if value in {"", "[not set]", "infinity"}:
            return None
        if not value.isascii() or not value.isdigit():
            raise AiRuntimeError("invalid_runtime_response")
        number = int(value)
        return math.ceil(number / divisor)

    def _terminal_output(self, dispatch):
        path = self.config.state_root / f"{dispatch.dispatch_id}.receipt"
        output_path = self.config.state_root / f"{dispatch.dispatch_id}.output"
        try:
            raw, info = _read_bounded(path, 4096)
            if info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise ValueError()
            value = json.loads(
                raw.decode("ascii"), object_pairs_hook=_pairs,
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
            )
            provider = self._providers[dispatch.kind]
            if (type(value) is not dict or set(value) != {
                    "schemaVersion", "jobId", "dispatchId", "providerId",
                    "status", "outputSha256", "outputBytes"}
                    or value["schemaVersion"] != 1
                    or type(value["schemaVersion"]) is not int
                    or value["jobId"] != dispatch.job_id
                    or value["dispatchId"] != dispatch.dispatch_id
                    or value["providerId"] != provider.provider_id
                    or value["status"] != "succeeded"
                    or type(value["outputSha256"]) is not str
                    or re.fullmatch(r"[0-9a-f]{64}", value["outputSha256"])
                    is None or type(value["outputBytes"]) is not int
                    or not 0 <= value["outputBytes"] <= MAX_OUTPUT_BYTES):
                raise ValueError()
            output, output_info = _read_bounded(output_path, MAX_OUTPUT_BYTES)
            if (output_info.st_uid != os.geteuid() or output_info.st_mode & 0o077
                    or len(output) != value["outputBytes"]
                    or not hmac.compare_digest(
                        hashlib.sha256(output).hexdigest(),
                        value["outputSha256"],
                    )):
                raise ValueError()
            return value["outputSha256"], value["outputBytes"]
        except Exception:
            raise AiRuntimeError("invalid_runtime_response") from None

    def observe(self, dispatch):
        if type(dispatch) is not AiDispatch:
            raise AiRuntimeError("invalid_runtime_response")
        code, output = self._run([
            str(self.config.systemctl), *self._manager(), "show",
            self._unit(dispatch),
            "--property=LoadState,ActiveState,SubState,Result,ExecMainStatus,MemoryPeak,CPUUsageNSec",
        ])
        if code != 0:
            return AiRuntimeObservation("unknown", "runtime_lost")
        values = self._properties(output)
        if values["LoadState"] == "not-found":
            return AiRuntimeObservation("unknown", "runtime_lost")
        memory = self._metric(values["MemoryPeak"], 1_048_576)
        cpu = self._metric(values["CPUUsageNSec"], 1_000_000)
        active = values["ActiveState"]
        if active in {"activating", "reloading"}:
            return AiRuntimeObservation("starting", memory_peak_mb=memory,
                                        cpu_millis=cpu)
        if active == "active" and values["SubState"] != "exited":
            return AiRuntimeObservation("running", memory_peak_mb=memory,
                                        cpu_millis=cpu)
        if active == "deactivating":
            return AiRuntimeObservation("cancel_requested", memory_peak_mb=memory,
                                        cpu_millis=cpu)
        status = values["ExecMainStatus"]
        if not status.isascii() or not status.isdigit() or not 0 <= int(status) <= 255:
            raise AiRuntimeError("invalid_runtime_response")
        exit_code = int(status)
        result = values["Result"]
        if (active == "inactive" or active == "active"
                and values["SubState"] == "exited") and result == "success" and exit_code == 0:
            try:
                output_sha256, output_bytes = self._terminal_output(dispatch)
            except AiRuntimeError:
                return AiRuntimeObservation(
                    "failed", "provider_failed", exit_code, memory, cpu)
            return AiRuntimeObservation(
                "succeeded", "succeeded", exit_code, memory, cpu,
                output_sha256, output_bytes)
        if result in {"oom-kill", "timeout", "watchdog", "resources"}:
            code_name = "resource_limit"
        elif result in {"signal", "core-dump"} and exit_code in {9, 15}:
            code_name = "cancelled"
        else:
            code_name = "provider_failed"
        phase = "cancelled" if code_name == "cancelled" else "failed"
        return AiRuntimeObservation(
            phase, code_name, exit_code, memory, cpu)

    def cancel(self, dispatch):
        if type(dispatch) is not AiDispatch:
            raise AiRuntimeError("invalid_runtime_response")
        code, _output = self._run([
            str(self.config.systemctl), *self._manager(), "stop",
            self._unit(dispatch),
        ])
        observed = self.observe(dispatch)
        if code != 0 and observed.phase == "unknown":
            raise AiRuntimeError("dispatch_unknown")
        return observed

    def release(self, dispatch):
        if type(dispatch) is not AiDispatch:
            raise AiRuntimeError("invalid_runtime_response")
        code, _output = self._run([
            str(self.config.systemctl), *self._manager(), "stop",
            self._unit(dispatch),
        ])
        if code != 0 and self.observe(dispatch).phase != "unknown":
            raise AiRuntimeError()
        try:
            for suffix in (".json", ".output", ".receipt"):
                path = self.config.state_root / f"{dispatch.dispatch_id}{suffix}"
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
            directory = os.open(
                self.config.state_root, os.O_RDONLY | os.O_DIRECTORY,
            )
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except OSError:
            raise AiRuntimeError() from None


def build_ai_job_runtime(config_path):
    if config_path is None:
        return UnavailableAiJobRuntime()
    try:
        return SystemdAiJobRuntime(AiRuntimeConfig.load(config_path))
    except AiRuntimeError:
        return UnavailableAiJobRuntime()
