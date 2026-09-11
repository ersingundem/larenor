# Android native VNC adapter contract

This bounded slice defines the Android contract that a future native RFB/JNI
engine must satisfy. It does not package or load a native library, resolve a
host, open a socket, or connect to a VNC server. The production default is
`UnavailableVncNativeBackend`, so a build without a reviewed engine reports
unavailable and cannot simulate a connection.

## Security and feature negotiation

Capabilities and requests use one exact schema version and reject unknown,
duplicate, malformed, or inconsistent fields. The initial native boundary
accepts only RFB 3.8 with `vencryptTlsVncAuth`, TLS, an exact SPKI SHA-256 pin,
and password authentication. Classic plaintext VNC and unauthenticated modes
cannot enter the adapter request. Missing TLS, pinning, password auth, or the
requested RFB version fails before the backend receives credentials.

Framebuffer negotiation is bounded to 640×480–8192×8192, at most 33,554,432
pixels, 72–640 DPI, true-color 32-bit pixels, and the closed raw/ZRLE/Tight
encoding set. Dynamic resolution and external-display requests require an
explicit matching capability. Pointer, physical-keyboard, and clipboard
requests also require exact advertised support; the adapter does not silently
downgrade them.

Targets are independent bounded IP/domain plus port values. Public request and
plan summaries omit the target host and SPKI fingerprint. Passwords cross the
native boundary only as caller-owned mutable `CharArray` values, are bounded to
4096 code units, and are zeroized after success, negotiation rejection, or an
unexpected backend exception. Native diagnostics collapse to a closed,
secret-free error code with `retryable: false`; this layer has no automatic
retry or replay.

## Focused evidence

Android JVM tests cover strict capability and request parsing, unavailable and
inconsistent capability claims, hostile target syntax, TLS/SPKI/auth downgrade
rejection, framebuffer/display/input negotiation, clipboard escalation,
secret redaction and zeroization, unexpected backend diagnostics, and the
no-network production default. All test backends are in-process fixtures.

## Acceptance still open

This contract does not complete F61/F62 or increase selected-feature progress.
A later slice must pin the native RFB implementation and Android ABI/build
provenance, add JNI symbol and lifecycle ownership, bounded cancellation and
deadlines, framebuffer decoding and surface delivery, and real pointer and
keyboard transport. An isolated owned TLS/VeNCrypt fixture must prove handshake,
pin mismatch, authentication, frame bounds, input, disconnect, and cleanup.
Real-server interoperability and Huawei tablet/Samsung DeX external-display,
keyboard, pointer, reconnect, and long-session behavior remain physical
acceptance work.
