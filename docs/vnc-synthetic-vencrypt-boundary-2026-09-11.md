# Synthetic VeNCrypt and SPKI boundary

This stacked slice inserts an in-memory VeNCrypt security state machine between
RFB security-type selection and the package-internal engine session. It parses
no certificate and opens no DNS, socket, proxy, or TLS connection. The default
native backend remains unavailable and `productionAvailable` remains `false`.

## Closed negotiation

The security parser accepts only VeNCrypt 0.2. Its buffer is capped at 1,024
bytes and its subtype list at 16 entries. It selects only X509Vnc subtype 261,
which requires both certificate-based TLS and VNC authentication. Version
downgrades, TLSNone, X509None, missing authenticated subtypes, unknown states,
trailing bytes, malformed lengths, and failed VNC authentication are terminal.

The state machine stops at the TLS boundary. A future audited TLS engine must
provide a minimal evidence object containing only protocol, cipher suite,
certificate-chain validity, hostname verification, and a 32-byte SPKI SHA-256
digest. Certificate objects, subjects, hostnames, target addresses, diagnostics,
and credentials cannot enter this boundary.

Only TLS 1.3 with AES-GCM or ChaCha20-Poly1305 suites is accepted. Certificate
chain and hostname validation must both already be successful. The supplied
SPKI digest is compared to the exact saved `SHA256:` pin with
`MessageDigest.isEqual`; mismatch is terminal and maps to the existing closed
`spkiPinningRequired` result. Owned digest arrays and the decoded expected pin
are zeroized after validation or cleanup.

## Engine lifecycle and cleanup

The engine transport now separates RFB bytes, VeNCrypt bytes, TLS peer evidence,
and the VNC-auth result. It cannot skip directly from RFB security selection to
an authenticated session. The exact path is VeNCrypt version and subtype,
TLS handoff, peer validation, VNC-auth handoff, and only then RFB ServerInit.

Malformed input, downgrade, invalid certificate evidence, pin change, auth
failure, transport failure, cancellation, background loss, or close detaches
and cancels once. Late peer evidence is closed and zeroized. Nothing restarts,
retries, or replays after a terminal result.

## Evidence and open acceptance

Android JVM tests cover fragmented VeNCrypt negotiation, X509Vnc selection,
downgrade and no-auth rejection, TLS evidence bounds, certificate and hostname
failure, changed pins, failed VNC auth, oversized input, cancellation, late
signals, engine state transitions, and the unchanged unavailable production
capability. Related Flutter tests continue to cover MethodChannel ownership and
the tablet/DeX framebuffer surface.

Feature progress remains **0/63**. The TLS evidence and VNC-auth results are
synthetic fixture signals. A later reviewed native implementation must perform
the real TLS 1.3 handshake, certificate-chain and hostname verification, SPKI
extraction, VeNCrypt sub-negotiation, password challenge, deadlines, and I/O
cancellation. Owned isolated-server and Huawei tablet/Samsung DeX physical
acceptance remain open.
