# K03 WebPanel advanced browser operations

Status: **software acceptance complete at PR #474; queue closure update pending**

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
  The process accepts at most eight concurrent WebPanel requests across all
  attachments. Non-GET requests, user-info URLs, cross-origin redirects,
  responses over 16 MB, over-capacity work and calls beyond the 15-second
  deadline fail closed. The transport bypasses the system proxy, and releases
  its shared permit on EOF, read/skip failure, overflow or exact attachment
  retirement. Detach does not cancel a different attachment's calls.
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
  feature. Before document JavaScript runs in each realm, the installed
  non-configurable guard disables `WebSocket`, `EventSource`, `WebTransport`,
  `Worker` and `SharedWorker`. These long-lived transports are deliberately
  unavailable because Android WebView exposes no supported redirect-aware
  request callback for them; this evidence does not claim a native interceptor.
  Service Worker networking remains closed by the separate process-wide policy.
- The document-start rule is `*`, not the HTTP(S) allowlist, because sandboxed
  `srcdoc` frames have an opaque origin. Dedicated API 35 integration tests
  require all five constructors to throw `SecurityError` in the top document,
  a same-origin iframe, immediate and delayed opaque frames, and after reload.
  They carry no JavaScript message interface into native code.
- A separate real-WebView API 35 acceptance route proves an exact-origin
  redirect reaches its script while a cross-origin redirect opens no foreign
  socket and a declared response above 16 MB executes no script. The regular
  owned-transport unit suite still covers cancellation, streaming overflow,
  shared process capacity and exact attachment retirement deterministically.
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
the fail-fast permit cap. Adversarial RED `ff3f3d46` then exposes cross-attachment
capacity, opaque-frame injection, system-proxy and failed-stream cleanup gaps;
GREEN `5fdab42f` closes them. The grouped milestone passes **20/20** Android
WebPanel Robolectric tests and **113/113** Flutter WebPanel tests; focused
Flutter analysis reports no issues. Physical tablet/DeX/OEM evidence stays in
the separate manual gate described above.

Exact-head emulator CI at `d7b71fd9` then exposed a real lifetime gap: WebView
can consume exactly the declared `Content-Length` without requesting EOF or
closing the response stream. That stranded a process-wide permit, eventually
blocking both the allowed redirect script and the matrix's same-origin frame;
the matrix had served load 2 and remained at `waiting`, so it was not stale
reload evidence. RED `183bddc0` reproduces the starvation with two attachments
and one shared permit. GREEN `03216bd0` treats exact declared-length completion
as terminal while preserving the streaming byte cap and exactly-once close.
The rebased Android WebPanel group now passes **21/21** tests. Exact-head API 35
CI was the final automated gate.

## Exact review and CI acceptance

The final independent exact-tree review at
`ac8e1af6c5564fbc41eb5ea50d15241d01da2a87` found no remaining P1/P2 software
blocker after the exact-length lease fix. It rechecked the production WebView
boundary against the owned-transport, redirect, iframe, document-start,
Service Worker, lifecycle and secret-free requirements. The deterministic
acceptance manifest at `docs/testing/k03-webpanel-acceptance.json` binds those
production and adversarial test files to this review source.

The seven production and adversarial test references are byte-for-byte
unchanged from that exact source on the closure tree: `git diff --quiet
ac8e1af6..HEAD -- <manifest production/test references>` exits 0. The
validator additionally requires the critical redirect, owned-transport,
WebSocket, Worker, Service Worker and API 35 test markers in the current tree,
so the accepted CI and the live guard implementation are checked together.

[Android Build run 35941771379](https://github.com/ersingundem/larenor/actions/runs/35941771379)
passed on that exact source: API 35 `emulator-journeys`, all four Flutter
shards, static analysis, all four Server shards plus their aggregate gate and
the debug APK. [Security run 35941771192](https://github.com/ersingundem/larenor/actions/runs/35941771192)
passed dependency, platform-policy and secret scans on the same SHA. PR #474
then squash-merged as `7211a6ffca6008bcb30d9ec4d6849e222fc81092`.

This closes the K03.remaining software acceptance. It does not convert the
physical Android, DeX, Huawei WebView, OEM renderer, DPC, force-stop, peripheral
or real-site checks into automated evidence; those remain in the manual gates.
