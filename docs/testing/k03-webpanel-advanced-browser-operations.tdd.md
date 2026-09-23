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
  plugin delegate or network handles them. Exact default and explicit ports are
  tested, including subdomain, scheme, port, file and data negatives. Allowed
  POST requests are delegated without inspecting method, headers or body; a
  blocked request is never proxied.
- Service Worker network, content and file access is disabled process-wide
  before a panel loads. Attachment fails closed when any required AndroidX
  WebKit feature is unavailable or a setting cannot be applied. This global
  boundary is deliberate because Android Service Workers may outlive a WebView.
- The native attachment reverses the Android plugin's permissive popup defaults
  before JavaScript or the initial request is enabled. Automatic JavaScript
  windows and multiple-window support must both read back as disabled or the
  panel fails to attach; same-view navigation remains behind the exact-origin
  navigation firewall.
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

K03.remaining is still open for two documented Android platform gaps:

1. [`shouldInterceptRequest`](https://developer.android.com/reference/android/webkit/WebViewClient.html#shouldInterceptRequest(android.webkit.WebView,%20android.webkit.WebResourceRequest))
   is called only for the initial resource URL, not later redirect targets. An
   allowed subresource can therefore redirect cross-origin without another
   native callback. Closing that gap would require a proxy/transport that reads
   or replays requests, which this contract explicitly forbids.
2. Android WebView exposes no official native pre-request WebSocket callback.
   [`addDocumentStartJavaScript`](https://developer.android.com/reference/androidx/webkit/WebViewCompat#addDocumentStartJavaScript(android.webkit.WebView,java.lang.String,java.util.Set%3Cjava.lang.String%3E))
   runs script before document JavaScript, but it is not a native network
   boundary and does not cover worker execution contexts. It is therefore not
   presented as WebSocket enforcement. The supported
   [`ServiceWorkerWebSettingsCompat`](https://developer.android.com/reference/kotlin/androidx/webkit/ServiceWorkerWebSettingsCompat#setBlockNetworkLoads(kotlin.Boolean))
   network block is installed and negatively tested, but its documentation does
   not promise WebSocket interception.

The focused RED checkpoints were the new Dart attach-contract tests failing to
compile and the Kotlin/Robolectric firewall tests failing on missing native
types. The popup and credential hardening follow-up first failed because the
plugin defaults remained permissive and security callbacks still reached its
delegate. GREEN requires the 92-test WebPanel suite, the focused Android bridge
Robolectric suite, Flutter analysis, formatting and `git diff --check`.
K03.remaining and progress stay at **25/125** and **0/63** until the two
software platform gaps and remaining manual gates are accepted.
