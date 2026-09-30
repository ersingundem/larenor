# Embedded Moonlight Android engine notices

Larenor's embedded game-stream engine is a source transformation of
Moonlight Android 12.2. The exact upstream and recursive submodule commits,
source trees, licenses, reviewed files, build toolchain, and local patch digest
are recorded in `source-lock.json`.

- Moonlight Android, Copyright Moonlight contributors, GPL-3.0-only:
  <https://github.com/moonlight-stream/moonlight-android>
- moonlight-common-c, Copyright Moonlight contributors, GPL-3.0-only:
  <https://github.com/moonlight-stream/moonlight-common-c>
- ENet, Copyright Lee Salzman, MIT:
  <https://github.com/cgutman/enet>
- nanors, Copyright Joseph Calderon, MIT:
  <https://github.com/sleepybishop/nanors>
- OpenSSL libcrypto 4.0.2, Copyright OpenSSL contributors, Apache-2.0:
  <https://github.com/openssl/openssl>
- libopus, Copyright Xiph.Org Foundation contributors, BSD-3-Clause:
  <https://gitlab.xiph.org/xiph/opus>

The pinned Moonlight source tree carries prebuilt OpenSSL and libopus static
archives rather than submodules. Their arm64-v8a and x86_64 archive digests are
therefore recorded separately in `bundledNativeArchives`. OpenSSL reports
4.0.2 in its pinned header and binary. The pinned libopus archive reports its
version as unknown, so this package does not invent a version or source commit;
its exact upstream-tree path and SHA-256 remain part of the source lock.

The transformation changes the Android module from an independently launched
application to a private Android library. It retains the upstream pairing,
certificate/key handling, computer database, MediaCodec video, audio,
controller/input, stream protocol, resources, and native engine. It removes
the standalone launcher intent and exported Moonlight entry points so the
Larenor application remains the sole authenticated product surface.
The patch also adds a protected causal-stop hook immediately after the actual
`NvConnection.stop()` call returns. This is necessary because the pinned
moonlight-common-c intentionally suppresses `connectionTerminated` for a local
`LiStopConnection`; the hook does not treat Activity destruction as a stop.
The patch also forwards two bounded, data-free output observations to the
embedding activity: Android's `MediaCodec.OnFrameRenderedListener` callback
after a frame is rendered on the output surface, and a full positive return
from the blocking PCM `AudioTrack.write()` call. It does not retain pixels or
audio samples, and it does not present submitted decoder buffers, dropped
audio, or Activity lifecycle as rendered/accepted output.

Android defines `OnFrameRenderedListener` as notification that an output frame
rendered on the surface, while noting that callbacks may be delayed, batched,
or omitted. Android defines `AudioTrack.write()` as returning the positive
amount actually written, with zero/negative values and short transfers possible
when playback cannot accept the complete request:

- <https://developer.android.com/reference/android/media/MediaCodec#setOnFrameRenderedListener(android.media.MediaCodec.OnFrameRenderedListener,%20android.os.Handler)>
- <https://developer.android.com/reference/android/media/AudioTrack#write(short[],%20int,%20int,%20int)>

The complete corresponding source is the exact recursive checkout named by
`source-lock.json`, plus `patches/0001-embed-library.patch`. The packaging tool
can verify that checkout and produce a source archive containing those sources,
the lock, patch, and this notice. Binaries must be distributed with that source
archive and the applicable license texts.
