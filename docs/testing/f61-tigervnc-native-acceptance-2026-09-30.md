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
.....
Ran 5 tests ... OK

python3 -m py_compile tool/f61_tigervnc_acceptance.py

./gradlew --no-daemon :app:testDebugUnitTest \
  --tests com.ersingundem.larenor.vnc.VncTigerVncAcceptanceTest
BUILD SUCCESSFUL in 20s
1 test, 1 skipped, 0 failures/errors
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
