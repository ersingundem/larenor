# VNC verified transport lifecycle boundary — 2026-09-11

This slice adds the first production-shaped Android transport handoff without
claiming a usable production VNC connection.

## Implemented contract

- The native lifecycle accepts an opaque `VncVerifiedRfbResult`; it cannot be
  activated by a raw Boolean success callback.
- Only an active `VncRfbEngineSession` can issue the one-use result, after RFB
  3.8, VeNCrypt 0.2/X509Vnc, TLS certificate and hostname evidence, exact saved
  SHA-256 SPKI pin, VNC authentication, and bounded ServerInit parsing have all
  succeeded.
- The result is bound to the exact request ID, engine revision, RFB version,
  security type, and framebuffer encoding. Drift or reuse fails as
  `staleSession`.
- Connect time is explicitly bounded to 1–60,000 ms. Deadline expiry,
  backgrounding, explicit close, transport failure, and transport close are
  terminal.
- Detach and cancel run once. Late results are consumed and discarded. The
  lifecycle never retries, restarts, or replays a connection.
- Public failure state uses the existing closed native error vocabulary. The
  verification result contains no address, certificate, pin, credential,
  framebuffer bytes, or raw native error.

## Deliberately unavailable

`VncVerifiedTransportSession.productionAvailable` remains `false`, and the
packaged `VncNativeAdapter` still uses `UnavailableVncNativeBackend`. This slice
does not add DNS, sockets, Android TLS primitives, JNI calls, credential
handoff, or a real VNC server connection.

The next production acceptance steps remain:

1. implement a bounded Android socket and TLS operation with DNS/peer/rebinding
   checks and no redirect/proxy path;
2. prove certificate-chain, hostname, and SPKI extraction against owned local
   fixtures;
3. bind password challenge handling with immediate zeroization;
4. connect decoded frames and negotiated input to the existing bridge under
   instrumentation tests; and
5. complete physical tablet/DeX keyboard, pointer, display, background, and
   network-loss acceptance before enabling the packaged capability.

## Evidence

- Android VNC package: 31 tests passed across six JUnit suites.
- Flutter VNC bridge and framebuffer surface: 12 tests passed.
- Focused Flutter analyzer: no issues.
- Queue validation remains 14/125 and 0/63; F62 is not accepted by this slice.
