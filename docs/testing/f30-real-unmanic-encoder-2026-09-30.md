# F30 signed encoder and actual Unmanic acceptance

The isolated archive library now requires exactly `larenor_archive_encoder` and
`larenor_archive_terminal`. The worker writes a per-command HMAC plan only after
confirmation and durable original protection. The standalone encoder validates
that plan, staged inode/content, codec/bitrate and bounded expiry before returning
a fixed FFmpeg argv. A scan cannot authorize an unsigned file. All audio,
subtitle and attachment tracks are copied; the video is encoded with libx265 or
libsvtav1. The original library is never an Unmanic library.

Generate the encoder with
`larenor-unmanic-callback-package --kind encoder --output <new-encoder.zip>`.
Its private config, selected by `LARENOR_UNMANIC_ENCODER_CONFIG`, has exactly
`schemaVersion: 1`, `workRoot`, `cacheRoot`, `keyFile`, `ffmpeg`. Config/key are
0600, work/cache roots 0700. The callback key is shared for domain-separated
authentication. Set both plugin configuration variables before Unmanic starts.
Use an application-specific `HOME_DIR`; Unmanic's PluginExecutor loads plugins
from `$HOME_DIR/.unmanic/plugins` even when `plugins_path` is configured.

The upstream-created cache task directory may not exist when its runner is
called. Existing ancestors are validated without creating the directory. The
provider's 0644 output is sealed to 0600 through an owned, unlinked, no-follow
descriptor only after exact content verification in the private work directory.
Group/world-writable, hardlinked or changed output is rejected. Signed failed
events with no destination are durably delivered and terminate as failed.

Actual acceptance uses PyPI `unmanic==0.4.1`, reporting `0.4.1~1c324b8`, pinned
to [upstream revision 1c324b8](https://github.com/Unmanic/unmanic/tree/1c324b8fc3974ffce3d7cc945adb938fe7182910).
Its [worker runner](https://github.com/Unmanic/unmanic/blob/1c324b8fc3974ffce3d7cc945adb938fe7182910/unmanic/libs/unplugins/plugin_types/worker/process.py)
and actual plugin installer/process were exercised, rather than replacing them
with an in-process adapter. The opt-in pytest uses only disposable local
configuration, media, HTTP listeners and files. Real home media is untouched.

Run `LARENOR_UNMANIC_041_EXECUTABLE=<absolute-unmanic> uv run --project server
pytest server/tests/test_media_archive_unmanic_041_acceptance.py -q`.
The real process encoded video, emitted the authenticated callback, passed real
FFmpeg verification including audio/subtitles, atomically installed a smaller
HEVC output and retained the verified original. The initial focused package
passed 39 tests including this actual-provider case. Full Client→Core→worker
deployment, duplicate/retention cleanup and required CI remain separate gates;
this evidence does not by itself close F30 or FINAL.FUNCTION.
