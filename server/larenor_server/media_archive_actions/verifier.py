"""Read-only, bounded verification of a real transcoded media file.

The worker probes two opened descriptors, decodes every output video/audio
packet and hashes copied audio/subtitle packets. No shell, network protocols,
playlist demuxers or caller-selected FFmpeg options are accepted.
"""

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import time


class ArchiveVerificationError(RuntimeError):
    def __init__(self, code="verification_failed"):
        self.code = code
        super().__init__(code)


def _require(value, code="verification_failed"):
    if not value:
        raise ArchiveVerificationError(code)


def _identity(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def _number(value):
    _require(type(value) in (str, int, float) and type(value) is not bool)
    try:
        result = float(value)
    except (ValueError, OverflowError):
        raise ArchiveVerificationError() from None
    _require(math.isfinite(result) and result > 0)
    return result


@dataclass(frozen=True)
class VerifiedArchiveOutput:
    digest: str
    byteLength: int
    codec: str
    durationSeconds: float
    width: int
    height: int
    audioStreams: int
    subtitleStreams: int


class MediaArchiveOutputVerifier:
    MAX_OUTPUT = 512 * 1024
    MAX_SECONDS = 6 * 60 * 60
    _FORMATS = "matroska,webm,mov,avi,mpegts,mpeg"
    _COPY_FIELDS = ("codec_type", "codec_name", "sample_rate", "channels",
                    "channel_layout", "extradata_hash")
    _VIDEO_FIELDS = ("width", "height", "pix_fmt", "color_range", "color_space",
                     "color_transfer", "color_primaries")

    def __init__(self, ffmpeg, ffprobe):
        self.ffmpeg = self._binary(ffmpeg)
        self.ffprobe = self._binary(ffprobe)

    @staticmethod
    def _binary(path):
        try:
            _require(Path(path).is_absolute())
            resolved = Path(path).resolve(strict=True)
            info = resolved.stat()
            _require(stat.S_ISREG(info.st_mode) and not info.st_mode & 0o022
                     and info.st_uid in {0, os.getuid()} and os.access(resolved, os.X_OK))
            return str(resolved)
        except (OSError, ValueError, TypeError):
            raise ArchiveVerificationError("verifier_unavailable") from None

    @contextmanager
    def _opened(self, path):
        fd = None
        try:
            _require(Path(path).is_absolute())
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            before = os.fstat(fd)
            _require(stat.S_ISREG(before.st_mode) and before.st_size > 0)
            yield fd, before
            _require(_identity(before) == _identity(os.fstat(fd)))
            _require(_identity(before) == _identity(os.stat(path, follow_symlinks=False)))
        except OSError:
            raise ArchiveVerificationError() from None
        finally:
            if fd is not None:
                os.close(fd)

    def _run(self, args, fd, deadline, cancelled):
        _require(not cancelled(), "cancelled")
        _require(time.monotonic() < deadline, "verification_deadline")
        process = None
        output = bytearray()
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            process = subprocess.Popen(
                args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, pass_fds=(fd,), start_new_session=True,
                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
            )
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, True)
                selector.register(process.stderr, selectors.EVENT_READ, False)
                total = 0
                while selector.get_map():
                    _require(not cancelled(), "cancelled")
                    _require(time.monotonic() < deadline, "verification_deadline")
                    for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                        part = os.read(key.fileobj.fileno(), 16 * 1024)
                        if not part:
                            selector.unregister(key.fileobj)
                            continue
                        total += len(part)
                        _require(total <= self.MAX_OUTPUT, "verification_output_limit")
                        if key.data:
                            output.extend(part)
            _require(process.wait(timeout=max(0.001, deadline - time.monotonic())) == 0)
            return bytes(output)
        except (OSError, subprocess.SubprocessError):
            raise ArchiveVerificationError() from None
        finally:
            if process is not None:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                process.stdout.close()
                process.stderr.close()

    def _input(self, fd):
        return ["-protocol_whitelist", "file,pipe", "-format_whitelist",
                self._FORMATS, "-i", "/dev/fd/" + str(fd)]

    def _probe(self, fd, deadline, cancelled):
        raw = self._run([
            self.ffprobe, "-v", "error", *self._input(fd),
            "-show_streams", "-show_format", "-show_data_hash", "sha256",
            "-of", "json",
        ], fd, deadline, cancelled)
        try:
            value = json.loads(raw)
            _require(type(value) is dict and type(value.get("streams")) is list
                     and 1 <= len(value["streams"]) <= 64
                     and type(value.get("format")) is dict)
            _require(all(type(item) is dict for item in value["streams"]))
            value["duration"] = _number(value["format"].get("duration"))
            return value
        except (ValueError, KeyError, TypeError, RecursionError):
            raise ArchiveVerificationError() from None

    def _copied(self, probe):
        return [{**{key: item.get(key) for key in self._COPY_FIELDS},
                 "language": item.get("tags", {}).get("language"),
                 "title": item.get("tags", {}).get("title"),
                 "disposition": item.get("disposition", {})}
                for item in probe["streams"] if item.get("codec_type") != "video"]

    def _copy_hashes(self, fd, probe, deadline, cancelled):
        # Packet hashing proves compressed audio/subtitle content was preserved;
        # attachment bytes are covered by ffprobe's extradata_hash above.
        if not any(item.get("codec_type") in {"audio", "subtitle"}
                   for item in probe["streams"]):
            return b""
        value = self._run([
            self.ffmpeg, "-v", "error", "-nostdin", *self._input(fd),
            "-map", "0:a?", "-map", "0:s?", "-c", "copy", "-f",
            "streamhash", "-hash", "sha256", "pipe:1",
        ], fd, deadline, cancelled)
        _require(value.strip())
        return value

    def _decode(self, fd, deadline, cancelled):
        decoded = self._run([
            self.ffmpeg, "-v", "error", "-nostdin", "-xerror",
            "-err_detect", "explode", *self._input(fd),
            "-map", "0:v:0", "-map", "0:a?", "-progress", "pipe:1",
            "-nostats", "-f", "null", "-",
        ], fd, deadline, cancelled)
        fields = dict(line.split(b"=", 1) for line in decoded.splitlines() if b"=" in line)
        _require(fields.get(b"progress") == b"end")
        try:
            frames = _number(fields.get(b"frame", b"0").decode("ascii"))
            seconds = _number(fields.get(b"out_time_us", b"0").decode("ascii")) / 1_000_000
            return frames, seconds
        except (UnicodeDecodeError, AttributeError):
            raise ArchiveVerificationError() from None

    @staticmethod
    def _hash(fd, deadline, cancelled):
        digest = hashlib.sha256()
        length = 0
        os.lseek(fd, 0, os.SEEK_SET)
        while True:
            _require(not cancelled(), "cancelled")
            _require(time.monotonic() < deadline, "verification_deadline")
            part = os.read(fd, 1024 * 1024)
            if not part:
                return digest.hexdigest(), length
            digest.update(part)
            length += len(part)

    def verify(self, command, original_path, output_path, *, deadline, cancelled=lambda: False):
        _require(command.operation == "stage_transcode")
        _require(type(deadline) in (float, int) and math.isfinite(deadline)
                 and time.monotonic() < deadline <= time.monotonic() + self.MAX_SECONDS)
        target = command.target
        with self._opened(original_path) as (source_fd, source_info), \
                self._opened(output_path) as (output_fd, output_info):
            _require(source_info.st_size == target.sourceSizeBytes
                     and 0 < output_info.st_size < source_info.st_size
                     and (source_info.st_dev, source_info.st_ino)
                     != (output_info.st_dev, output_info.st_ino))
            source = self._probe(source_fd, deadline, cancelled)
            output = self._probe(output_fd, deadline, cancelled)
            tolerance = max(0.25, source["duration"] * 0.001)
            _require(abs(source["duration"] - target.durationSeconds) <= max(1, tolerance)
                     and abs(source["duration"] - output["duration"]) <= tolerance
                     and source["format"].get("format_name") == output["format"].get("format_name"))
            src_video = [s for s in source["streams"] if s.get("codec_type") == "video"]
            dst_video = [s for s in output["streams"] if s.get("codec_type") == "video"]
            _require(len(src_video) == len(dst_video) == 1)
            old, new = src_video[0], dst_video[0]
            codec = {"mpeg2video": "mpeg2"}.get(old.get("codec_name"), old.get("codec_name"))
            _require(codec == target.sourceCodec and new.get("codec_name") == target.targetCodec
                     and all(old.get(key) == new.get(key) for key in self._VIDEO_FIELDS)
                     and type(new.get("width")) is int and new["width"] > 0
                     and type(new.get("height")) is int and new["height"] > 0
                     and self._copied(source) == self._copied(output))
            _require(self._copy_hashes(source_fd, source, deadline, cancelled)
                     == self._copy_hashes(output_fd, output, deadline, cancelled))
            source_frames, source_seconds = self._decode(source_fd, deadline, cancelled)
            output_frames, output_seconds = self._decode(output_fd, deadline, cancelled)
            _require(source_frames == output_frames and output_seconds
                     >= source["duration"] - max(0.25, tolerance)
                     and abs(source_seconds - output_seconds) <= tolerance)
            digest, length = self._hash(output_fd, deadline, cancelled)
            _require(length == output_info.st_size)
            return VerifiedArchiveOutput(
                digest, length, target.targetCodec, output["duration"],
                new["width"], new["height"],
                sum(item.get("codec_type") == "audio" for item in output["streams"]),
                sum(item.get("codec_type") == "subtitle" for item in output["streams"]),
            )
