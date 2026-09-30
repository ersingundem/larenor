"""Normal private worker composition for archive reads and confirmed actions."""

import argparse
from contextlib import ExitStack
from dataclasses import dataclass
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time

from ..plugins.media_archive_read_collector import MediaArchiveReadCollector
from ..plugins.media_archive_worker_ipc import MediaArchiveWorkerClient, MediaArchiveWorkerServer
from .callback_server import UnmanicCallbackServer
from .engine import MediaArchiveActionEngine
from .encoder_plan import SignedArchiveTranscodePlanWriter
from .file_store import MediaArchiveFileStore
from .http_transport import UnmanicLoopbackHttpTransport
from .journal import MediaArchiveActionJournal
from .source_resolver import (
    CoreArchiveActionAuthorityReader, PrivateArchiveResolverCatalog,
    build_private_media_archive_source_publisher,
    build_private_media_archive_source_resolver, _read_private, _unique_pairs,
)
from .terminal_store import UnmanicTerminalStore
from .unmanic import UnmanicAdapter, UnmanicRequest
from .verifier import MediaArchiveOutputVerifier
from .worker_ipc import MediaArchiveActionWorkerServer


class ArchiveWorkerRuntimeError(RuntimeError):
    def __init__(self):
        super().__init__("archive_worker_unavailable")


def _verified_encoder_library(transport, library):
    response = transport(UnmanicRequest(
        'POST', '/unmanic/api/v2/settings/library/read',
        (('Accept', 'application/json'), ('Content-Type', 'application/json')),
        json.dumps({'id': library.libraryId}).encode()), time.monotonic() + 5)
    if response.status != 200 or response.contentType.split(';', 1)[0] != 'application/json':
        raise ArchiveWorkerRuntimeError()
    value = json.loads(response.body, object_pairs_hook=_unique_pairs)
    if (type(value) is not dict or type(value.get('library_config')) is not dict
            or value['library_config'].get('id') != library.libraryId
            or value['library_config'].get('path') != library.workRoot
            or type(value.get('plugins')) is not dict
            or type(value['plugins'].get('enabled_plugins')) is not list):
        raise ArchiveWorkerRuntimeError()
    plugins = value['plugins']['enabled_plugins']
    if (len(plugins) != 2 or any(type(item) is not dict for item in plugins)
            or {item.get('plugin_id') for item in plugins}
            != {'larenor_archive_encoder', 'larenor_archive_terminal'}):
        raise ArchiveWorkerRuntimeError()


@dataclass(frozen=True, repr=False)
class ArchiveWorkerRuntimeConfig:
    resolverCatalog: str
    readSocket: str
    actionSocket: str
    authoritySocket: str
    coreUid: int
    unmanicPort: int
    callbackPort: int
    journalRoot: str
    terminalRoot: str
    callbackKeyFile: str
    ffmpeg: str
    ffprobe: str
    quotaBytes: int

    def __repr__(self):
        return "ArchiveWorkerRuntimeConfig(<private>)"

    def __post_init__(self):
        paths = (self.resolverCatalog, self.readSocket, self.actionSocket,
            self.authoritySocket, self.journalRoot, self.terminalRoot,
            self.callbackKeyFile, self.ffmpeg, self.ffprobe)
        if (any(type(path) is not str or not Path(path).is_absolute()
                or '..' in Path(path).parts or str(Path(path)) != path
                or any(ord(char) < 32 or ord(char) == 127 for char in path)
                for path in paths)
                or len(set(paths)) != len(paths)
                or any(len(path.encode('utf-8')) > 103 for path in (
                    self.readSocket, self.actionSocket, self.authoritySocket))
                or type(self.coreUid) is not int or not 0 <= self.coreUid < 2**31
                or any(type(port) is not int or not 1024 <= port <= 65535
                       for port in (self.unmanicPort, self.callbackPort))
                or self.unmanicPort == self.callbackPort
                or type(self.quotaBytes) is not int
                or not 256*1024**2 <= self.quotaBytes <= 10*1024**4):
            raise ArchiveWorkerRuntimeError()

    @classmethod
    def load(cls, path):
        try:
            value = json.loads(_read_private(path, maximum=16384).decode('utf-8'),
                object_pairs_hook=_unique_pairs,
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
            if (type(value) is not dict
                    or set(value) != {'schemaVersion', *cls.__dataclass_fields__}
                    or type(value['schemaVersion']) is not int or value.pop('schemaVersion') != 1):
                raise ValueError()
            return cls(**value)
        except Exception:
            raise ArchiveWorkerRuntimeError() from None


class _Collector:
    """Live authority comes from Core, never from this worker's snapshot cache."""

    def __init__(self, collector, authority):
        self._collector, self._authority = collector, authority

    def current(self, installation_id):
        return self._authority.current(installation_id)

    def collect(self, private, *, deadline, gate):
        return self._collector.collect(private, deadline=deadline, gate=gate)


class ArchiveWorkerRuntime:
    def __init__(self, config):
        if type(config) is not ArchiveWorkerRuntimeConfig:
            raise ArchiveWorkerRuntimeError()
        self._resources = ExitStack()
        self._started = False
        try:
            catalog = PrivateArchiveResolverCatalog.load(config.resolverCatalog)
            roots = tuple(Path(path) for path in (
                config.journalRoot, config.terminalRoot, catalog.storeRoot,
                catalog.workRoot, catalog.retainedRoot,
                *(mount.hostRoot for mount in catalog.approvedMounts)))
            if (len(set(roots)) != len(roots)
                    or any(left.is_relative_to(right) for left in roots for right in roots if left != right)):
                raise ValueError()
            authority = MediaArchiveWorkerClient(config.authoritySocket, owner_uid=config.coreUid)
            transport = UnmanicLoopbackHttpTransport(config.unmanicPort)
            publisher = self._resources.enter_context(build_private_media_archive_source_publisher(
                config.resolverCatalog, unmanic_exchange=transport))
            resolver = self._resources.enter_context(build_private_media_archive_source_resolver(
                config.resolverCatalog, authority_reader=CoreArchiveActionAuthorityReader(authority),
                unmanic_exchange=transport))
            # Refuse to expose ready action IPC without the actual isolated
            # library readback and working verifier binaries.
            library = resolver._unmanic(time.monotonic() + 5)
            _verified_encoder_library(transport, library)
            journal = self._resources.enter_context(MediaArchiveActionJournal(config.journalRoot))
            key = _read_private(config.callbackKeyFile, maximum=32)
            if len(key) != 32:
                raise ValueError()
            terminals = self._resources.enter_context(UnmanicTerminalStore(config.terminalRoot, key))
            files = MediaArchiveFileStore(catalog.retainedRoot, catalog.workRoot,
                tuple(mount.hostRoot for mount in catalog.approvedMounts), quota_bytes=config.quotaBytes)
            verifier = MediaArchiveOutputVerifier(config.ffmpeg, config.ffprobe)
            engine = MediaArchiveActionEngine(journal, files, UnmanicAdapter(transport),
                terminals, verifier, resolver,
                plan_writer=SignedArchiveTranscodePlanWriter(catalog.workRoot, key))
            self._resources.callback(engine.close)
            self.callback = UnmanicCallbackServer(terminals, config.callbackPort)
            self._resources.callback(self.callback.close)
            self.actions = MediaArchiveActionWorkerServer(config.actionSocket, engine, peer_uid=config.coreUid)
            self._resources.callback(self.actions.close)
            self.reads = MediaArchiveWorkerServer(config.readSocket,
                _Collector(MediaArchiveReadCollector(private_source_sink=publisher), authority),
                allowed_uid=config.coreUid)
            self._resources.callback(self.reads.close)
        except Exception:
            self.close()
            raise ArchiveWorkerRuntimeError() from None

    def start(self):
        if self._started:
            raise ArchiveWorkerRuntimeError()
        try:
            self.callback.start()
            self.actions.start()
            self.reads.start()
            self._started = True
            return self
        except Exception:
            self.close()
            raise ArchiveWorkerRuntimeError() from None

    def close(self):
        self._resources.close()

    def __enter__(self):
        return self.start()

    def __exit__(self, *_args):
        self.close()


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise ArchiveWorkerRuntimeError()


def main(argv=None):
    parser = _Parser(description=__doc__)
    parser.add_argument('--config', required=True)
    stopped = threading.Event()
    previous = {}
    try:
        args = parser.parse_args(argv)
        config = ArchiveWorkerRuntimeConfig.load(args.config)
        for number in (signal.SIGTERM, signal.SIGINT):
            previous[number] = signal.signal(number, lambda *_args: stopped.set())
        with ArchiveWorkerRuntime(config):
            while not stopped.wait(0.2):
                pass
        return 0
    except Exception:
        print('archive_worker_unavailable', file=sys.stderr)
        return 2
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


if __name__ == '__main__':
    raise SystemExit(main())
