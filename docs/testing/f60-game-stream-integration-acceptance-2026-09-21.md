# F60 game streaming integration acceptance

Status: **software contract complete; physical host/device acceptance remains manual**.

Progress remains **22/125 selected features** and **0/63 fully accepted features**.
This package does not count F60 as accepted until a real Sunshine-compatible
host, GPU/video path, controller/keyboard/audio path, Huawei tablet, and DeX
display pass the physical matrix.

## Three software acceptance criteria

1. **Core owns the host and session authority.** Authenticated Core routes expose
   only bounded host capabilities, never the credential handle. A session binds
   the exact account, Core/home, host/pairing, route, lifecycle, display, network,
   and policy revisions. Storage is durable and HMAC protected; another login
   family, changed revision, expired lease, or modified row fails closed.
2. **The Android tablet owns one current effect.** The Client parses the Core
   host/session/command receipts with a closed schema and cancels a late HTTP
   response after route/account retirement. The existing personal session and
   Kotlin MethodChannel bind the same account/route/lifecycle/idle revisions,
   accept an opaque local credential handle, and never automatically replay an
   ambiguous or lost command result.
3. **The low-latency request is bounded and protected.** Each native command now
   includes the exact protected display dimensions, frame rate, bitrate, and
   maximum frame/input queue depths. Kotlin rejects an insecure surface or an
   out-of-range profile before an engine call, includes the quality profile in
   idempotency identity, and accepts only an exact engine readback.

## Automated evidence

- `server/tests/test_f60_game_stream_authority.py`
- `test/features/game_streaming/core_game_stream_api_test.dart`
- `test/features/game_streaming/game_stream_session_test.dart`
- `test/features/game_streaming/android_game_stream_port_test.dart`
- `test/features/game_streaming/game_stream_personal_session_test.dart`
- `test/features/game_streaming/game_stream_settings_screen_test.dart`
- `android/app/src/test/kotlin/com/ersingundem/larenor/game/GameStreamNativeAdapterTest.kt`

## Manual gates

- Pair and stream from an isolated real Sunshine/Moonlight fixture without
  placing its address, PIN, key, or token in CI.
- Verify video, audio, controller, keyboard/IME, suspend/resume, Wi-Fi loss,
  display detach, and lost acknowledgement on supported Android hardware.
- Verify Huawei MatePad and DeX window/display changes at 600 and 1280 logical
  pixels, including protected-surface recreation and touch/controller mapping.
