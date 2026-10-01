"""Real FFmpeg fixtures; these do not substitute a fabricated media probe."""

import hashlib
from pathlib import Path
import shutil
import subprocess
import time

import pytest

from larenor_server.media_archive_actions.models import PrivateArchiveActionCommand
from larenor_server.media_archive_actions.verifier import (
    ArchiveVerificationError, MediaArchiveOutputVerifier,
)
from test_media_archive_action_journal import command


@pytest.fixture(scope="module")
def media(tmp_path_factory):
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        pytest.skip("real FFmpeg/ffprobe dependency unavailable")
    directory = tmp_path_factory.mktemp("real-archive-media")
    source = directory / "source.mkv"
    subtitles = directory / "captions.srt"
    subtitles.write_text("1\n00:00:00,100 --> 00:00:01,800\nArchive caption\n", encoding="utf-8")
    subprocess.run([
        ffmpeg, "-v", "error", "-nostdin", "-f", "lavfi", "-i",
        "testsrc2=size=160x90:rate=24:duration=2", "-f", "lavfi", "-i",
        "sine=frequency=440:duration=2", "-i", str(subtitles),
        "-map", "0:v", "-map", "1:a", "-map", "2:s",
        "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p",
        "-color_range", "tv", "-colorspace", "bt709",
        "-c:a", "aac", "-c:s", "srt", str(source),
    ], check=True, capture_output=True, timeout=30)
    output = directory / "output.mkv"
    transcode(ffmpeg, source, output)
    value = command().model_dump(mode="json")
    length = source.stat().st_size
    source_bitrate = length * 4
    target_bitrate = source_bitrate // 2
    saving = min(length, (source_bitrate - target_bitrate) * 2 // 8)
    value["reservedBytes"] = length
    value["target"].update(sourceSizeBytes=length, durationSeconds=2,
                           sourceBitrate=source_bitrate, targetBitrate=target_bitrate)
    value["candidate"]["potentialBytes"] = saving
    value["candidate"]["comparison"].update(
        observedBytes=length, estimatedSavingBytes=saving, estimatedRetainedBytes=length-saving)
    return MediaArchiveOutputVerifier(ffmpeg, ffprobe), ffmpeg, source, output, PrivateArchiveActionCommand.model_validate(value)


def transcode(ffmpeg, source, output, *, extra=(), codec="libx265"):
    subprocess.run([
        ffmpeg, "-v", "error", "-nostdin", "-i", str(source), "-map", "0",
        "-c", "copy", "-c:v", codec, "-crf", "32", "-threads", "1",
        *(["-x265-params", "pools=1:frame-threads=1:log-level=error"] if codec == "libx265" else []),
        *extra, str(output),
    ], check=True, capture_output=True, timeout=30)


def verify(media, output=None, **kwargs):
    verifier, _ffmpeg, source, original_output, cmd = media
    return verifier.verify(cmd, source, output or original_output,
                           deadline=time.monotonic()+30, **kwargs)


def test_real_smaller_hevc_decodes_and_preserves_copied_audio(media):
    result = verify(media)
    output = media[3]
    assert result.digest == hashlib.sha256(output.read_bytes()).hexdigest()
    assert result.byteLength == output.stat().st_size < media[2].stat().st_size
    assert (result.codec, result.width, result.height, result.audioStreams) == ("hevc", 160, 90, 1)
    assert result.subtitleStreams == 1


def test_real_fixture_has_explicit_preserved_sdr_color_contract(media):
    verifier, _ffmpeg, source, output, _command = media
    expected = {"pix_fmt": "yuv420p", "color_range": "tv", "color_space": "bt709"}
    for path in (source, output):
        with verifier._opened(path) as (fd, _info):
            observed = verifier._probe(fd, time.monotonic() + 30, lambda: False)
        video = [stream for stream in observed["streams"]
                 if stream.get("codec_type") == "video"]
        assert len(video) == 1
        assert {key: video[0].get(key) for key in expected} == expected


def test_real_output_with_changed_color_range_is_rejected(media, tmp_path):
    output = tmp_path / "changed-range.mkv"
    transcode(media[1], media[2], output, extra=("-color_range", "pc"))
    with pytest.raises(ArchiveVerificationError):
        verify(media, output)


def test_real_output_with_dropped_audio_is_rejected(media, tmp_path):
    output = tmp_path / "missing-audio.mkv"
    transcode(media[1], media[2], output, extra=("-an",))
    with pytest.raises(ArchiveVerificationError):
        verify(media, output)


def test_real_output_with_changed_picture_dimensions_is_rejected(media, tmp_path):
    output = tmp_path / "scaled.mkv"
    transcode(media[1], media[2], output, extra=("-vf", "scale=128:72"))
    with pytest.raises(ArchiveVerificationError):
        verify(media, output)


def test_real_output_with_wrong_codec_is_rejected(media, tmp_path):
    output = tmp_path / "wrong-codec.mkv"
    transcode(media[1], media[2], output, codec="libx264")
    with pytest.raises(ArchiveVerificationError):
        verify(media, output)


def test_real_output_with_changed_audio_packets_is_rejected(media, tmp_path):
    output = tmp_path / "changed-audio.mkv"
    transcode(media[1], media[2], output, extra=("-c:a", "aac", "-af", "volume=0.2"))
    with pytest.raises(ArchiveVerificationError):
        verify(media, output)


def test_real_output_with_lost_video_frames_is_rejected(media, tmp_path):
    output = tmp_path / "lost-frames.mkv"
    transcode(media[1], media[2], output, extra=("-r", "12"))
    with pytest.raises(ArchiveVerificationError):
        verify(media, output)


def test_truncated_real_output_is_not_installable(media, tmp_path):
    output = tmp_path / "truncated.mkv"
    data = media[3].read_bytes()
    output.write_bytes(data[:len(data)//2])
    with pytest.raises(ArchiveVerificationError):
        verify(media, output)


def test_cancel_or_expired_deadline_preserves_both_files(media):
    before = [hashlib.sha256(path.read_bytes()).hexdigest() for path in media[2:4]]
    with pytest.raises(ArchiveVerificationError, match="cancelled"):
        verify(media, cancelled=lambda: True)
    with pytest.raises(ArchiveVerificationError):
        media[0].verify(media[4], media[2], media[3], deadline=time.monotonic()-1)
    assert before == [hashlib.sha256(path.read_bytes()).hexdigest() for path in media[2:4]]


def test_output_symlink_and_identical_file_are_rejected(media, tmp_path):
    output = tmp_path / "linked.mkv"
    output.symlink_to(media[3])
    with pytest.raises(ArchiveVerificationError):
        verify(media, output)
    with pytest.raises(ArchiveVerificationError):
        verify(media, media[2])
