"""Host entry point for the private systemd user-manager AI worker."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import threading

from .runtime import AiRuntimeConfig, AiRuntimeError, SystemdAiJobRuntime
from .worker_ipc import AiWorkerServer


def build_server(config_path, socket_path, *, core_uid, socket_gid):
    config = AiRuntimeConfig.load(config_path)
    if config.manager != "user":
        raise AiRuntimeError("invalid_runtime_configuration")
    runtime = SystemdAiJobRuntime(config)
    if not runtime.available():
        raise AiRuntimeError("worker_unavailable")
    return AiWorkerServer(
        socket_path, runtime, owner_uid=os.geteuid(), peer_uid=core_uid,
        socket_gid=socket_gid,
    )


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise AiRuntimeError("invalid_runtime_configuration")


def main(argv=None):
    parser = _Parser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--core-uid", required=True, type=int)
    parser.add_argument("--socket-gid", required=True, type=int)
    parser.add_argument("--check-config", action="store_true")
    try:
        args = parser.parse_args(argv)
        if any(not 0 <= value < 2**31 for value in (args.core_uid, args.socket_gid)):
            raise AiRuntimeError("invalid_runtime_configuration")
        server = build_server(
            args.config, args.socket, core_uid=args.core_uid,
            socket_gid=args.socket_gid,
        )
        if args.check_config:
            return 0
        stopped = threading.Event()
        previous = {}
        for number in (signal.SIGTERM, signal.SIGINT):
            previous[number] = signal.signal(number, lambda *_args: stopped.set())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            while not stopped.wait(0.2):
                if not thread.is_alive():
                    raise AiRuntimeError()
        finally:
            server.close()
            thread.join(timeout=3)
            for number, handler in previous.items():
                signal.signal(number, handler)
        return 0
    except AiRuntimeError as error:
        print(error.code, file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
