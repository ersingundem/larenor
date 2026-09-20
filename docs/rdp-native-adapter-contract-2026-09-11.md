# Android native RDP adapter contract

This slice defines the fail-closed Android boundary that a future pinned
FreeRDP/JNI implementation must satisfy. It does not bundle or load a native
library, open a socket, resolve a host, or connect to an RDP server. The
production default is `UnavailableRdpNativeBackend`, so unsupported builds
cannot present a connection as available.

## Closed capability negotiation

The adapter accepts one exact schema version and rejects unknown fields. An
available engine must report a bounded revision plus TLS, certificate pinning,
NLA, RD Gateway, display, pointer, keyboard, and clipboard capabilities.
Requests cannot silently downgrade a requested security or interaction
feature. If the engine cannot meet the exact request, negotiation returns a
stable redacted error code before the backend receives credentials.

Targets and optional gateways have independent bounded host, port, username,
and policy fields. A gateway route requires gateway credential material, while
a direct route rejects unexpected gateway credential material. Certificate
fingerprints use the exact `SHA256:` form. Resolution, DPI, and pixel counts
are bounded before the native boundary.

Passwords cross this boundary only as mutable `CharArray` values. The adapter
zeroizes both target and gateway arrays after every open attempt, including
negotiation rejection and unexpected backend failure. Public summaries,
exception messages, and `toString` output exclude hosts, usernames, domains,
fingerprints, passwords, and backend error text. Failures are a closed set and
are never marked retryable; this layer performs no retry or replay.

## Verification in this slice

Android JVM contract tests cover strict schema parsing, inconsistent capability
claims, hostile target syntax, feature downgrade rejection, display and
clipboard negotiation, redacted output, bounded secret ownership and
zeroization, route/credential matching, and the unavailable production
backend. The tests use an in-process recording backend and make no network
request.

## Acceptance still open

The follow-up
[`f62-freerdp-native-engine-acceptance-2026-09-20.md`](f62-freerdp-native-engine-acceptance-2026-09-20.md)
pins FreeRDP source/build provenance and ABIs, creates exact AAR/ELF receipts,
and implements the bounded JNI lifecycle, frame, input and channel contract.
F62 remains at **0/63** feature acceptance: the receipted package still needs a
reviewed concrete product `RdpJniRuntime` plus an isolated owned Windows
fixture. Windows/NLA and RD Gateway interoperability and Huawei tablet/Samsung
DeX keyboard, pointer, external-display, resolution, reconnect and long-session
checks still require real acceptance.
