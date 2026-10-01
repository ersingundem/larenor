# F62 authenticated output boundary — 2026-10-01

The FreeRDP certificate callback now verifies the exact endpoint and presented
SPKI and returns the accept/reject decision only. A matching certificate does
not publish a secured session. The production `OnConnectionSuccess` callback
is the only source of authenticated security publication under the fixed
`sec=nla` policy. The operation monitor orders that publication before any
frame delivery. An early graphics update remains in the private bitmap and is
coalesced after security delivery; no pre-authentication frame bytes are
published. Retirement during security delivery, late callbacks, invalid pins,
and duplicate connection callbacks cannot release or resurrect output.

The URI explicitly uses `tls=seclevel:2,enforce:1.2`. FreeRDP's pinned parser
sets both TLS minimum and maximum to 1.2 for this option. The emitted TLS 1.2
value is therefore an enforced policy, rather than an inference from OpenSSL
cipher strength. TLS 1.3 is not negotiated by this reviewed configuration.

The credential-free `inspect` path deliberately rejects the certificate to
stop before login. Its native DTO is `RdpJniCertificateProbe`: the observed
SPKI, enforced TLS policy, and Client NLA requirement are separate from an
authenticated session result. The v1 MethodChannel keys remain compatible;
Client types and copy describe certificate retrieval and local policy. The
real `open` result requires the accepted pin and successful NLA connection,
with security delivered before returning success.

Primary implementation references:

- [Pinned Android post-connect callback](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/cpp/android_freerdp.c).
- [Pinned TLS option parser](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/common/cmdline.c).
- [Pinned URI-to-command-line conversion](https://github.com/FreeRDP/FreeRDP/blob/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/Android/Studio/freeRDPCore/src/main/java/com/freerdp/freerdpcore/services/LibFreeRDP.java).

## Local evidence and remaining acceptance

Root compiled production and AndroidTest Kotlin against the receipt-verified
FreeRDP x86_64 AAR. The current native regression set passed 22 tests:
12 Engine, 7 Contract, 1 Bridge, and 2 Package; zero skips, failures, or errors.
It covers certificate-only denial, exact one-time post-authentication
publication, retirement during delivery, exact clipboard modes, unavailable
IME, frame ACK ownership, and terminal lifecycle. Independent review found no
operation-monitor / Engine-state-lock inversion.

The owned-shadow baseline now requires a real secured frame, an RDP HID key
effect observed through XI2, a host-originated resized frame, acknowledgements,
and clean close. Its receipt is explicitly partial: it cannot prove client
DISP, clipboard, IME, physical keyboard, Windows, or DeX. A changed-source
hosted result is still required. These local gates do not promote F62 to
`awaiting_ci` or `done`, and do not increase acceptance counters.

The display fixture uses a direct Xorg dummy driver with two configured modes.
Before building the AAR, it must prove one active output and exact CRTC/root
1280×800 → 1024×768 → 1280×800 readbacks. Bare Xvfb could not provide this
resize contract. The31 runner/workflow tests and shell checks are local
evidence; the later exact e05df8ea hosted display preflight passed, while the full Android/shadow result remains open.
