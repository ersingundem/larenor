# VNC Flutter to Android session bridge

This stacked slice connects the strict Flutter session owner to the Android
native VNC contract through two fixed channels. It still does not package or
load an RFB library, resolve a target, open a socket, or claim a successful VNC
connection. `UnavailableVncNativeBackend` remains the production backend.

## Exact ownership and capability binding

Every session uses an opaque UUID owner plus bounded account and route
revisions. Android accepts one active binding while the activity is resumed
and focused. Flutter rechecks its foreground, route, account, and PIN owner
after each asynchronous boundary. Backgrounding, focus loss, route or account
replacement, event-stream loss, malformed native data, and disposal retire the
session and issue at most one cancel. Late work cannot attach to a new owner.

Flutter reads the strict native capability envelope before open and sends its
exact engine revision with the request. Android compares that revision to the
same capability snapshot used for negotiation. Revision drift returns
`staleSession` before the backend is called. The existing TLS, SPKI, RFB auth,
framebuffer, display, and input request is parsed again on Android.

Password material crosses the method channel as a bounded byte array. Android
decodes it without creating an immutable password string, gives the adapter a
mutable character array, and zeroizes both arrays on every result. Flutter also
zeroizes its caller-owned byte array in a `finally` path. Neither channel result
nor public exception contains target, pin, password, platform message, details,
or stack text.

## Frame and input backpressure

The event channel carries frame-ready metadata only; it never transports pixel
bytes. One bounded frame notice may be outstanding. Its owner, account/route
revisions, session/request UUID, monotonically increasing sequence, dimensions,
and byte-length bound must match before Flutter publishes it. The next notice
cannot advance until Flutter explicitly ACKs the current sequence. A gap,
duplicate delivery, bad ACK, oversized metadata, or event-sink exception
retires the current session.

Flutter permits one input call in flight and never queues or replays input.
Android also enforces monotonic input sequences and a closed key/pointer event
schema. A `busy` result expresses bounded native backpressure. Any ambiguous
input result is terminal, because retrying could duplicate an input already
accepted by the native engine.

## Honest acceptance boundary

Focused Flutter and Android JVM tests use only mock method channels and
in-process backends. They prove channel names and payloads, capability revision
binding, lifecycle cleanup, stale result rejection, frame ACK/backpressure,
input serialization, password zeroization, closed native error mapping, and
channel detachment.

Feature progress remains **0/63**. A later slice must implement the pinned JNI
engine, texture or Surface ownership, real frame availability callbacks,
deadlines and native cancellation, and an isolated owned TLS/VeNCrypt fixture.
Real-server behavior plus Huawei tablet and Samsung DeX background, focus,
external-display, keyboard, pointer, reconnect, and long-session acceptance
remain open.
