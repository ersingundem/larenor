# F62 fit, fill and native rendering evidence (2026-10-01)

## Scope

The RDP panel now derives rendering and pointer input from the same actual
decoded-frame and viewport geometry:

- **Fit window** preserves the frame aspect ratio, contains the complete frame,
  and rejects pointer input in letterbox or pillarbox regions.
- **Fill window** preserves the frame aspect ratio, covers the viewport, and
  includes the cropped frame offset in inverse pointer coordinates.
- **Native resolution** uses the current device pixel ratio so one decoded
  remote pixel occupies one local physical display pixel, clips the resulting
  logical canvas to the viewport, and suppresses automatic DISP resize
  requests. A separate 48-point, localized and accessible control explicitly
  switches between remote pointer input and local canvas panning. Local panning
  never forwards pointer events to the remote session.

The previously persisted `fixed` value did not have a distinct renderer. It is
migrated to `fitWindow`; the client does not advertise a fixed-resolution mode.
Mode changes and controller replacement reset native pan state. A queued resize
callback is also bound to the exact controller and display mode that scheduled
it, so switching to native mode cannot apply an older automatic DISP request.
Pointer admission is equally bounded: a new press in a letterbox is rejected,
while an admitted press that later leaves the image still emits a zero-button
release at its last valid remote coordinate. Enabling local native panning also
releases an admitted remote press before suppressing its remaining events.

## Focused verification

The focused Dart tests cover:

- contain, cover and device-pixel-ratio-aware native one-to-one geometry,
  inverse coordinate mapping, native pan clamping, and invalid dimensions;
- persisted legacy `fixed` migration and `fillWindow` round-trip;
- actual decoded-frame rendering in the production panel, fit letterbox input
  rejection, fill crop-aware mapping, explicit native pan isolation, frame ACK,
  keyboard input and DISP suppression.

Commands and final counts are recorded after the frozen source gate:

```text
flutter test test/features/remote_access/rdp/rdp_display_geometry_test.dart test/features/remote_access/rdp/rdp_profile_settings_test.dart test/features/remote_access/rdp/rdp_session_panel_test.dart
flutter analyze lib/features/remote_access/rdp/rdp_models.dart lib/features/remote_access/rdp/rdp_session_panel.dart lib/features/remote_access/rdp/rdp_display_geometry.dart test/features/remote_access/rdp/rdp_display_geometry_test.dart test/features/remote_access/rdp/rdp_profile_settings_test.dart test/features/remote_access/rdp/rdp_session_panel_test.dart
```

Result: **30 passed, 0 failed, 0 skipped**; scoped analysis reported **no
issues**. `flutter gen-l10n` completed before the gate and the generated
English and Turkish localization implementations match the ARB inputs.

## Acceptance boundary

This is a Flutter framebuffer rendering and coordinate-transform proof. It does
not claim fullscreen/window-policy acquisition, relative-pointer transport,
remote density negotiation, physical display acceptance, or a hardware/device
rendering result. Those remain separate native, hosted, or manual gates. Native
mode prevents automatic DISP resize; it does not claim that the remote desktop
already matches the local display density. The existing automatic DISP resize
deduplication is viewport-size based: a device-pixel-ratio change with an
unchanged logical viewport is not yet an independently triggered DISP update.
