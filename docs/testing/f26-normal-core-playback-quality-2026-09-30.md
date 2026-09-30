# F26 normal playback-quality acceptance

Date: 2026-09-30

This gate replaces the earlier shadow HTTP Core test with a production Flutter
Client call to a normal Core TCP listener. The only external double is an owned
Jellyfin-shaped HTTP server. It returns one bounded playback negotiation and
does not start playback, contact a household server or claim physical receiver
acceptance.

## Upstream meaning and limits

Jellyfin documents that the client sends its capabilities and bitrate limits,
then the server selects direct play, remux/direct stream or transcode. Its
official generated SDK exposes the posted PlaybackInfo request, including
`DeviceProfile` and `MaxStreamingBitrate`. These are negotiation facts, not a
measurement that a physical decoder, display or network can sustain the
result:

- [Jellyfin transcoding and playback methods](https://jellyfin.org/docs/general/post-install/transcoding/)
- [Jellyfin codec support](https://jellyfin.org/docs/general/clients/codec-support/)
- [Jellyfin PlaybackInfo request](https://typescript-sdk.jellyfin.org/interfaces/generated-client.MediaInfoApiGetPostedPlaybackInfoRequest.html)

The fixture accepts exactly one authenticated
`POST /Items/movie-1/PlaybackInfo`. Production `JellyfinClient` parses its
source codec, 25 Mbps bitrate, 4K HDR10 shape and server transcode reasons. The
Android channel DTO is parsed through the production bounded snapshot contract
with reported HEVC/E-AC-3, display and link-capability values. No value is
upgraded to verified evidence.

`CorePlaybackQualityRequestAdapter` then creates the actual schema-v1 request.
`CorePlaybackQualityController`, a real account session and normal Core return
reported transcode advice, a conservative 14 Mbps ceiling, and manual physical
acceptance. Retiring the route clears the advice and suppresses another call.
F26 is advisory only; it does not change player quality or issue a Jellyfin
play command.

## Contract repair

Core's response schema permits at most 6 gaps, 12 reasons and 7
recommendations. Flutter previously accepted 16, 16 and 8, respectively. The
parser now mirrors the server limits and a hostile eight-recommendation reply
is rejected as `invalid_response`.

## Evidence

```text
cd server
uv run python tests/support/f26_flutter_acceptance.py
1 passed; exact Jellyfin negotiation call count: 1

uv run pytest -q tests/test_f26_playback_quality_api.py
4 passed

cd ..
flutter test --no-pub \
  test/features/media/playback_quality/core_playback_quality_loopback_test.dart \
  test/features/media/playback_quality/core_playback_quality_normal_core_test.dart
3 passed, 1 environment-gated test skipped

flutter analyze --no-pub lib/features/media/playback_quality \
  test/features/media/playback_quality/core_playback_quality_loopback_test.dart \
  test/features/media/playback_quality/core_playback_quality_normal_core_test.dart
No issues found

cd android
./gradlew :app:testDebugUnitTest \
  --tests 'com.ersingundem.larenor.playbackquality.AndroidPlaybackCapabilityBridgeTest'
BUILD SUCCESSFUL
```

The Android bridge's existing focused JVM test remains part of this gate. Real
decoder availability, HDR presentation, sustained bandwidth, thermal behavior
and a household Jellyfin account remain explicit physical/manual evidence.
