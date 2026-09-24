# K08 authority-bound WebPanel native bridge

Status: **software acceptance complete; physical device evidence remains MANUAL**

Source: `K08 — Sınırlı web→native köprü` in `docs/execution-queue.json`.
The accepted `K03.remaining` and `K07` foundations are present at base
`a20c546526486ce1d7c860a0b39c53b5e5623760`. The two K08 production slices wire
the strict command contract to AndroidX WebMessage, the Flutter WebPanel
lifecycle and bounded TTS, print and QR effect adapters. Physical Huawei, DeX,
TalkBack and OEM evidence remains outside this software acceptance.

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

## Foundation acceptance boundary

The foundation slice remained `pending` at **30/125 (24.0%)** because it did
not yet provide production effect adapters. The follow-up below supplies those
adapters and closes the software acceptance with independent review and exact
CI. Physical Huawei/DeX/WebView permission and accessibility journeys remain a
separate MANUAL gate.

## Production effect ports

This follow-up replaces the unsupported production default for verified-Core dashboard
panels with three bounded device effects while preserving the v1 website
contract and one-shot consent:

1. Android `TextToSpeech` accepts only 1..500 control-free characters and an
   optional canonical language tag. The native owner is bound to the exact
   Core/home/account/session/source/policy/route/lifecycle scope. Background,
   replacement, renderer retirement and logout stop speech without replay.
2. `printDocument` never accepts a URL or bytes from the website. Its opaque
   handle opens one user-visible Android document picker; only a canonical
   `content://` selection whose resolver MIME is `application/pdf`, whose
   decoded bytes begin `%PDF-`, and whose copied size is at most 25 MiB reaches
   `PrintManager`. The private 64 KiB streaming copy is removed after printing,
   cancellation or failure. A picker-owned pause is allowed; app stop, scope
   retirement and stale picker results cancel it.
3. QR uses the existing Android CameraX/ML Kit-backed `mobile_scanner` path in
   a visible in-app surface. Only QR is advertised by this port; Data Matrix is
   rejected until a reviewed decoder surface exists. Camera permission denial,
   background, route/account/Core/session replacement, renderer loss, timeout
   and explicit close terminate the single flight. The decoded value is
   bounded to 2,048 control-free characters, stays in memory and is never
   logged, persisted or placed in a public receipt.

### RED to GREEN evidence

| Job | RED | GREEN | Permanent evidence |
| --- | --- | --- | --- |
| Android speech | `f0b513e6` | `7b484e0a` | Exact scope/resumed owner, bounded text/locale, replacement and retirement; MethodChannel envelopes contain no Core secret or API URL. |
| Confirmed print | `bc41920b` | `811fabec` | Opaque handle, visible SAF picker, exact PDF MIME/magic, 25 MiB cap, bounded streaming, cancellation and no raw URI in website messages. |
| Visible QR | `8a3077f9` | `7070512d` | Single CameraX flight, permission/error UI, EN/TR 600/1280 at 200%, authority/background retirement and no replay. |
| Terminal lifecycle review | `ff48b5f2` | `f940bc61` | Retirement wins a delayed native bind, and a bounded 25-second QR flight cancels its visible camera before the 30-second controller deadline. |
| Owner replacement review | `2618977b` | `7c45df15` | Every WebPanel render receives a fresh effect owner, so a retired owner cannot be reused after rebuild or replacement. |
| Exact bind completion | `b96bda24` | `2a39ca2b` | A delayed native bind must finish for the exact current owner before the request can proceed; replacement and retirement remain terminal. |

The production-port grouped milestone passes:

- **185/185 Flutter tests** across the complete WebPanel feature, dashboard
  WebView tile, Core home/session and logout, managed-tablet and Server store
  scope;
- **30/30 Robolectric tests** across every WebPanel native suite, including
  the five speech, print, scope-replacement and stale-picker regressions;
- focused Flutter analysis with **0 issues**, Dart formatting, Android backup
  and CI trust security policy, execution-queue validation and `git diff
  --check`.

PR #487 exact source `2a39ca2be54a51e64a1c6517dc8c37ffe370045b`
passed Android Build `35988043289`, including API 35 emulator journeys, and
Security `35988042981`. Independent final review found no remaining P1/P2
blocker. Squash `a87d1bb3a2868f4f43d30733207c84cdb0129901` has the same
aggregate stable patch-id
`49dd58e007084eeff56f383b3d4f3e46b6b6f860` and is in main ancestry. K08 is
`done`; queue progress is **33/125 (26.4%)** and feature progress remains
**0/63 (0.0%)**. Physical Huawei/DeX/TalkBack/OEM evidence remains MANUAL.
