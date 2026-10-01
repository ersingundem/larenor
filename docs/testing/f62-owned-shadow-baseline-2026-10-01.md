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
