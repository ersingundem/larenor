# F61 TigerVNC native acceptance — 2026-09-30

## Gap closed by this gate

`VncProductionLoopbackTest` exercises the packaged `VncAndroidRfbBackend`, but
its peer is a repository-owned byte fixture. It cannot establish compatibility
with an independently implemented VNC server. The opt-in acceptance in this
slice instead starts the distribution's official TigerVNC `Xtigervnc` process
and drives the normal `VncNativeBridge` against it.

The fixture is isolated to a GitHub-hosted Ubuntu runner. It generates a
one-day certificate and random synthetic VNC password, listens on one ephemeral
port of that runner, records the installed package version, and deletes all
credentials and processes after the test. No household address, credential or
remote service is an input.

## Provider contract

TigerVNC's upstream [`Xvnc(1)` source
manual](https://github.com/TigerVNC/tigervnc/blob/master/unix/xserver/hw/vnc/Xvnc.man)
defines the exact capabilities used here:

- `SecurityTypes=X509Vnc` selects VeNCrypt X.509 TLS plus VNC password
  authentication; `X509Cert`, `X509Key` and `PasswordFile` identify the owned
  fixture credentials.
- `AcceptSetDesktopSize` accepts client desktop-size requests.
- `AcceptKeyEvents` and `AcceptPointerEvents` are enabled server behaviors.
- `SendCutText` and `AcceptCutText` are real server clipboard paths.

The upstream [TigerVNC security
guide](https://github.com/TigerVNC/tigervnc/wiki/Secure-your-connection)
documents X.509 certificate/key configuration and warns against bypassing
certificate errors. Larenor discovers only the leaf SPKI, requires the exact
user-approved pin on the authenticated connection, and never downgrades to
plain VNC.

## Acceptance behavior

`VncTigerVncAcceptanceTest` uses the same production bridge constructed by
`MainActivity`. It verifies:

1. a certificate-inspection connection returns a bounded SPKI SHA-256 value;
2. a second connection negotiates RFB 3.8, VeNCrypt `X509Vnc`, TLS and VNC
   password authentication;
3. the server supplies a non-uniform 800×600 raw framebuffer;
4. pointer press/release and text input produce a subsequent changed frame;
5. a 960×720 `SetDesktopSize` request returns a framebuffer with that exact
   size;
6. clipboard remains truthfully unsupported: the capability is false and an
   attempted outbound clipboard event fails closed and retires the session;
7. after lifecycle authority loss, the old binding and input sequence cannot
   reconnect or replay, and no further frame is published.

The clipboard assertion is intentionally a denial assertion. The production
backend consumes and bounds server cut text but does not expose it, advertises
`clipboard=false`, and sends no client cut text. This gate does not convert a
dormant parser shape into a product capability.

## Commands and evidence state

Local macOS verification, where no TigerVNC X server or Linux container runtime
is present:

```text
python3 -m unittest tool.tests.vnc_native_workflow_test
......
Ran 6 tests ... OK

python3 -m py_compile tool/f61_tigervnc_acceptance.py

The acceptance runner's materialized Gradle 9.7.1 wrapper command then ran:

java ... org.gradle.wrapper.GradleWrapperMain --no-daemon \
  :app:cleanTestDebugUnitTest :app:testDebugUnitTest \
  --tests 'com.ersingundem.larenor.vnc.*'
BUILD SUCCESSFUL in 24s
46 tests, 1 skipped, 0 failures/errors
```

The skip is mandatory outside the owned Linux fixture. A passing real-server
receipt requires `.github/workflows/vnc-native-acceptance.yml`. Its runner
cleans the exact Gradle test task and then requires the XML report to contain
one executed test with zero skips, failures and errors before it can write a
passing receipt. Until that hosted job runs on the committed exact source, F61
remains awaiting this software acceptance rather than being described as
real-server verified.

Physical tablet/DeX focus, IME, keyboard layout, long-session performance and
real household network behavior remain manual gates even after the hosted
TigerVNC receipt passes.

## Exact hosted fixture result and repair

[Run 36764619917](https://github.com/ersingundem/larenor/actions/runs/36764619917)
at `939646c25f44c5f80750cb1c5f157f39b919d92a` started TigerVNC 1.13.1
but failed before the production bridge test. The bounded xterm log reports
that its fixed Unicode font could not be loaded; the window-focus readiness
step then timed out. The workflow used `--no-install-recommends` without an
X core-font package. The owned fixture now explicitly installs `xfonts-base`.
This bootstrap repair does not establish VNC interoperability: the exact
one-test/no-skip XML gate still must run and pass on a new revision.

[Run 36765832888](https://github.com/ersingundem/larenor/actions/runs/36765832888)
at `b76558c4ee09b3f8e5fad4b274ac699576e71821` installed the fonts and no longer
reported that error, but timed out waiting for the xterm title. No production
bridge test executed. The fixture now uses a unique immutable X resource class
(`LarenorF61Fixture`) and `xdotool --class` instead of a mutable window title.
Its owned shell explicitly uses `bash --noprofile --norc`, so runner shell startup
configuration cannot rename the test window. Title mutation is a suspected cause
of the earlier timeout, not an observed protocol failure.

The [xterm manual](https://manpages.ubuntu.com/manpages/noble/man1/xterm.1.html)
documents `-class` and `-e`; the
[xdotool manual](https://manpages.ubuntu.com/manpages/noble/man1/xdotool.1.html)
defines `--class` against WM_CLASS. The visible-window/focus readiness check still
has a ten-second bound; none of the real SPKI/auth/frame/input/resize assertions
or the exact one-test/no-skip XML receipt gate were relaxed. Six VNC workflow
policy tests passed locally. A new exact hosted gate must verify this bootstrap
repair and then execute the actual bridge acceptance.

[Run 36768307357](https://github.com/ersingundem/larenor/actions/runs/36768307357)
at `645e5b7305fe56c56545a3dba8fcf4671e959ad5` proved that the font and
WM_CLASS bootstrap repairs worked: TigerVNC started, the fixture window became
ready, and the runner reached the native-test launch. It then failed before any
Gradle test because `android/gradlew` is deliberately ignored and is absent in a
fresh checkout. The local file had hidden that packaging error; this was not an
RFB, TLS or authentication failure.

The runner now materializes the wrapper JAR supplied by the workflow's pinned
Flutter SDK beside the repository's tracked `gradle-wrapper.properties` in its
private temporary fixture directory, gives both files mode `0600`, and invokes
`GradleWrapperMain` directly. It does not generate or trust an untracked
project script. Missing or symlinked SDK wrapper artifacts and missing or
symlinked project properties fail closed. Six workflow-policy tests, an actual
materialized Gradle 9.7.1 launch, and the 46-test native VNC batch passed
locally; the one real TigerVNC test remains the intentional non-Linux skip. A
new exact hosted run is still required for the one-test/no-skip receipt.

[Run 36769953343](https://github.com/ersingundem/larenor/actions/runs/36769953343)
at `f1713f654bc6bc2fac0bb2d35a8f63a423e12415` again started the owned
TigerVNC fixture and materialized Gradle successfully. Gradle then compiled the
application before running the selected test and failed because localization,
Freezed and provider outputs were absent from the fresh checkout. The workflow
now runs lockfile-enforced `flutter pub get`, `flutter gen-l10n`, and
`build_runner` in that order before launching the production bridge.

The public receipt is now bound to the real 40-character Git `HEAD` and, on a
hosted run, requires exact equality with `GITHUB_SHA`. Its XML verifier requires
one testcase with the exact production acceptance class and method plus zero
skip, failure or error elements; a summary-only suite can no longer create a
passing receipt. Eight workflow/parser/provenance policy tests pass locally.
No raw fixture or Gradle logs are included in the public receipt. A new hosted
run must still execute that exact test successfully before F61 can claim native
TigerVNC interoperability.

## Real TigerVNC TLS readiness defect and repair

[Run 36772273119](https://github.com/ersingundem/larenor/actions/runs/36772273119)
on exact `f5b382cec7e3d4ced65535e8e538e696fbb3fec6` reached the production
bridge test. Certificate inspection failed before VNC authentication or frames.
The real server reported an improperly terminated TLS handshake.

TigerVNC 1.13.1's [server TLS implementation](https://github.com/TigerVNC/tigervnc/blob/v1.13.1/common/rfb/SSecurityTLS.cxx#L150-L169)
sends a plaintext readiness byte after VeNCrypt subtype selection; its
[client reads that byte before TLS](https://github.com/TigerVNC/tigervnc/blob/v1.13.1/common/rfb/CSecurityTLS.cxx#L152-L175).
Larenor had handed the unread byte to SSLSocket, so the TLS record stream began
with non-TLS data. The production backend now requires readiness byte 1 before
TLS takes ownership. TLS 1.3 and profile SPKI verification remain unchanged.

Root ran the actual production loopback class after adding the same readiness
step to the owned server. All 3 tests passed with 0 skips/failures/errors:
frame/input/resize/disconnect, readiness 0 rejection, and unknown readiness 2
rejection. Both rejection hosts observed EOF with no TLS ClientHello or
authentication traffic. The archived local XML is
`/tmp/larenor-root-vnc-readiness-result.xml`.

The first local full Gradle dependency run stopped on an in-progress F47 Dart
type error before native tests. The final narrow Kotlin run excluded
`:app:compileFlutterBuildDebug` and passed in 14 seconds; it is native protocol
evidence, not a new full application build. A new exact hosted TigerVNC receipt
is still required. F61 remains implemented/awaiting native validation.

## Hosted first-frame fixture repair

[Run 36774361551](https://github.com/ersingundem/larenor/actions/runs/36774361551)
on exact `2cf908b21d6253e120e9b84d89b7ad92fc86a41b` reached the owned TigerVNC
server, completed X509Vnc negotiation and produced the first 800 by 600 frame.
The single acceptance method then failed at its first-frame diversity assertion.
This was after the earlier VeNCrypt readiness repair; the server log confirmed
the requested VeNCrypt and X509Vnc security types and the requested 32-bit pixel
format.

The fixture only painted a solid root color. The xterm visibility check proved
that a window had been mapped, but it did not guarantee that the server's first
full framebuffer response contained that window's later paint. The test's
requirement for more than four distinct byte values was therefore stronger than
the fixture it controlled. The runner now uses X.Org's documented
[`xsetroot -mod` pattern with foreground and background colors](https://xorg.freedesktop.org/archive/X11R7.0/doc/html/xsetroot.1.html)
to paint a fixed two-color 8 by 8 root before launching Gradle. That makes the
first full frame deterministically non-solid while leaving the later xterm
input-change assertion independent. TLS, SPKI pinning, password authentication
and the production VNC backend are unchanged.

The runner/workflow policy suite now has 9 passing tests, including a regression
that requires both fixed colors and rejects the former solid-root command.
Python compilation and whitespace validation also pass. No hosted rerun was
started from this workspace; a new source-bound run is still required for the
actual TigerVNC receipt.

Root independently passed 9 VNC workflow policy tests and 45 combined VNC/queue/commit-progress tests; Python compilation and exact diff check passed. The new fixture requires a fresh exact hosted receipt; no passing native acceptance is inferred from the previous first-frame observation.

## ExtendedDesktopSize control update repair — 1 October

[Run 36776598508](https://github.com/ersingundem/larenor/actions/runs/36776598508)
on exact `2a585d3c77b99fb323c9dbd791d4e7e62b11e731` still failed the initial
frame diversity assertion. Painting the owned root alone did not close it.
Root then reproduced a production parser defect with an actual owned TLS peer:
a standalone ExtendedDesktopSize update was published as a zero-filled frame,
and its screen ID was discarded. The regression failed at the pixel-array
assertion before the production repair. This supersedes the earlier inference
that the hosted failure was solely a solid-root fixture precondition.

The [RFB protocol's ExtendedDesktopSize semantics](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst)
require metadata and pixel updates to be separate, preserve framebuffer contents
when dimensions do not change, honor resize refusal, and preserve screen IDs.
The parser now consumes and validates bounded layout metadata without publishing
a frame or consuming a Flutter ACK. Its next request is incremental: repeatedly
sending non-incremental requests after metadata would solicit metadata forever.
Accepted size changes invalidate the old pixels; refused sizes leave them
intact. A SetDesktopSize request is allowed only after observed extension
support and carries the actual screen ID/flags. Mixed metadata/pixel updates
fail closed.

The owned X fixture now paints after the long-lived xterm is visible and uses
[`-noreset`](https://xorg.freedesktop.org/releases/X11R6.9.0/doc/html/Xserver.1.html)
to prevent the last short-lived readiness connection from resetting the display.
These fixture changes do not relax any production pixel/input/resize assertions.

Root native Gradle gate passed: 49 tests, 1 intentional Linux/TigerVNC skip,
0 failures/errors. The four actual owned TLS tests all executed with 0 skips:
frame/input, metadata without false frames, screen ID 42 preservation, accepted
resize, refused resize preserving previously decoded pixels, and both rejected
TLS readiness values. The archived exact class report is
`/tmp/larenor-root-vnc-metadata-result.xml`; final log is
`/tmp/larenor-root-vnc-metadata-final.log`. The gate excluded Flutter build to
avoid the concurrent F60 implementation, so it is native software evidence,
not a new full application build. Nine workflow policy tests also passed.
F61 remains implemented/awaiting actual hosted TigerVNC validation until the
exact one-method/no-skip receipt passes.

## Source-only timeout diagnostics — 1 October

[Run 36779316558](https://github.com/ersingundem/larenor/actions/runs/36779316558)
on exact `a745863947eb7e175386b78295fa6c84cf425e01` failed the named
real-host method in `pumpUntil`, source line 293. It no longer reported the
first-frame diversity assertion, but the generic Gradle output does not identify
which frame, input or resize wait timed out. No successful protocol acceptance
is inferred from that change.

The runner now prints only exact-source-bound diagnostic JSON: bounded counts
and up to eight allowlisted owned filename/line frames. It never prints JUnit
failure messages, arbitrary exception text, system output, host/password or raw
paths. Symlink, entity/DTD and oversized reports are refused. The report is
removed before the fresh native invocation; diagnostic output cannot reuse a
previous report. The success verifier still requires exactly the original
method, one executed test and zero skips/failures/errors.

Root passed 12 workflow/runner tests, including secret-bearing failure text,
identity rejection and malformed-report limits. A fresh run of this changed
source is required to locate the real timeout; the failed run was not blindly
restarted. F61 stays implemented/awaiting native acceptance.
