# K08 authority-bound WebPanel native bridge

Status: **production wiring slice ready; K08 remains pending**

Source: `K08 — Sınırlı web→native köprü` in `docs/execution-queue.json`.
The accepted `K03.remaining` and `K07` foundations are present at base
`a20c546526486ce1d7c860a0b39c53b5e5623760`. This slice wires the existing
strict command contract to an AndroidX WebMessage transport and the Flutter
WebPanel lifecycle without claiming the unavailable physical-device evidence
or concrete TTS, print, and QR effect adapters.

## Production boundaries

1. **Explicit versioned policy.** WebPanel settings default the bridge off. An
   enabled policy persists only schema v1, a monotonically revised exact
   canonical HTTPS top origin, and a closed nonempty set drawn from `speak`,
   `printDocument`, and `scanQr`. Noncanonical origins, unknown fields, duplicate
   methods, wrong types, HTTP, paths, queries, fragments, and revision overflow
   fail closed.
2. **Authenticated main-frame transport.** AndroidX WebKit 1.15.0 attaches the
   fixed `larenorNative` object only to the exact policy origin. Native metadata,
   rather than website-controlled JSON, supplies source origin and main-frame
   status. Iframes, downgrade, foreign origins, popups, oversized messages,
   reply overflow, detached generations, and unsupported WebMessage capability
   produce no Flutter dispatch. Replacement/detach removes the listener and
   retires pending one-shot replies.
3. **Live authority and one-shot consent.** A runtime can be created only when
   the caller supplies both a verified Core authority lease and a native effect
   port. The lease binds exact Core, home, account, session family, panel source,
   source revision, policy revision, route epoch, lifecycle epoch, and top
   origin. Every command needs a fresh 30-second grant and visible user
   confirmation. Capability revision drift, callback exception, logout,
   replacement, route cover/disposal, background, timeout, failed readback, or
   lost acknowledgement retires the generation and never replays an effect.

The Android message adapter is not a credential path: its envelopes and public
receipts carry no Core token, panel URL, header, cookie, native receipt handle,
or command payload. Normal WebPanel callers pass no authority/port, so enabling
settings alone cannot create a native effect path.

## RED to GREEN evidence

| Job | RED | GREEN | Evidence |
| --- | --- | --- | --- |
| Policy and opt-in | `f63e4071` | `f7e9ad39` | Strict JSON policy, safe default off, persisted user-selected methods, and EN/TR 600/1200 at 2x controls. |
| Frame-aware Android adapter | `75d24392` | `35b70639` | Main-frame/exact-origin acceptance plus iframe, HTTP downgrade, foreign origin, popup, bounded replies, replacement, and stale-detach denials. |
| Core authority and lifecycle | `92d71c96` | `d0c12ade` | Verified authority lease, 30-second confirmation, capability revision, route/lifecycle retirement, callback failure, and exactly-once behavior. |
| Adversarial hardening | focused regression | `469b6ab8` | Canonical origin enforcement, permanent grant revocation after capability drift, and reachable legacy Save action before the lazy native-options section. |
| Monotonic consent expiry | `266b7d17` | `4cd4e049` | Replaces injectable wall-clock deadlines with a production `Stopwatch` clock and locks both arm-to-preview and preview-to-confirm expiry at the exact 30-second boundary. |

The final grouped milestone on `469b6ab8` passes:

- **153/153 Flutter tests** across all WebPanel tests, dashboard WebView tile,
  Core home/session and logout, and managed-tablet runtime scope;
- **20/20 Robolectric tests** across native WebMessage, renderer, and owned
  transport suites;
- focused Flutter analysis with **0 issues**;
- focused bridge/view coverage with `web_panel_native_bridge.dart` at
  **244/290 (84.1%)**, `web_panel_native_runtime.dart` at **110/130 (84.6%)**,
and `web_panel_view.dart` at **351/388 (90.5%)**.

The independent review expiry regression then passes **52/52** focused bridge,
renderer-monitor, and WebPanel view tests after the monotonic-clock GREEN. The
RED failed to compile because the old controller exposed only a `DateTime`
wall-clock callback; it could not express or enforce monotonic elapsed time.

## Remaining K08 acceptance

K08 remains `pending`; queue progress stays **30/125 (24.0%)** and feature
progress stays **0/63 (0.0%)**. A later slice must supply and independently
review the authorized production TTS, print, and QR ports, then collect API 35
emulator plus physical Huawei/DeX/WebView permission-revoke and accessibility
journeys. Exact-head required CI and independent security review are also still
required before the queue item can close.
