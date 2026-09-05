#!/usr/bin/env python3
"""Manual Larenor Server checks and an explicitly requested, private backup.

Standard library only. Never installs Docker, starts a new deployment, restores
data, contacts Home Assistant, or accepts account credentials. Output is a
small set of status codes; Docker output, HTTP bodies and exceptions stay private.
"""

import argparse
import datetime
import fcntl
import http.client
import io
import json
import os
from pathlib import Path
import platform
import re
import socket
import stat
import subprocess
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


HERE = Path(__file__).resolve().parent
NAME = "larenor-server"
VERSION = "2.10.2"
IMAGE = ("ghcr.io/music-assistant/server:2.10.2@sha256:"
         "09c02b4ee491976efa6d698265f72571f064031bb1a2c9a1c32e104392209690")
DATA = Path("/var/lib/larenor-server/data")
BACKUPS = Path("/var/backups/larenor-server")
MAX_RESPONSE = 64 * 1024
# Deliberately excludes Env, credentials, labels, network addresses and logs.
INSPECT = ('{"id":{{json .Id}},"name":{{json .Name}},'
           '"running":{{json .State.Running}},"paused":{{json .State.Paused}},'
           '"restarting":{{json .State.Restarting}},'
           '"exitCode":{{json .State.ExitCode}},"oom":{{json .State.OOMKilled}},'
           '"image":{{json .Config.Image}},"user":{{json .Config.User}},'
           '"network":{{json .HostConfig.NetworkMode}},'
           '"privileged":{{json .HostConfig.Privileged}},'
           '"caps":{{json .HostConfig.CapAdd}},'
           '"capDrop":{{json .HostConfig.CapDrop}},'
           '"security":{{json .HostConfig.SecurityOpt}},'
           '"devices":{{json .HostConfig.Devices}},'
           '"logs":{{json .HostConfig.LogConfig}},'
           '"mounts":{{json .Mounts}}}')


class DeploymentError(Exception):
    """Only static, safe error codes may cross the CLI boundary."""


def run_docker(args, timeout=15):
    try:
        result = subprocess.run(["docker", *args], capture_output=True,
                                text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        raise DeploymentError("docker_timeout") from None
    except OSError:
        raise DeploymentError("docker_unavailable") from None
    if result.returncode:
        raise DeploymentError("docker_command_failed")
    if len(result.stdout) > MAX_RESPONSE:
        raise DeploymentError("docker_response_too_large")
    return result.stdout


def checked_path(value):
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts or path == Path("/"):
        raise DeploymentError("invalid_directory")
    # Check all existing ancestors, not just the final component.
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise DeploymentError("symlink_directory")
    return path


def private_directory(path):
    path = checked_path(path)
    try:
        info = path.stat()
    except OSError:
        raise DeploymentError("directory_missing") from None
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise DeploymentError("directory_owner_invalid")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise DeploymentError("directory_not_private")
    for parent in path.parents:
        ancestor = parent.stat()
        sticky_root = ancestor.st_uid == 0 and ancestor.st_mode & stat.S_ISVTX
        if (ancestor.st_uid not in (0, os.geteuid()) or
                (ancestor.st_mode & 0o022 and not sticky_root)):
            raise DeploymentError("directory_parent_not_trusted")
    return path


def inspect_runtime(data_dir=DATA, runner=run_docker):
    """Verify the selected running OR stopped deployment, without listing secrets."""
    expected_data = checked_path(data_dir)
    try:
        value = json.loads(runner(["inspect", "--type", "container", "--format", INSPECT, NAME]))
        required = {"id", "name", "running", "paused", "restarting", "exitCode", "oom",
                    "image", "user", "network", "privileged", "caps", "capDrop", "security",
                    "devices", "logs", "mounts"}
        if not isinstance(value, dict) or not required.issubset(value):
            raise ValueError()
        if any(not isinstance(value[key], str) for key in ("name", "image", "user", "network")):
            raise ValueError()
        for key in ("caps", "capDrop", "security"):
            sequence = value[key]
            if sequence is not None and (not isinstance(sequence, list) or len(sequence) > 64 or
                                         any(not isinstance(item, str) or len(item) > 128 for item in sequence)):
                raise ValueError()
        identifier = value.get("id", "")
        if not isinstance(identifier, str) or not re.fullmatch(r"[a-f0-9]{64}", identifier):
            raise ValueError()
        for key in ("running", "paused", "restarting", "oom", "privileged"):
            if type(value.get(key)) is not bool:
                raise ValueError()
        if type(value.get("exitCode")) is not int:
            raise ValueError()
        mounts = value["mounts"]
        if not isinstance(mounts, list) or not 1 <= len(mounts) <= 2:
            raise ValueError()
        targets = set()
        for mount in mounts:
            if not isinstance(mount, dict) or mount.get("Type") != "bind":
                raise ValueError()
            target = mount.get("Destination")
            if target in targets or target not in ("/data", "/media"):
                raise ValueError()
            targets.add(target)
            if target == "/data":
                if mount.get("Source") != str(expected_data) or mount.get("RW") is not True:
                    raise ValueError()
            elif mount.get("RW") is not False:
                raise ValueError()
            elif not checked_path(mount.get("Source", "")).is_dir():
                raise ValueError()
        if "/data" not in targets:
            raise ValueError()
    except (ValueError, TypeError, KeyError):
        raise DeploymentError("runtime_identity_or_mount_invalid") from None
    if (value["name"] != "/" + NAME or value["image"] != IMAGE or
            value["network"] != "host" or value["user"] != "0:0" or
            value["privileged"] or value["devices"] or
            {cap.removeprefix("CAP_") for cap in value["caps"] or []} != {"NET_BIND_SERVICE"} or
            set(value["capDrop"] or []) != {"ALL"} or
            set(value["security"] or []) not in (
                {"no-new-privileges:true"}, {"no-new-privileges"}) or
            value["logs"] != {"Type": "json-file", "Config": {
                "max-size": "10m", "max-file": "3"}}):
        raise DeploymentError("runtime_policy_mismatch")
    if value["paused"] or value["restarting"] or value["oom"]:
        raise DeploymentError("runtime_not_stable")
    return value


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def probe_url(raw):
    if not raw or len(raw) > 2048 or any(c.isspace() or ord(c) < 32 for c in raw):
        raise DeploymentError("invalid_url")
    try:
        uri = urllib.parse.urlsplit(raw)
        if (uri.scheme not in ("http", "https") or not uri.hostname or
                any(c in uri.netloc for c in "@\\%") or uri.query or uri.fragment or
                uri.path not in ("", "/") or uri.port == 0):
            raise ValueError()
        return urllib.parse.urlunsplit((uri.scheme, uri.netloc, "/info", "", ""))
    except ValueError:
        raise DeploymentError("invalid_url") from None


def probe(raw, opener=None):
    """One unauthenticated GET. Reachability is not authentication or playback."""
    url = probe_url(raw)
    if opener is None:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())
    request = urllib.request.Request(url, headers={"Accept": "application/json",
                                                  "User-Agent": "Larenor-Server-Preflight/1"})
    try:
        with opener.open(request, timeout=5) as response:
            if response.status != 200:
                return {"status": "unexpected_http_status"}
            if response.headers.get_content_type() != "application/json":
                return {"status": "invalid_response"}
            deadline = time.monotonic() + 5
            body = bytearray()
            while len(body) <= MAX_RESPONSE:
                if time.monotonic() >= deadline:
                    return {"status": "timeout"}
                chunk = response.read1(min(8192, MAX_RESPONSE + 1 - len(body)))
                if not chunk:
                    break
                body.extend(chunk)
            if len(body) > MAX_RESPONSE:
                return {"status": "response_too_large"}
            try:
                info = json.loads(body)
                if (not isinstance(info, dict) or
                        not isinstance(info.get("server_id"), str) or
                        not 1 <= len(info["server_id"]) <= 128 or
                        type(info.get("schema_version")) is not int or
                        not 0 <= info["schema_version"] <= 10000 or
                        not isinstance(info.get("server_version"), str) or
                        not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[a-zA-Z0-9.+-]{0,32})?",
                                         info["server_version"])):
                    raise ValueError()
            except (ValueError, UnicodeError):
                return {"status": "invalid_response"}
            return {"status": "server_reachable", "version_matches_pin": info["server_version"] == VERSION,
                    "authentication_verified": False, "playback_verified": False}
    except urllib.error.HTTPError as error:
        error.close()
        if error.code == 401:
            return {"status": "authentication_required"}
        if error.code == 403:
            return {"status": "permission_denied"}
        if 300 <= error.code < 400:
            return {"status": "redirect_rejected"}
        return {"status": "server_error" if error.code >= 500 else "http_error"}
    except (TimeoutError, socket.timeout):
        return {"status": "timeout"}
    except urllib.error.URLError as error:
        return {"status": "timeout" if isinstance(error.reason, TimeoutError) else "network_error"}
    except (OSError, http.client.HTTPException):
        return {"status": "network_error"}


def preflight(data_dir=DATA, runner=run_docker):
    results = {"system": "supported" if platform.system() == "Linux" and
               platform.machine() in ("x86_64", "amd64", "aarch64", "arm64") else "unsupported"}
    for key, check in (
        ("private_data_directory", lambda: private_directory(data_dir)),
        ("compose_config", lambda: runner(["compose", "-f", str(HERE / "compose.yaml"),
                                            "config", "--quiet"])),
    ):
        try:
            check()
            results[key] = "ok"
        except DeploymentError as error:
            results[key] = str(error)
    # Advisory: a listener may start later; discovery/UDP reachability is not tested.
    for port in (8095, 8097):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as connection:
            connection.settimeout(0.2)
            results[f"tcp_{port}"] = "in_use" if connection.connect_ex(("127.0.0.1", port)) == 0 else "no_loopback_listener_seen"
    return results


def archive_data(data_dir, stream):
    def safe_member(member):
        # Do not follow or silently omit links, devices, FIFOs or sockets.
        if not (member.isfile() or member.isdir()):
            raise DeploymentError("backup_non_regular_member")
        member.uid = member.gid = 0
        member.uname = member.gname = "root"
        return member

    metadata = json.dumps({"format": 1, "image": IMAGE, "engine": "Music Assistant"}).encode()
    with tarfile.open(fileobj=stream, mode="w:gz", dereference=False) as archive:
        entry = tarfile.TarInfo("larenor-server-backup.json")
        entry.size, entry.mode = len(metadata), 0o600
        archive.addfile(entry, io.BytesIO(metadata))
        archive.add(data_dir, arcname="data", filter=safe_member)


def backup(data_dir=DATA, destination=BACKUPS, *, execute=False,
           runner=run_docker, archiver=archive_data):
    if not execute:
        return {"status": "backup_plan_only", "mutations": False}
    data_dir = private_directory(data_dir)
    destination = private_directory(destination)
    if (data_dir == destination or data_dir in destination.parents or
            destination in data_dir.parents):
        raise DeploymentError("backup_directories_overlap")
    lock_fd = os.open(destination / ".backup.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "a") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise DeploymentError("backup_lock_invalid")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise DeploymentError("backup_already_running") from None
        initial = inspect_runtime(data_dir, runner)
        identifier = initial["id"]
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        name = f"larenor-server-{stamp}-{uuid.uuid4().hex[:12]}.tar.gz"
        final_path = destination / name
        temporary = destination / (name + ".partial")
        stop_attempted = False
        try:
            if initial["running"]:
                stop_attempted = True
                runner(["stop", "--time", "60", identifier], timeout=75)
            stopped = inspect_runtime(data_dir, runner)
            if stopped["id"] != identifier or stopped["running"]:
                raise DeploymentError("container_changed_or_not_stopped")
            if stopped["exitCode"] not in (0, 143):
                raise DeploymentError("unclean_stop_no_consistent_backup")
            fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as stream:
                archiver(data_dir, stream)
                stream.flush()
                os.fsync(stream.fileno())
            after = inspect_runtime(data_dir, runner)
            if after["id"] != identifier or after["running"]:
                raise DeploymentError("container_changed_during_backup")
            # Link is atomic and cannot overwrite an existing archive.
            os.link(temporary, final_path)
            directory_fd = os.open(destination, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            cleanup_failed = False
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
            except OSError:
                cleanup_failed = True
            if stop_attempted:
                # Never start a different/replaced service or a second old instance.
                current = inspect_runtime(data_dir, runner)
                if current["id"] != identifier:
                    raise DeploymentError("container_changed_restart_manually")
                try:
                    runner(["start", identifier], timeout=30)
                    if not inspect_runtime(data_dir, runner)["running"]:
                        raise DeploymentError("restart_failed_check_private_backups")
                except DeploymentError:
                    raise DeploymentError("restart_failed_check_private_backups") from None
            if cleanup_failed:
                raise DeploymentError("backup_cleanup_failed_check_private_backups")
        return {"status": "backup_complete", "archive": name,
                "service_restarted": stop_attempted}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command")
    for name in ("preflight", "verify-runtime", "backup"):
        sub = commands.add_parser(name)
        sub.add_argument("--data-dir", type=Path, default=DATA)
        if name == "backup":
            sub.add_argument("--destination", type=Path, default=BACKUPS)
            sub.add_argument("--execute", action="store_true")
    commands.add_parser("probe").add_argument("--url", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "probe":
            result = probe(args.url)
        elif args.command == "verify-runtime":
            private_directory(args.data_dir)
            current = inspect_runtime(args.data_dir)
            result = {"status": "runtime_policy_verified", "running": current["running"]}
        elif args.command == "backup":
            if args.execute and (platform.system() != "Linux" or os.geteuid() != 0):
                raise DeploymentError("backup_requires_linux_root")
            result = backup(args.data_dir, args.destination, execute=args.execute)
        else:
            result = preflight(getattr(args, "data_dir", DATA))
        print(json.dumps(result, sort_keys=True))
        if args.command in (None, "preflight"):
            ready = (result.get("system") == "supported" and
                     result.get("private_data_directory") == "ok" and
                     result.get("compose_config") == "ok" and
                     all(result.get(f"tcp_{port}") == "no_loopback_listener_seen" for port in (8095, 8097)))
            return 0 if ready else 1
        return 0 if result.get("status") in ("server_reachable", "runtime_policy_verified",
                                             "backup_plan_only", "backup_complete") else 1
    except DeploymentError as error:
        print(json.dumps({"status": str(error)}))
        return 1
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError):
        print(json.dumps({"status": "operation_failed"}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
