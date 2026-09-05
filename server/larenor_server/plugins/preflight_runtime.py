"""Internal Linux entry point for Larenor's read-only host preflight worker.

The eventual unified installer supplies this operator-owned policy and private
runtime directory. This is not a separate service-setup flow. Version 2 policy
may enable a fixed read-only Docker API/platform check. The worker never mutates
Docker, creates storage roots or enables component installation. An occupied
socket is refused, including after a crash; recovery of a stale endpoint belongs
to the operator/runtime-directory manager until the managed installer exists.
"""

import argparse
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import threading

from ..errors import StartupError
from ..files import checked_path, private_read
from .docker_probe import DockerEndpoint
from .host_preflight import HostInspector, HostPolicy, HostRoot, _host_platform
from .preflight_ipc import PreflightWorkerServer
from .worker import _safe_path


MAX_POLICY_BYTES = 32768


class _ConfigurationError(ValueError):
    pass


class _ParserExit(Exception):
    def __init__(self, status):
        self.status = status


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise _ConfigurationError()

    def exit(self, status=0, message=None):
        raise _ParserExit(status)


def _uid(value):
    if not re.fullmatch(r"[0-9]{1,10}", value) or int(value) > 2**31 - 1:
        raise _ConfigurationError()
    return int(value)


def _pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise _ConfigurationError()
        value[key] = item
    return value


def _reject_number(_value):
    raise _ConfigurationError()


def load_policy(path):
    """Read only the small private policy file; do not inspect configured roots."""
    invalid = False
    try:
        source = checked_path(Path(path))
        _safe_path(source, uid=os.geteuid(), kind=stat.S_ISREG, private=True)
        raw = private_read(source, MAX_POLICY_BYTES)
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=_pairs,
                           parse_float=_reject_number, parse_constant=_reject_number)
        if (type(value) is not dict or type(value.get('version')) is not int
                or value['version'] not in (1, 2)
                or set(value) != ({'version', 'roots'} if value['version'] == 1 else {'version', 'roots', 'docker'})
                or type(value['roots']) is not list or not 1 <= len(value['roots']) <= 16):
            raise _ConfigurationError()
        roots = {}
        for root in value['roots']:
            if type(root) is not dict or set(root) != {'id', 'path', 'purpose'} or type(root['id']) is not str or root['id'] in roots:
                raise _ConfigurationError()
            roots[root['id']] = HostRoot(root['path'], root['purpose'])
        docker = value.get('docker')
        endpoint = None
        if docker is not None:
            if type(docker) is not dict or set(docker) != {'socketPath', 'ownerUid'}:
                raise _ConfigurationError()
            endpoint = DockerEndpoint(path=docker['socketPath'], owner_uid=docker['ownerUid'])
        policy = HostPolicy(roots, docker=endpoint)
    except Exception:
        # Neither argparse nor OS/JSON/Pydantic errors may echo a host path or
        # policy value. Raise outside the handler to avoid a raw exception chain.
        invalid = True
    if invalid:
        raise _ConfigurationError()
    return policy


def _serve(args, policy, platform):
    stopped = threading.Event()
    previous = {}
    worker = None
    failed = False
    def stop(_number, _frame):
        stopped.set()
    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.getsignal(number)
            signal.signal(number, stop)
        worker = PreflightWorkerServer(args.socket, HostInspector(policy), platform=platform,
                                       allowed_uid=args.api_uid, socket_gid=args.socket_gid)
        worker.start()
        stopped.wait()
    except Exception:
        failed = True
    finally:
        if worker is not None:
            try:
                worker.close()
            except Exception:
                failed = True
        for number, handler in previous.items():
            try:
                signal.signal(number, handler)
            except Exception:
                failed = True
    return 1 if failed else 0


def main(argv=None) -> int:
    parser = _Parser(prog='larenor-preflight-worker', description=__doc__)
    parser.add_argument('--policy', required=True, type=Path)
    parser.add_argument('--socket', required=True, type=Path)
    parser.add_argument('--api-uid', required=True, type=_uid)
    parser.add_argument('--socket-gid', type=_uid)
    parser.add_argument('--check-config', action='store_true', help='Validate private policy only; never open a socket or inspect host roots')
    try:
        args = parser.parse_args(argv)
        checked_path(args.policy)
        checked_path(args.socket)
        if os.getuid() != os.geteuid() or args.api_uid != os.getuid() and args.socket_gid is None:
            raise _ConfigurationError()
    except _ParserExit as result:
        return result.status
    except (ValueError, StartupError, OSError):
        print('invalid_arguments', file=sys.stderr)
        return 2
    try:
        platform = _host_platform()
        if platform not in ('linux/amd64', 'linux/arm64'):
            print('worker_platform_unsupported', file=sys.stderr)
            return 1
        policy = load_policy(args.policy)
    except Exception:
        print('worker_configuration_invalid', file=sys.stderr)
        return 1
    if args.check_config:
        return 0
    status = _serve(args, policy, platform)
    if status:
        print('worker_unavailable', file=sys.stderr)
    return status


if __name__ == '__main__':
    raise SystemExit(main())
