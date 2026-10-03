# F60 nonzero PCM witness package — 2026-10-03

## Corrected observation boundary

The embed-v3 hook reported every complete positive `AudioTrack.write()` to the
private game activity. That return value proves that Android accepted the
decoded buffer, but it does not distinguish a generated tone from an all-zero
buffer. Sunshine's Linux capture path forwards every successful PulseAudio
capture buffer to Opus, while PulseAudio may supply silence for an idle sink.
The old one-count witness could therefore be satisfied before the owned tone.

Embed-v4 adds an ordered second patch. After a complete positive write, the
renderer performs one finite scan of the decoded `short[]` and sends only
counts plus `containsNonZeroPcm` to `Game`. No PCM samples, values, provider
addresses, or credentials cross the hook. The exact public API is:

```text
com.limelight.Game.onAudioPcmWritten(int,int,boolean)  (IIZ)V
```

The consumer counts only a complete write whose boolean is true. An all-zero
write remains a valid renderer operation but is not causal audio-output
evidence.

Primary source boundaries:

- Moonlight Android 12.2 renderer:
  <https://raw.githubusercontent.com/moonlight-stream/moonlight-android/b48494cb96bff23d8886c4775cc4f39a1075495d/app/src/main/java/com/limelight/binding/audio/AndroidAudioRenderer.java>
- Sunshine Linux PulseAudio capture:
  <https://raw.githubusercontent.com/LizardByte/Sunshine/v2026.914.233613/src/platform/linux/audio.cpp>
- Sunshine audio encode loop:
  <https://raw.githubusercontent.com/LizardByte/Sunshine/v2026.914.233613/src/audio.cpp>
- PulseAudio simple API semantics:
  <https://www.freedesktop.org/software/pulseaudio/doxygen/simple.html>

## Immutable package identity

- upstream commit: `b48494cb96bff23d8886c4775cc4f39a1075495d`
- engine revision: `moonlight-android-12.2-larenor-embed-v4`
- first patch SHA-256: `85bfb0080400eff2bc05392b4ea1c05b2b72dc152cafea9716008ae2dd222e0d`
- nonzero PCM patch SHA-256: `95c7e95ca9f4087e029459e00856868d9a22fe2a265c3de32715b67ac5b462ca`
- AAR SHA-256: `e9bccd49d938284ebace46238073fad0018bb6e8a060748234c953ffe40176d8`
- classes SHA-256: `ed2b16ef3ba2081d9b484382c419d9c0e4d7cd26053cb44cff0afb35abebef4b`
- receipt SHA-256: `c0c28531b5b6a97d6aa48fb3c806e45b97e623fd719f8a676d200e26275ad394`
- source archive SHA-256: `cc044e9a9abac60705ece53d35d49f402507f284f7e468de238368366d3c2c8c`

The receipt binds the ordered two-patch chain, both `arm64-v8a` and `x86_64`,
and the compiled `(IIZ)V` descriptor. A complete-write-only `(II)V` AAR and an
embed-v3 receipt fail closed.

## Verification

The focused package suite passed **11 tests** with no failures or errors. It
checks the exact engine contract, patch order and digests, finite nonzero scan,
compiled descriptor, stale hook rejection, both ABI payloads, receipt tamper,
install, and APK binding. Python compilation, lock verification, pristine
source verification, ordered patch preparation, and install verification also
passed.

The private source-locked build used Java 17, Gradle 9.7.1, NDK
29.0.14206865, one worker, and a 4 GiB heap. It completed **33 tasks** with
`BUILD SUCCESSFUL` in 1m13s. Private artifacts are under
`/private/tmp/larenor-f60-nonzero-v4-build.YqoXvJ/`; the directory is mode
0700 and files are mode 0600.

This package proves source identity, finite classification, compiled API, and
binary integrity. A nonzero write is stronger than silence, but it is not a
sound-pressure, perceptual-quality, or loudspeaker proof. The owned Sunshine
acceptance must inject and observe a separate causal tone for each required
stream lifetime; embed-v4 intentionally prevents ambient silence from filling
that gap.
