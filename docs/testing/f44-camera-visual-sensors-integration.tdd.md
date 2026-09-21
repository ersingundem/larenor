# F44 camera visual sensor integration slice

Status: **software integration slice delivered; F44 remains pending**

This slice extends the existing in-memory visual sensor foundation. It does not
add a frame-ingestion endpoint or let an administrator manufacture detector
results. Until an isolated detector worker supplies a trusted complete frame,
the authenticated summary remains explicitly `unknown` and `unavailable`.

## Three acceptance criteria

1. **Durable, authenticated rule state.** An administrator can create or
   revision-update at most 64 exact Core/home camera rules. The marker-backed
   store survives restart, authenticates every row with HMAC, and rejects stale
   revisions, foreign scope, changed storage or invalid labels fail closed.
2. **No-frame and bad-frame safety.** Missing, corrupt and wrong-camera frames
   must be degraded and contain no detections. They produce only an `unknown`
   non-automation reading. The public summary cannot claim access-control or
   automation authority and no public detector-ingestion route exists.
3. **Visible capability and tablet uncertainty.** The authenticated summary
   reports architecture plus AVX, AVX2 and ARM64 applicability explicitly while
   reporting the absent detector worker as unavailable. The Android Settings
   route shows that uncertainty in English and Turkish at 600/1280 widths with
   2x text, a 48dp keyboard action and TalkBack semantics; account, route, PIN
   or lifecycle changes retire late results.

## Focused evidence

| Guarantee | Test | Result |
| --- | --- | --- |
| Revisioned HMAC persistence, restart, scope and tamper rejection | `server/tests/test_f44_camera_visual_sensor_http.py` | 2 scenarios pass |
| Exact authority, replay, hysteresis, privacy and incomplete/wrong-frame rejection | `server/tests/test_f44_camera_visual_sensors.py` | 7 scenarios pass |
| Strict authenticated response projection and stale callback rejection | `test/features/camera_visual_sensors/camera_visual_sensor_api_test.dart` | 3 scenarios pass |
| EN/TR tablet layout, explicit uncertainty, 48dp keyboard/TalkBack and Settings discovery | `camera_visual_sensor_screen_test.dart`, `camera_visual_sensor_route_test.dart` | 10 scenarios pass |

## Manual and follow-up gates

Real Frigate or custom-classifier worker isolation, model licensing, training or
inference, AVX/AVX2 performance, ARM64 model support, physical camera frame
correctness and Home Assistant entity projection remain manual or later work.
F43 is still a queue dependency. Software progress therefore stays at **22/125**
and feature progress at **0/63**.
