# K08 constrained web-to-native bridge foundation

Status: **foundation ready; K08 remains pending**

Source: `K08 — Sınırlı web→native köprü` in `docs/execution-queue.json`.
The queue dependencies `K03.remaining` and `K07` remain pending, so this slice
adds no WebView JavaScript channel and does not advance queue progress.

## Three acceptance criteria

1. **Strict typed envelope.** The bridge accepts only schema v1, a monotonic
   sequence, bounded opaque request/grant identifiers, and the allowlisted
   `speak`, `printDocument`, and `scanQr` methods. Method-specific payload keys,
   text length, locale, document handle, QR formats, and total message size are
   bounded. Unknown versions, methods, fields and values fail closed.
2. **Exact frame and session authority.** A fresh 30-second user grant binds one
   method to exact Core, home, account, session-family, panel source, source and
   policy revisions, route/lifecycle epochs, and HTTPS top origin. Trusted
   native metadata must also report a foreground visible main frame and no new
   window. Foreign iframe/origin, HTTP downgrade, stale binding, revocation and
   expired grants cannot produce a preview or delayed confirmation.
3. **No replay or synthetic success.** Ordered requests create an explicit
   preview before confirmation. The bounded ledger dispatches a request once;
   concurrent confirmation, timeout, exception, invalid receipt, lost
   acknowledgement or failed readback becomes `unconfirmed` and is never
   replayed. Unsupported native capabilities use the production fail-closed
   port. Public receipts omit payload, grant and native receipt handles.

## TDD evidence

| Stage | Command | Result |
| --- | --- | --- |
| RED | `flutter test test/features/web_panel/web_panel_native_bridge_test.dart` before production code | Expected compile failure because the bridge contract did not exist; checkpoint `d8a0b70b` |
| GREEN | `flutter test test/features/web_panel/web_panel_native_bridge_test.dart --coverage` | Initial 4/4 tests passed; checkpoint `4ec93d37` |
| Expiry RED | Focused confirmation-expiry test before the fix | Expected failure: delayed confirmation was observed; checkpoint `262ae13b` |
| Final GREEN | `flutter test test/features/web_panel/web_panel_native_bridge_test.dart --coverage` | 5/5 tests passed |
| Coverage | Focused LCOV entry for `web_panel_native_bridge.dart` | 201/241 lines, **83.4%** |
| Static analysis | Focused `flutter analyze` | 0 issues |

The tests cover strict parsing, every authority dimension through exact scope
equality, iframe/new-window/origin/downgrade/visibility denial, grant revocation,
sequence/replay, concurrent confirmation, lost readback, timeout, capability
denial, and redacted public receipts.

## Manual and dependent boundary

A normal `webview_flutter` JavaScript channel does not authenticate the source
frame and therefore is intentionally not connected to this contract. A later
Android frame-aware adapter must provide trusted main-frame/origin metadata and
must pass K03/K07 authority integration before any website can reach the port.
Actual TTS, printing and QR adapters, permission denial/revocation, Huawei
WebView and DeX behavior remain **MANUAL**. No physical operation or complete
K08 acceptance is claimed; progress remains **22/125** and **0/63**.
