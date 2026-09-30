"""Actual Jellyfin-shaped TCP -> Flutter Client -> normal Core F26 gate."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


def main():
    calls = []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "-1"))
            raw = self.rfile.read(length) if 0 <= length <= 256_000 else b""
            try:
                body = json.loads(raw)
            except (UnicodeDecodeError, json.JSONDecodeError):
                self.send_error(400)
                return
            calls.append((self.path, self.headers.get("X-Emby-Authorization"), body))
            authorization = self.headers.get("X-Emby-Authorization", "")
            if (self.path != "/Items/movie-1/PlaybackInfo" or
                    'Token="f26-owned-token"' not in authorization or
                    body.get("UserId") != "f26-user" or
                    body.get("MaxStreamingBitrate") != 20_000_000 or
                    not isinstance(body.get("DeviceProfile"), dict)):
                self.send_error(400)
                return
            response = {
                "PlaySessionId": "f26-play-session",
                "MediaSources": [{
                    "Id": "main-source",
                    "SupportsDirectPlay": False,
                    "SupportsDirectStream": False,
                    "SupportsTranscoding": True,
                    "TranscodingUrl": "/Videos/movie-1/master.m3u8?token=fixture",
                    "Container": "mkv",
                    "TranscodingContainer": "ts",
                    "Bitrate": 25_000_000,
                    "TranscodingReasons": [
                        "VideoCodecNotSupported", "BitrateTooHigh",
                    ],
                    "MediaStreams": [
                        {"Type": "Video", "Codec": "hevc",
                         "VideoRange": "HDR10", "Width": 3840,
                         "Height": 2160},
                        {"Type": "Audio", "Codec": "eac3"},
                        {"Type": "Subtitle", "Codec": "srt"},
                    ],
                }],
            }
            encoded = json.dumps(response, separators=(",", ":")).encode("ascii")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(encoded)

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=upstream.serve_forever, daemon=True)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix="larenor-f26-client-") as root:
            generator = core_fixture.__wrapped__(Path(root))
            fixture = next(generator)
            try:
                ready(fixture)
                with InstalledCoreTcp(fixture[0]) as tcp:
                    result = subprocess.run([
                        "flutter", "test", "--no-pub",
                        "test/features/media/playback_quality/"
                        "core_playback_quality_normal_core_test.dart",
                    ], env={
                        **os.environ,
                        "LARENOR_F26_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                        "LARENOR_F26_JELLYFIN_URL": (
                            f"http://127.0.0.1:{upstream.server_port}"
                        ),
                    }, cwd=Path(__file__).resolve().parents[3],
                        timeout=120, check=False)
                    if result.returncode:
                        return result.returncode
            finally:
                generator.close()
        if len(calls) != 1:
            raise RuntimeError(f"unexpected_jellyfin_calls:{len(calls)}")
    finally:
        upstream.shutdown()
        upstream.server_close()
        worker.join(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
