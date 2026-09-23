# K03 WebPanel advanced browser operations

Status: **software slice ready; K03.remaining stays open**

## Three acceptance criteria

1. **Explicit, bounded transfers.** Upload and download are disabled by default
   and persist only as per-panel preferences. Each operation needs a fresh
   30-second foreground action. Uploads accept at most four supported files of
   at most 25 MB; downloads accept one exact-origin main-frame link, follow at
   most three exact-origin redirects, allow a bounded safe MIME set, and save at
   most 25 MB through the system picker.
2. **No credential or authority widening.** Download transport sends no Larenor
   token, website cookie, HTTP auth value, raw filename, or WebView user agent.
   Cross-origin redirects, subframe-triggered capture, `intent:`, non-HTTP
   schemes, TLS bypass, client certificates, HTTP auth, camera/microphone and
   unarmed file selectors fail closed. Late route, account, lifecycle and
   renderer callbacks cannot publish a transfer result.
3. **Bounded tablet recovery.** Web-content process termination and invalidated
   renderer errors retire the old controller before a fresh controller is
   built. Recovery and manual retry share a three-attempt/five-minute budget
   with a two-second floor, then show the existing secret-free maintenance
   state. EN/TR controls are 48dp, keyboard/TalkBack reachable, and tested at
   600/1200 widths with 2x text.

## Automated evidence

- WebPanel unit/widget tests cover one-shot upload, exact-origin anonymous
  download, redirect/MIME/size bounds, stale completion, iframe non-capture,
  settings persistence, EN/TR tablet layout, renderer recovery and existing
  origin/auth/TLS/data-retirement protections.
- The Android bridge now binds the plugin-owned native WebView identifier to an
  opaque one-shot attachment. `onRenderProcessGone` retires that exact Dart
  controller generation; duplicate, malformed and post-disposal events cannot
  recover or revive a newer controller. The wrapper forwards the existing
  plugin WebViewClient callbacks and never sends URLs, headers or diagnostics
  over the channel.
- A rejecting picker or transport port ends the one-shot operation as failed;
  it cannot strand the controller in `working` or replay a download.
- Focused Flutter analysis, formatting, diff, security, queue, progress and
  secret scans are required before merge.

## Remaining manual and platform boundary

Android WebView file chooser URI handling, SAF save behavior, physical OEM
renderer termination delivery, Huawei WebView, DeX mouse/keyboard and actual
website forms remain MANUAL. The app-level Android adapter now covers the
renderer-gone callback missing from the pinned plugin, but that plugin still
does not provide a complete pre-request firewall for every
iframe/fetch/WebSocket. Cross-origin subresource enforcement and physical
renderer-death acceptance are therefore not claimed. Pop-ups remain disabled
and external intents remain blocked. K03.remaining and progress stay at
**23/125** and **0/63** until those remaining gates are implemented and
accepted.
