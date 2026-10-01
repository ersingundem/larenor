# F62 RDP Client capability truth — 2026-10-01

## Contract boundary

The version 1 native capability response keeps the existing `channels.clipboard`, `channels.audio`, and `channels.files` fields and adds `channels.clipboardModes`. The mode list is ordered, contains only `disabled`, `clientToRemote`, and `bidirectional`, and must not contain duplicates. `channels.clipboard` is true exactly when the list contains a non-disabled mode.

The packaged FreeRDP runtime currently reports `ime: false` and clipboard modes `disabled` and `clientToRemote`. Remote-to-device clipboard delivery and IME Unicode entry are not presented as available. A legacy three-field channel response with `clipboard: true` is accepted only as `clientToRemote`; it never creates a bidirectional claim.

## Client behavior

- A session request is rejected before native open when its saved clipboard mode is absent from the current capability set. The boolean channel request and selected mode must agree.
- Unsupported modes are hidden. A persisted legacy bidirectional value remains visible but disabled after capabilities are read, with an EN/TR instruction to choose Off or a supported one-way mode and save. The stored value is never silently rewritten.
- The IME field is rendered only when the native capability is true. The packaged `ime: false` response therefore exposes no text-send control and sends no native text event.
- Connect requires a loaded `WindowPolicySnapshot` with an exact logical
  `displayId` and process-local `displayRevision`. Android increments the
  revision on public `DisplayManager.DisplayListener` add/remove lifecycle
  callbacks; raw display names or hardware identifiers never cross the method
  channel. The exact tuple is read again around settings I/O. If either field
  changes, the old controller and channel are disposed and no connection is
  replayed. The user must explicitly connect again. Repeated snapshots for the
  same tuple do not recreate or disconnect the active session. A legacy packet
  without the tuple remains parseable for other window-policy consumers, but
  RDP connection fails closed.

## Evidence

Focused RDP coverage verifies strict ordered modes, conservative legacy
parsing, request rejection, unavailable IME controls, explicit legacy
correction, external-display classification retirement without replay, the
certificate-only probe boundary, and mandatory Client NLA policy:

```text
flutter test test/features/remote_access/rdp
38 passed

flutter analyze lib/features/remote_access/rdp/rdp_engine.dart lib/features/remote_access/rdp/rdp_models.dart lib/features/remote_access/rdp/rdp_session_controller.dart lib/features/remote_access/rdp/rdp_session_panel.dart test/features/remote_access/rdp/rdp_method_channel_engine_test.dart test/features/remote_access/rdp/rdp_models_test.dart test/features/remote_access/rdp/rdp_session_controller_test.dart test/features/remote_access/rdp/rdp_session_panel_test.dart
No issues found

flutter test test/core/window/window_policy_test.dart test/features/remote_access/rdp/rdp_session_panel_test.dart
18 passed

flutter analyze lib/core/window/window_policy_models.dart lib/core/window/window_policy_bridge.dart lib/features/remote_access/rdp/rdp_session_panel.dart test/core/window/window_policy_test.dart test/features/remote_access/rdp/rdp_session_panel_test.dart
No issues found

JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testDebugUnitTest --tests com.ersingundem.larenor.window.WindowPolicyTest --tests com.ersingundem.larenor.window.WindowPolicyBridgeTest
13 passed; 0 failures, errors, or skipped
```

The coupled Kotlin capability producer and packaged-host acceptance remain separate native evidence. This Client gate does not establish remote clipboard reception, IME negotiation, physical DeX hotplug behavior, or a successful connection to a household RDP host. It proves software fencing when Android reports a different logical display ID or an observed remove/add lifecycle reuses an ID. Android's public `Display` API does not expose a physical-device unique ID to applications, so an ID reuse without a delivered add/remove callback is not claimed as detected.

Primary Android contracts:

- `Display.getDisplayId()` identifies a logical display; Android notes that a
  logical display need not represent one physical device:
  <https://developer.android.com/reference/android/view/Display#getDisplayId()>
- `DisplayManager.DisplayListener` reports logical displays being added,
  changed, and removed:
  <https://developer.android.com/reference/android/hardware/display/DisplayManager.DisplayListener>
- `Display.isValid()` becomes false after removal even though other getters can
  retain the last observed values; an invalid display therefore produces no
  current tuple or known-display claim:
  <https://developer.android.com/reference/android/view/Display#isValid()>

## Certificate probe and authenticated connection boundary

The v1 `inspect` MethodChannel shape remains compatible, but its Client model is
`RdpCertificateProbe`. `tlsCertificateObserved` means the certificate callback
was reached on the locally enforced TLS 1.2 probe. `clientRequiresNla` is the
fixed Client connection policy. The deliberately credential-free probe does not
claim an authenticated peer or a server-selected authentication mode.

The controller requires packaged NLA capability before probing and always
requires an NLA credential before opening. A certificate probe can only reach
the explicit pin-review state; it cannot publish a connected session. The
native `open` result remains the authenticated boundary because it completes
only after the exact pin has matched and FreeRDP's successful-connection
callback has passed the NLA/TLS gate. User copy describes certificate retrieval
and a connection-level NLA requirement rather than peer discovery.

Root independently verified the final native XML totals: WindowPolicyTest10 and WindowPolicyBridgeTest3, with zero failures/errors/skips. A broader `flutter test test/core/window test/features/remote_access/rdp --reporter json` run passed49 real test cases with zero skipped/failed. The private runner log is not published. This software slice remains separate from a hosted RDP/channel or physical display acceptance receipt.
