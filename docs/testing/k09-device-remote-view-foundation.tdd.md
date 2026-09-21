# K09 device information and controlled remote-view foundation

Status: **foundation ready; K09 remains pending**

Source: `K09 — Cihaz bilgisi ve kontrollü uzaktan görünüm` in
`docs/execution-queue.json`. K07 is still pending, so this slice provides the
local authority and port contract without a listener, network route, Android
MediaProjection engine, or queue-progress claim.

## Three acceptance criteria

1. **Bounded read-only device state.** A strict v1 snapshot accepts only the
   expected device and policy revisions plus a fresh monotonic sample. Battery,
   charging, coarse network class, app version/build, process memory and uptime
   are bounded. Extra keys, SSID/IP-like network values, stale samples and
   impossible resource values fail closed. Public projection omits Core, home,
   account and device identifiers.
2. **App view and device projection stay distinct.** `appSurface` needs no
   MediaProjection grant. `fullDeviceProjection` additionally needs a current,
   revision-bound system consent. Both modes require the exact Core/home/
   account/device/policy/session/route/lifecycle authority, a visible foreground
   interaction, and an ordinary screen. PIN, credential, secret and unknown
   screens are denied before the port is called.
3. **Observed start and bounded retirement.** Every request has a 30-second
   preview/confirmation window. Start/readback/stop use a capability-gated port
   and bounded timeouts. Concurrent confirmation, stale callbacks, invalid
   receipts and lost acknowledgement never replay. Authority or system-consent
   loss retires the local session and attempts one stop; a lost stop remains
   `unconfirmed` and cannot be reported active. Public receipts omit native
   handles.

## TDD evidence

| Stage | Command | Result |
| --- | --- | --- |
| RED | `flutter test test/features/kiosk/kiosk_remote_view_foundation_test.dart` before production code | Expected compile failure because the K09 contract did not exist; checkpoint `6a44a428` |
| GREEN | `flutter test test/features/kiosk/kiosk_remote_view_foundation_test.dart --coverage` | 4/4 tests passed; checkpoint `d2a6dd4d` |
| Coverage | Focused LCOV entry for `kiosk_remote_view.dart` | 210/248 lines, **84.7%** |
| Static analysis | Focused `flutter analyze` | 0 issues |

The focused tests cover strict telemetry parsing and redaction, stale samples,
mode separation, missing consent, sensitive routes, exact revision drift,
concurrent start, stale-start compensation, preview expiry, consent loss,
lost stop acknowledgement, and receipt redaction.

## Dependent and manual boundary

K07 must provide authenticated remote read/control scopes before this state can
leave the tablet. A later Android adapter must collect the bounded metrics and
implement app-surface rendering and MediaProjection with Android's per-session
system consent and foreground-service rules. Process death, system consent
revocation, PIN/credential route classification, Huawei WebView, DeX and real
capture/stop behavior remain **MANUAL**. Progress remains **22/125** and
**0/63**; complete K09 acceptance is not claimed.
