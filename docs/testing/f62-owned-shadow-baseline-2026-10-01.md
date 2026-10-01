# F62 owned FreeRDP shadow baseline

This gate is a bounded software baseline. It does not complete physical Windows,
Huawei, DeX, clipboard, IME, or client-driven dynamic-resolution acceptance.

Before the expensive native build, the x86_64 job installs candidate-pinned
Ubuntu Xorg core and dummy-driver packages, verifies their installed versions,
and starts a direct owned headless Xorg display. Its private configuration
contains only the known 1280x800 and 1024x768 modes. The preflight requires one
active output, switches that output and the framebuffer to 1024x768, verifies
the root dimensions, and restores and verifies 1280x800. A failed or ambiguous
display preflight stops the job before the AAR build.

The later host step reuses that exact output and starts the Ubuntu FreeRDP
shadow server with an ephemeral NLA SAM credential. The packaged Android client
must establish the real TLS/NLA connection, accept the inspected SPKI pin,
receive a nonzero 1280x800 framebuffer, and acknowledge that frame. It then sends one software
USB HID `KeyA` press/release through the RDP input route. The host runner accepts only the exact XI2 raw key
pair from the private `xinput test-xi2 --root` stream; that stream is neither
written to an artifact nor included in the public receipt.

After the key witness, the host runner first revalidates that the configured
Xorg output is still the only active output. It changes that output's mode and
the owned framebuffer to 1024x768 with one bounded `xrandr` command and requires
an exact `xdpyinfo` readback. The Android test must receive a nonzero 1024x768 framebuffer,
acknowledge it, close the session, observe the close callback, and zero the
ephemeral password. Every owned process is terminated by its recorded process
group or workflow PID during failure and success cleanup.

The workflow preflight validates that its pinned Ubuntu Xorg core and dummy
driver can shrink to 1024x768 and return to 1280x800 before building FreeRDP.
The later runner repeats the shrink during the RDP session. A passing hosted
run therefore proves a host-originated
framebuffer change. It does not prove the client DISP channel: FreeRDP Android's
monitor-layout call requires a connected DISP context, while FreeRDP shadow
does not provide that server channel. FreeRDP shadow also does not implement
`cliprdr`, so this gate never sends clipboard data and never reports a remote
clipboard effect. IME remains unavailable.

The public receipt is source- and package-receipt-bound and names its scope as
`ownedShadowBaseline`. It records only booleans and fixed dimensions for the
TLS/NLA/SPKI, at least two acknowledged nonzero frames, software RDP HID key
effect, and clean
close. It explicitly lists `clientDynamicResolution`,
`clientToRemoteClipboard`, and `ime` as unsupported or unproven. Raw JUnit,
XI2 events, credentials, certificates, provider logs, and host identifiers are
not published. A physical keyboard remains a separate manual hardware gate.

Primary implementation references:

- FreeRDP 3.31.1 X11 key injection and root-size detection:
  <https://github.com/FreeRDP/FreeRDP/blob/3.31.1/server/shadow/X11/x11_shadow.c>
- FreeRDP 3.31.1 shadow desktop-resize delivery:
  <https://github.com/FreeRDP/FreeRDP/blob/3.31.1/server/shadow/shadow_client.c>
- FreeRDP 3.31.1 Android DISP client requirement:
  <https://github.com/FreeRDP/FreeRDP/blob/3.31.1/client/Android/Studio/freeRDPCore/src/main/cpp/android_disp.c>
- FreeRDP maintainer statement that shadow does not implement clipboard:
  <https://github.com/FreeRDP/FreeRDP/discussions/9272>
- Ubuntu 24.04 Xorg dummy-driver package and exact epoch-bearing version:
  <https://packages.ubuntu.com/noble/xserver-xorg-video-dummy>
- Xorg RandR framebuffer/CRTC resize validation:
  <https://github.com/XQuartz/xorg-server/blob/master/randr/rrscreen.c>

Local verification for this change is limited to the bounded Python runner and
workflow policy tests plus workflow lint. The real Android/Xorg/shadow result
must come from a changed-source hosted run; this document does not claim that
run has passed.

## Hosted display preflight (partial evidence)

At exact `e05df8ea1a95978370679b1f71fd7d93ff8b2c8b`, [run36794954941](https://github.com/ersingundem/larenor/actions/runs/36794954941), the `package (x86_64)` step `Preflight an owned resizable Xorg display` completed successfully. Root re-read the exact run SHA and named step result. Its shell requires one active output and matching CRTC plus `xdpyinfo` dimensions for1280×800 →1024×768 →1280×800. This closes the owned Linux display preflight only. The Android/NLA/frame/key/ACK/close baseline receipt and full feature acceptance remain open.

The same run later failed in the outer XI2 witness before a terminal JUnit
report was classified. Its bounded public diagnostic names the one expected
class and method but contains no test counts or Kotlin frames. The private
bounded step diagnostic was `owned XI2 key witness was malformed`: the runner
had decoded every `xinput test-xi2` line as strict ASCII, so a non-ASCII byte in
an unrelated device/locale line aborted the witness before its exact event
grammar was considered. This result does not prove that the Android test
reached its key calls.

The runner now parses bytes directly. Only a syntactically exact XI2 `EVENT`
line and its ASCII `detail` line can change the witness state; the accepted
effect remains one keycode-38 `RawKeyPress` followed by one
`RawKeyRelease`. A malformed line carrying either security-relevant prefix
fails closed. Unrelated bounded bytes are ignored and are never retained or
published. The existing one-megabyte stream bound remains unchanged.

Root independently ran the same outer-runner regression against the exact
pre-fix `e05df8ea` source loaded from Git. It failed with the observed
`UnicodeDecodeError` → `owned XI2 key witness was malformed` path; the current
byte parser passed the same fixture and reached resize. Root also passed all
75 runner/workflow/queue/progress checks. This is local regression evidence,
not a successful hosted Android baseline.

The actual pre-fix failure evidence is the changed-source hosted diagnostic
above, produced by the old strict-ASCII decode path. A new outer-runner
regression now supplies an unrelated non-ASCII XI2 line followed by the exact
ASCII key pair through the mocked bounded selector/read boundary. That payload
reaches the same old `raw_line.decode("ascii", errors="strict")` path and would
raise the observed malformed-witness failure; the byte parser observes the
pair. A second regression proves a malformed relevant-prefix line clears any
pending event before failing, so later detail bytes cannot complete stale
state. After the repair, the two focused regressions and the complete
packaged-acceptance runner suite pass. This is local parser evidence only. A
changed-source hosted run must still produce the one-test, zero-skip
Android/NLA/frame/key/resize/close receipt.
