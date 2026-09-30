from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import threading
import time
import pytest

from larenor_server.media_archive_actions.cleanup_executor import (
    ArchiveCleanupExecutorError, PrivateArchiveDeleteExecutor,
    ResolvedDuplicateCleanup, ResolvedDuplicateCleanupItem,
    ResolvedRetentionCleanup, cleanup_effects,
)
from larenor_server.media_archive_actions.journal import action_command_digest
from larenor_server.media_archive_actions.models import (
    ArchiveActionAuthority, PrivateArchiveActionCommand,
)
from test_media_archive_core_read import authority as collection_authority
from test_media_archive_worker_ipc import private


def action_authority(value):
    return ArchiveActionAuthority(
        installationId=value.installationId,
        installationRevision=value.installationRevision,
        snapshotRevision=value.snapshotRevision,
        sourceRevisions={item.serviceId: item.serviceRevision
                         for item in value.sources})


def retention(authority):
    return PrivateArchiveActionCommand(
        operationId="8" * 32, operation="cleanup_retention",
        authority=authority,
        candidate={
            "candidateId": "8" * 64, "kind": "retention",
            "title": "Retained download", "potentialBytes": 7,
            "confidence": "medium", "comparison": {
                "basis": "review_retained_copy", "observedBytes": 7,
                "estimatedRetainedBytes": 0, "estimatedSavingBytes": 7},
            "evidence": ["download_complete", "import_verified",
                         "retention_policy_satisfied"], "actionType": "cleanup"},
        target={"targetType": "retention", "torrentId": "a" * 40,
                "importedMediaKey": "movie:tmdb:1"},
        evidenceDigest="8" * 64, reservedBytes=0, retainOriginal=False)


def duplicate(authority):
    return PrivateArchiveActionCommand(
        operationId="7" * 32, operation="cleanup_duplicate",
        authority=authority,
        candidate={
            "candidateId": "7" * 64, "kind": "duplicate",
            "title": "Duplicate", "potentialBytes": 6,
            "confidence": "high", "comparison": {
                "basis": "keep_largest_copy", "observedBytes": 13,
                "estimatedRetainedBytes": 7, "estimatedSavingBytes": 6},
            "evidence": ["content_hash_match", "multiple_playable_files",
                         "largest_copy_excluded"], "actionType": "cleanup"},
        target={"targetType": "duplicate", "keepItemId": "1" * 32,
                "deleteItemIds": ["2" * 32]},
        evidenceDigest="7" * 64, reservedBytes=0, retainOriginal=False)


def test_real_loopback_qbittorrent_delete_removes_temp_file_and_reads_absence(tmp_path):
    content = tmp_path / "download.bin"
    content.write_bytes(b"content")
    state = {"present": True, "keep": False, "auth": [], "requests": []}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def _send(self, value, content_type="application/json"):
            raw = json.dumps(value).encode()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)

        def _missing(self):
            raw = b"missing"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            state["requests"].append(("GET", self.path))
            state["auth"].append(self.headers.get("Authorization"))
            if self.path == "/api/v2/app/version":
                raw = b"v5.2.3"
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(raw)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(raw)
            elif self.path.startswith("/Items/"):
                if state["keep"]:
                    self._send({
                        "Id": "1" * 32, "Path": "/media/movies/movie.mkv",
                        "MediaSources": [{"Size": 7}]})
                else:
                    self._missing()
            elif self.path == "/api/v3/moviefile/1":
                self._send({
                    "id": 1, "path": "/data/movies/movie.mkv", "size": 7})
            else:
                self._send([{
                    "hash": "a" * 40,
                    "content_path": "/data/downloads/movies/download.bin",
                    "total_size": 7, "state": "completed"}
                    ] if state["present"] else [])

        def do_POST(self):
            state["requests"].append(("POST", self.path))
            state["auth"].append(self.headers.get("Authorization"))
            length = int(self.headers["Content-Length"])
            assert self.rfile.read(length) == (
                b"hashes=" + b"a" * 40 + b"&deleteFiles=true")
            content.unlink()
            state["present"] = False
            self._send("Ok.", "text/plain")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        current = collection_authority()
        command = retention(action_authority(current))
        executor = PrivateArchiveDeleteExecutor()
        ports = {name: server.server_port for name in (
            "jellyfin", "sonarr", "radarr", "qbittorrent")}
        executor.refresh_authenticated(
            private(current=current), ports,
            deadline=time.monotonic()+5, gate=lambda: True)
        plan = ResolvedRetentionCleanup(
            action_command_digest(command), "5" * 64, "a" * 40,
            "movie:tmdb:1", "/data/downloads/movies/download.bin", 7,
            ResolvedDuplicateCleanupItem(
                "1" * 32, "movie:tmdb:1", "radarr", 1,
                "/media/movies/movie.mkv",
                "/data/movies/movie.mkv", 7))
        effect = cleanup_effects(plan)[0]
        assert executor.observe(
            command, plan, effect, deadline=time.monotonic()+5)
        with pytest.raises(ArchiveCleanupExecutorError) as blocked:
            executor.mutate(
                command, plan, effect, deadline=time.monotonic()+5)
        assert blocked.value.code == "authority_changed"
        assert content.exists()
        assert not any(method == "POST" for method, _path in state["requests"])

        state["keep"] = True
        assert executor.mutate(
            command, plan, effect, deadline=time.monotonic()+5)
        assert not content.exists()
        assert not executor.observe(
            command, plan, effect, deadline=time.monotonic()+5)
        assert any(value and value.startswith("Bearer qbt_")
                   for value in state["auth"])
        assert any(value and value.startswith("MediaBrowser ")
                   for value in state["auth"])
        post_index = state["requests"].index(
            ("POST", "/api/v2/torrents/delete"))
        before_post = state["requests"][:post_index]
        assert ("GET", "/api/v2/app/version") in before_post
        assert any(path.startswith("/Items/")
                   for method, path in before_post if method == "GET")
        assert ("GET", "/api/v3/moviefile/1") in before_post
        assert any(path.startswith("/api/v2/torrents/info?")
                   for method, path in before_post if method == "GET")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def test_real_loopback_duplicate_deletes_arr_file_then_jellyfin_index(tmp_path):
    duplicate_file = tmp_path / "duplicate.mkv"
    duplicate_file.write_bytes(b"delete")
    state = {"arr": True, "jellyfin": True, "requests": []}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def _send(self, value, *, status=200, content_type="application/json"):
            raw = (json.dumps(value).encode() if content_type == "application/json"
                   else str(value).encode())
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)

        def _missing(self):
            self._send("missing", status=404, content_type="text/plain")

        def do_GET(self):
            state["requests"].append(("GET", self.path))
            if self.path == "/api/v3/system/status":
                self._send({"appName": "Radarr", "version": "6.3.0.10514"})
            elif self.path == "/System/Info":
                self._send({"Id": "2" * 32, "ProductName": "Jellyfin Server",
                            "Version": "10.11.11"})
            elif self.path == "/api/v3/moviefile/1":
                self._send({"id": 1, "path": "/data/movies/keep.mkv", "size": 7})
            elif self.path == "/api/v3/moviefile/2":
                if state["arr"]:
                    self._send({"id": 2, "path": "/data/movies/delete.mkv",
                                "size": 6})
                else:
                    self._missing()
            elif self.path.startswith("/Items/" + "1" * 32):
                self._send({"Id": "1" * 32, "Path": "/media/movies/keep.mkv",
                            "MediaSources": [{"Size": 7}]})
            elif self.path.startswith("/Items/" + "2" * 32):
                if state["jellyfin"]:
                    self._send({"Id": "2" * 32,
                                "Path": "/media/movies/delete.mkv",
                                "MediaSources": [{"Size": 6}]})
                else:
                    self._missing()
            else:
                self._missing()

        def do_DELETE(self):
            state["requests"].append(("DELETE", self.path))
            if self.path == "/api/v3/moviefile/2":
                assert duplicate_file.exists()
                duplicate_file.unlink()
                state["arr"] = False
            elif self.path == "/Items/" + "2" * 32:
                # Arr has already removed the filesystem object. Jellyfin still
                # removes its indexed item, matching upstream LibraryManager.
                assert not duplicate_file.exists()
                state["jellyfin"] = False
            else:
                raise AssertionError(self.path)
            self._send({})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        current = collection_authority()
        command = duplicate(action_authority(current))
        executor = PrivateArchiveDeleteExecutor()
        ports = {name: server.server_port for name in (
            "jellyfin", "sonarr", "radarr", "qbittorrent")}
        executor.refresh_authenticated(
            private(current=current), ports,
            deadline=time.monotonic()+5, gate=lambda: True)
        keep = ResolvedDuplicateCleanupItem(
            "1" * 32, "movie:tmdb:1", "radarr", 1,
            "/media/movies/keep.mkv", "/data/movies/keep.mkv", 7)
        removed = ResolvedDuplicateCleanupItem(
            "2" * 32, "movie:tmdb:1", "radarr", 2,
            "/media/movies/delete.mkv", "/data/movies/delete.mkv", 6)
        plan = ResolvedDuplicateCleanup(
            action_command_digest(command), "6" * 64, keep, (removed,))
        assert executor.preflight(
            command, plan, deadline=time.monotonic()+5) == plan.planDigest
        effects = cleanup_effects(plan)
        assert executor.mutate(
            command, plan, effects[0], deadline=time.monotonic()+5)
        assert not duplicate_file.exists() and state["jellyfin"]
        assert executor.mutate(
            command, plan, effects[1], deadline=time.monotonic()+5)
        assert not state["jellyfin"]
        deletes = [path for method, path in state["requests"]
                   if method == "DELETE"]
        assert deletes == ["/api/v3/moviefile/2", "/Items/" + "2" * 32]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
