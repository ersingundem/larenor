# Synthetic RFB transport characterization

This stacked slice characterizes the byte-level boundary that a future VNC
engine must satisfy. It is an in-memory parser with no DNS, socket, proxy, TLS
implementation, credential access, JNI loading, or production registration.
`UnavailableVncNativeBackend` remains the production backend, so this work does
not claim a live VNC connection.

## Negotiation boundary

The parser accepts only the exact RFB 3.8 banner. The server security list is
bounded to 32 entries and must advertise VeNCrypt type 19; insecure None or
classic VNC authentication cannot be selected. The parser then stops at an
explicit VeNCrypt handoff. Tests call `markSecureAuthenticated` as a synthetic
fixture signal. It does not simulate or prove TLS, SPKI pinning, VeNCrypt
sub-negotiation, or password authentication.

After that handoff, ServerInit is chunk-safe and bounded to an 8192 by 8192
dimension limit, 33,554,432 pixels, a 4,096-byte UTF-8 desktop name, and the
exact 32-bit true-color pixel format requested by the fixture. The parser emits
fixed SetPixelFormat, raw-only SetEncodings, and initial framebuffer request
bytes. Server-provided names are validated and discarded; they never enter an
error, log, or receipt.

## Frame bounds and lifecycle

FramebufferUpdate accepts at most 256 rectangles and 16 MiB of pixel data per
update. It rejects unsupported encodings, invalid padding, zero or out-of-bounds
rectangles, overflow, malformed lengths, oversized buffers, and any other
server message. Raw wire pixels are converted to the RGBA8888 contract used by
the Flutter surface.

Only one frame may be outstanding. The parser emits the next incremental update
request only after an exact sequence acknowledgement. A duplicate or wrong ACK,
or additional input while a frame is outstanding, fails closed. It never
retries, reconnects, or replays protocol output.

Cancellation and foreground loss are terminal. Both wipe buffered bytes,
discard dimensions and pending ACK state, and reject later input. Any malformed
or oversized input follows the same terminal cleanup path and exposes only a
closed error code.

## Evidence and remaining acceptance

Android JVM tests use local byte arrays to cover fragmented version and
ServerInit input, VeNCrypt selection, raw frame conversion and sequence ACK,
unsupported negotiation, oversized and out-of-bounds rectangles, backpressure,
stale ACK, cancellation, and background cleanup. Related Flutter tests continue
to cover the strict MethodChannel owner and framebuffer surface.

Feature progress remains **0/63**. A later reviewed slice must provide a pinned
native RFB library, implement the full TLS/VeNCrypt handshake and credential
boundary, connect native cancellation to actual I/O, and deliver decoded frames
through JNI or a texture without extra copies. An owned isolated server fixture
and Huawei tablet/Samsung DeX physical tests remain required before F62 can be
accepted.
