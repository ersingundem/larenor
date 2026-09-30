# PRODUCT.CAMERA software acceptance — 2026-09-30

## Supported production boundary

The personal-camera feature is a local Android foreground surface. The user
must open it from the kiosk settings surface and explicitly open the front
camera. `PersonalCameraBridge` binds CameraX preview and optional analysis to
the activity lifecycle, keeps frames out of Dart and storage, and closes the
session on route retirement, focus loss, background, thermal pressure, low
battery, or engine disposal. Enrollment retains only one AES-GCM encrypted
geometric template under Android Keystore. Matching is personalization only;
it grants no account, administration, health, door, or automation authority.

The detector is the bundled `com.google.mlkit:face-detection:16.1.7` artifact.
Google's official Android guide distinguishes the bundled model from the Play
services downloaded model and recommends `STRATEGY_KEEP_ONLY_LATEST` plus
closing every `ImageProxy`, which the bridge uses:
<https://developers.google.com/ml-kit/vision/face-detection/android>.
CameraX officially uses lifecycle binding to open and close capture sessions:
<https://developer.android.com/media/camera/camerax/architecture>.

Larenor's Home Assistant camera cards are a separate authenticated read-only
boundary. They request only `GET /api/camera_proxy/<camera entity_id>`, the
official REST snapshot endpoint, and stop polling when hidden or backgrounded:
<https://developers.home-assistant.io/docs/api/rest/>. An owned loopback TCP
fixture verifies the exact path and bearer header without a household camera.

ONVIF credentials and RTSP transport remain owned by Home Assistant. Larenor
consumes the resulting `camera.*` entity and does not collect direct ONVIF
credentials. Home Assistant documents that its ONVIF integration exposes H.264
profiles as camera entities and requires its FFmpeg integration:
<https://www.home-assistant.io/integrations/onvif/>.

Larenor currently renders authenticated snapshots. It does **not** claim a
direct ONVIF, WebRTC, HLS, RTSP, two-way audio, microphone, recording, or PTZ
transport. Home Assistant documents HLS and native WebRTC as optional camera
stream capabilities, distinct from still images:
<https://developers.home-assistant.io/docs/core/entity/camera>. Those live
transport modes therefore remain outside this software acceptance rather than
being represented by a dummy or fake-success path.

## Defects closed in this review

- A profile-delete confirmation captured before interaction retirement could
  delete the local encrypted template after the route or app authority was no
  longer current. The screen now checks current route, window, interaction,
  and profile identity before opening confirmation, immediately before native
  mutation, and after I/O before publishing success.
- Profile deletion now owns one explicit `CupertinoDialogRoute`. A captured
  callback cannot pop a foreign route placed above that dialog, and deletion
  starts only after the owned dialog's reverse transition has completed and
  the originating camera route is current again.
- Cancelling the route-owned event listener previously removed only the Dart
  listener. If the exact close response was lost, the native preview could
  remain active until an activity lifecycle transition. Native event-channel
  cancellation now cancels pending permission and releases preview/analysis;
  exact close is idempotent only for the most recently released session ID.

## Focused evidence

```text
flutter test --no-pub \
  test/features/personal_camera/personal_camera_test.dart \
  test/features/personal_camera/product_camera_provider_boundary_test.dart \
  test/shared/widgets/camera_snapshot_test.dart \
  test/features/intercom/intercom_screen_test.dart
```

Root independently ran this focused command: **30 passed, zero skipped**.
Targeted analysis completed with no issues. The unchanged native bridge had
already passed the normal Android `compileDebugKotlin` gate.

The personal-camera tests cover late-open retirement, failed-close fencing,
event-listener retirement, exact MethodChannel shape, and deletion authority
expiry, exact dialog ownership against a foreign covering route, and one
successful deletion after transition completion. The loopback fixture uses a
real local TCP server and verifies an authenticated Home Assistant snapshot
request. Existing snapshot tests cover entity replacement,
hidden-tab/background retirement, serialized polling, and stale-frame
labeling. Existing intercom tests cover commissioned entity selection,
current-route controls, and the separate guarded door-release path.

The targeted Android compile gate covers the production CameraX/ML Kit bridge
in the normal application build. No frame, token, template vector, household
camera address, or household action is printed by these gates.

## Manual boundary

Physical front-camera permission and focus behavior, camera-busy coexistence,
thermal and battery callbacks, detector latency/accuracy, Keystore behavior,
Huawei MatePad and Samsung DeX, real ONVIF snapshots, and any provider-specific
live stream remain manual. The queue must not treat these software tests as
physical-device, biometric-security, live WebRTC/HLS, or household-camera
proof.
