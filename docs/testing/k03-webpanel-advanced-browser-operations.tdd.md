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
  opaque one-shot attachment and a bounded set of structured
  `{scheme, host, effective-port}` descriptors. `onRenderProcessGone` retires
  that exact Dart controller generation; duplicate, malformed and post-disposal
  events cannot recover or revive a newer controller. The wrapper forwards the
  existing plugin WebViewClient callbacks and never sends request URLs, paths,
  headers, cookies or diagnostics back over the channel or to logs.
- Native `shouldInterceptRequest` rejects direct cross-origin iframe, fetch and
  subresource HTTP(S) requests with an empty, non-cacheable response before the
  plugin delegate or network handles them. Exact-origin non-main-frame GETs use
  a dedicated anonymous OkHttp client instead of WebView networking. It accepts
  no WebView headers, cookies, credentials or request body, follows at most
  three redirects and rechecks every target before opening the next socket.
  Each attachment accepts at most eight concurrent requests. Non-GET requests,
  user-info URLs, cross-origin redirects, responses over 16 MB, over-capacity
  work and calls beyond the 15-second deadline fail closed. Detach, replacement,
  disposal and renderer death cancel the exact attachment's in-flight calls.
- Service Worker network, content and file access is disabled process-wide
  before a panel loads. Attachment fails closed when any required AndroidX
  WebKit feature is unavailable or a setting cannot be applied. This global
  boundary is deliberate because Android Service Workers may outlive a WebView.
- The native attachment reverses the Android plugin's permissive popup defaults
  before JavaScript or the initial request is enabled. Automatic JavaScript
  windows and multiple-window support must both read back as disabled or the
  panel fails to attach; same-view navigation remains behind the exact-origin
  navigation firewall.
- Attachment also requires AndroidX WebKit's official document-start script
  feature. Before document JavaScript runs in each allowed origin, the installed
  non-configurable guard disables `WebSocket`, `Worker` and `SharedWorker`.
  WebSocket is deliberately unavailable because Android WebView exposes no
  supported redirect-aware request callback; this evidence does not claim a
  native WebSocket interceptor. Service Worker networking remains closed by the
  separate process-wide policy above.
- TLS errors, client-certificate requests and HTTP-authentication challenges
  are cancelled by the native wrapper and are never delegated to the plugin.
  Host, realm and certificate details are not sent to Dart or logged.
- Download publication no longer trusts the response `Content-Type` alone.
  PDF object/xref/EOF framing, JPEG marker framing, PNG chunk lengths and CRCs,
  WebP RIFF/chunk lengths, strict UTF-8 text/CSV, and parseable JSON are checked
  after the bounded anonymous download and before Android SAF is opened.
  Generic octet-stream, truncated framing and declared-type mismatches fail
  closed. This is a format preflight, not a claim that remote content is trusted;
  the resulting OS-owned document remains untrusted input for its viewer.
- A rejecting picker or transport port ends the one-shot operation as failed;
  it cannot strand the controller in `working` or replay a download.
- Focused Flutter analysis, formatting, diff, security, queue, progress and
  secret scans are required before merge.

## Remaining manual and platform boundary

Android WebView file chooser URI handling, SAF save behavior, physical OEM
renderer termination delivery, Huawei WebView, DeX mouse/keyboard and actual
website forms remain MANUAL. Pop-ups remain disabled and external intents
remain blocked.

The two documented software gaps are now closed without claiming unsupported
WebView behavior. [`shouldInterceptRequest`](https://developer.android.com/reference/android/webkit/WebViewClient.html#shouldInterceptRequest(android.webkit.WebView,%20android.webkit.WebResourceRequest))
still reports only the initial URL, so allowed subresource GETs are fetched by
the owned transport and WebView never follows their redirects. Android exposes
no native pre-request WebSocket callback, so
[`addDocumentStartJavaScript`](https://developer.android.com/reference/androidx/webkit/WebViewCompat#addDocumentStartJavaScript(android.webkit.WebView,java.lang.String,java.util.Set%3Cjava.lang.String%3E))
is used only to disable WebSockets and worker creation before document script.
The supported
[`ServiceWorkerWebSettingsCompat`](https://developer.android.com/reference/kotlin/androidx/webkit/ServiceWorkerWebSettingsCompat#setBlockNetworkLoads(kotlin.Boolean))
network block remains the process-wide Service Worker boundary.

The owned-transport RED checkpoint `5fd7420a` failed to compile because its
transport, document-start policy and lifecycle retirement did not exist. The
WebSocket RED `7ad30fad` then rejected the temporary same-origin exception:
redirect-aware WebSocket enforcement is unsupported, so allowing it was not an
honest boundary. GREEN `dcc6ecd8` and `bfb2e7d1` supply the owned transport and
fail-closed dynamic-context policy. Concurrency RED `0e010a8c` failed to compile
because the transport had no concurrent-request bound; GREEN `9f89bf16` adds
the fail-fast permit cap. The grouped milestone passes **17/17**
Android WebPanel Robolectric tests and **113/113** Flutter WebPanel tests;
focused Flutter analysis reports no issues. K03.remaining and progress stay at
**26/125** and **0/63** until review and exact-head CI are recorded. Physical
tablet/DeX/OEM evidence stays in the separate manual gate described above.
