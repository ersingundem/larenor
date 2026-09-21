# F43 camera recording profile Core and Android integration

This slice connects the existing presence policy engine to an authenticated,
provider-backed Core boundary and a discoverable Android tablet surface. It is
an integration contract, not evidence that a physical camera, microphone, NVR,
or vendor account was changed.

## Three acceptance criteria

1. **Provider capability and exact readback.** Core exposes the current policy,
   presence signal, camera state, provider capability revision and desired state
   under the authenticated Core/home/admin session. Apply revalidates the exact
   authority, policy, signal, scope, state and capability snapshot before one
   dispatch. Success requires a newer matching provider readback. Reusing the
   request ID returns the stored process receipt and never dispatches again.
2. **Partial and ambiguous results stay visible.** Unsupported recording or
   detection changes are rejected per camera without calling the worker. Mixed
   applied, unsupported, failed and lost-ack results retain their per-camera
   codes and aggregate as partial. The Android controller preserves the receipt,
   rejects stale account/session/route/lifecycle callbacks and never retries an
   ambiguous command automatically.
3. **The tablet makes no false privacy claim.** The settings route shows current
   and requested recording/detection state plus provider support in EN/TR at
   600/1280 widths and 2x text, with 48dp, keyboard and TalkBack-compatible
   controls. Both Core and Client contracts fix microphone, camera hardware and
   other-recorder claims to false; a server response claiming otherwise is
   rejected.

## Verification

- `server/tests/test_f43_camera_recording_profile.py`
- `server/tests/test_f43_camera_profile_http.py`
- `test/features/camera_profiles/camera_profile_http_api_test.dart`
- `test/features/camera_profiles/camera_profile_client_test.dart`
- `test/features/settings/settings_split_screen_test.dart`
- `test/features/settings/settings_accessibility_test.dart`
- Targeted Flutter analyze, Python compile, security policy, queue validation,
  progress validation, diff check and redacted gitleaks.

## Open gates

The runtime deliberately requires a packaged provider implementation. Home
Assistant/vendor capability mapping, durable receipt recovery across a Core
restart, physical camera/NVR readback, microphone or hardware shutter proof and
Huawei/DeX device acceptance remain open. Therefore F43 stays pending and the
progress counters remain **22/125** and **0/63**.
