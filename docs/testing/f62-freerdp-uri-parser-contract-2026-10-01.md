# F62 pinned FreeRDP URI parser repair — 2026-10-01

## Observed defect

Larenor's packaged Android runtime passed each disabled redirection channel as a
FreeRDP URI query value of `-`. The pinned Android
[`LibFreeRDP.setConnectionInfo(Uri)` converter](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/java/com/freerdp/freerdpcore/services/LibFreeRDP.java)
converts that form to the command-line token `-key`.

That token is not a general channel-disable operation. In the exact pinned
[`cmdline.h`](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/common/cmdline.h),
`drive` and `usb` require values, `camera` is not an option, and
`sound`, `microphone`, `printer`, and `smartcard` accept optional values rather
than boolean `+`/`-` state. The old URI could therefore fail parsing or request
a channel instead of proving it disabled.

The pinned
[`SessionState.connect`](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/java/com/freerdp/freerdpcore/application/SessionState.java#L64-L75)
also discards the boolean returned by `setConnectionInfo` and calls native
`connect` unconditionally. A malformed URI could reach connection startup
without a valid parsed settings result.

## Repair boundary

`RdpPackagedRuntime` now omits every unsupported optional redirection argument.
No sound, microphone, drive, printer, smartcard, USB, or camera option is added,
so the runtime never asks FreeRDP to enable those channels. Clipboard remains
the one advertised channel and uses the converter's valid boolean `+clipboard`
or `-clipboard` form. NLA, TLS security level, certificate pin verification,
display size, and dynamic resolution are unchanged.

The runtime parses the URI exactly once with `LibFreeRDP.setConnectionInfo`,
checks its boolean result, cleans up and returns the existing bounded
`engineUnavailable` failure on rejection, and calls `LibFreeRDP.connect` only
after successful parsing. It no longer calls `SessionState.connect`, avoiding a
second parse and the upstream ignored-result path. Hostname, username,
certificate data, and native parser errors remain private.

## Focused evidence

The packaged instrumentation acceptance keeps one receipt-compatible test
method. Before contacting the owned NLA host, it creates two disposable native
FreeRDP sessions and requires `LibFreeRDP.setConnectionInfo` to accept the
production URI with explicit clipboard enable and explicit clipboard disable.
Each parser-only native instance is freed in `finally`. The same method then
continues through the existing owned-host NLA, TLS, certificate pin, frame,
input, resize, clipboard, and clean-close checks.

```text
./gradlew :app:connectedDebugAndroidTest \
  -PfreerdpPackageDir=<verified-package-dir> \
  -Pandroid.testInstrumentationRunnerArguments.class=com.ersingundem.larenor.rdp.RdpPackagedHostAcceptanceTest#nlaHostDeliversPinnedFrameInputResizeClipboardAndCleanClose \
  -Pandroid.testInstrumentationRunnerArguments.rdpHost=<owned-host> \
  -Pandroid.testInstrumentationRunnerArguments.rdpPort=<port> \
  -Pandroid.testInstrumentationRunnerArguments.rdpUsername=<ephemeral-user> \
  -Pandroid.testInstrumentationRunnerArguments.rdpDomain=<domain> \
  -Pandroid.testInstrumentationRunnerArguments.rdpPassword=<ephemeral-password>
```

The previous hosted run
[`36784045011`](https://github.com/ersingundem/larenor/actions/runs/36784045011)
at exact `bc65ac5ab55f9d3709660c6bc1dc894d80c93454` completed after this
repair was prepared. Its public diagnostic identifies the original test method
once, zero skips, one failure, and the fixed private outcome
`connectionFailureBeforeCertificate`. This distinguishes the failing phase; it
does not alone prove the URI parser is its only cause.

Root independently verified the retained pinned x86_64 AAR receipt and compiled
both production and instrumentation source sets:

```text
python3 tool/freerdp_android_package.py verify-install <aar> <receipt>
./gradlew :app:compileDebugKotlin :app:compileDebugAndroidTestKotlin --console=plain
BUILD SUCCESSFUL in 14s; 279 actionable tasks
```

The owned temporary FreeRDP mount was removed after compilation. Compilation
is not native host acceptance. The failed source revision was not blindly
redispatched; the next hosted run must exercise this changed parser path. F62 remains pending until a
new source-bound packaged Android run reaches the owned NLA host and passes the
unchanged TLS, NLA, certificate
pin, frame, input, resize, clipboard, clean-close, and both native parser
assertions.
