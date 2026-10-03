# F62 owned RDP full-screen route evidence (2026-10-01)

## Production composition

The connected RDP panel requests a transient `WindowPolicyBridge` full-screen
lease for the exact current internal-display incarnation. The request captures
the panel generation, connected controller/session revision, profile,
`ProviderContainer`, current `ModalRoute`, display identity and bridge owner.
A late grant is released without being rendered if any captured owner changed.

An accepted lease reparents the existing `_RdpInputSurfaceState` into the root
overlay. It does not create a second framebuffer subscriber or ACK path: the
same decoded image, admitted frame tuple, focus and input state move between the
inline 480-point surface and the larger window-sized surface. Exit, Escape,
session error/closure, controller replacement, route/interaction retirement,
foreground/display drift and disposal remove the overlay and release only the
exact native lease revision. The saved adaptive/panel preference is untouched.

The overlay has a localized, visible 48-point exit control and a named route
semantics container. Escape is consumed for both key down and the following key
up so exiting cannot inject an unmatched Escape event into the remote desktop.
Native denial is shown as a bounded localized failure while the RDP session
remains connected.

The surface installs a decoded frame only after the exact native frame ACK
returns true. Absolute pointer and vertical-wheel packets carry the geometry of
that displayed frame; a later rejected or stale frame cannot replace it. Display
resize requests compare the complete pixel and protocol-scale tuple, so a DPR
change at the same logical size is not silently ignored. The UI reports the
desktop and device scale percentages and does not describe either as measured
DPI.

## Focused verification

The production panel tests cover:

- exact acquisition and release arguments without a `setProfile` write;
- one framebuffer listener through inline-to-overlay-to-inline reparenting;
- ACK-before-display, exact displayed-frame input geometry and bounded wheel
  steps;
- a larger real surface, localized 48-point exit semantics and Escape exit;
- explicit denial without a fabricated hidden-bars claim;
- late-grant release after route/interaction ownership retirement; and
- existing display, session, frame ACK, pointer and clipboard retirement gates.

The frozen v2 contract was verified with:

```text
flutter gen-l10n
flutter test test/features/remote_access/rdp/rdp_session_panel_test.dart test/features/remote_access/rdp/rdp_display_geometry_test.dart test/features/remote_access/rdp/rdp_models_test.dart
41 passed, 0 failed, 0 skipped

flutter analyze lib/features/remote_access/rdp/rdp_session_panel.dart test/features/remote_access/rdp/rdp_session_panel_test.dart test/features/remote_access/rdp/rdp_display_geometry_test.dart test/features/remote_access/rdp/rdp_models_test.dart
No issues found
```

Private logs: `/private/tmp/larenor-f62-fullscreen-focused-final.log` and
`/private/tmp/larenor-f62-fullscreen-analyze.log`.

## Platform boundary

Android documents immersive mode as a request through
`WindowInsetsControllerCompat.hide()` and requires system gestures to remain
available for transient bar access. It also notes that desktop window captions
remain visible and require separate handling. The lease therefore rejects
desktop/caption/multi-window/PiP/external-display conditions and uses transient
bars-by-swipe behavior; an accepted request is not presented as proof that the
bars are currently hidden. See [Android immersive
mode](https://developer.android.com/develop/ui/views/layout/immersive).

Apple guidance likewise treats full screen as a focused content presentation,
so the Cupertino UI keeps an obvious exit instead of hiding navigation without
a recovery control. See [Apple going full
screen](https://developer.apple.com/design/human-interface-guidelines/going-full-screen).

This slice proves local route/window ownership with mocked MethodChannel
receipts. Physical system-bar visibility, DeX behavior, real keyboard Escape,
and provider-host rendering remain separate Android/device or hosted gates.
