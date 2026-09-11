# VNC package-internal RFB engine adapter

This stacked slice connects the synthetic RFB parser to an Android
`VncNativeSession` lifecycle. The adapter accepts only an injected in-memory
byte transport. It has no target address, DNS, socket, proxy, TLS stack,
credential API, JNI loader, or production registration.

## Session state and frame ownership

The session follows the parser through version, security selection, explicit
security handoff, initialization, active, and awaiting-ACK states. Outbound RFB
bytes are written in parser order. A decoded frame is published only while the
session is active, and only one sequence may be outstanding. The next
incremental framebuffer request is written after the exact frame sequence is
acknowledged. Wrong or duplicate ACKs and extra frame data during backpressure
terminate the session without retry or replay.

Parser failures map to the existing closed `VncNativeFailure` vocabulary.
Target bytes, server names, protocol input, callback exceptions, and transport
diagnostics are never copied into the public failure code. A rejected frame
callback, failed write, malformed transition, unexpected close, or parser
failure detaches and cancels the transport once.

Background loss and explicit close are terminal. They clear the pending frame,
cancel the parser, detach the listener, and cancel the injected transport.
Late byte, security, or close callbacks cannot attach to a retired session, and
returning to the foreground does not restart it.

## Production availability remains closed

`VncRfbEngineAdapter.productionAvailable` is fixed to `false`, and no code
replaces the default `UnavailableVncNativeBackend`. Tests create a negotiated
raw-frame plan with synthetic capability data only to exercise the internal
post-negotiation state machine. Their `secureAuthenticated` callback is a
fixture signal, not proof of TLS, SPKI pinning, VeNCrypt sub-negotiation, or
password authentication.

## Evidence and remaining acceptance

Android JVM tests cover exact lifecycle transitions, parser output writes,
single frame ACK, malformed version cleanup, stale ACK cleanup, ignored late
callbacks, background cleanup, idempotent close, and the unchanged unavailable
production backend. Related Flutter tests continue to cover MethodChannel
ownership and the tablet/DeX framebuffer surface.

Feature progress remains **0/63**. A later slice must provide and attest a
pinned native RFB/TLS implementation, bind credentials and SPKI verification,
add real bounded I/O deadlines, and connect frame delivery to JNI or a texture.
An owned isolated VNC fixture plus Huawei tablet and Samsung DeX physical tests
remain required before F62 acceptance.
