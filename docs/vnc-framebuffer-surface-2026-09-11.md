# VNC bounded framebuffer and input surface

This stacked slice adds the tablet and DeX rendering boundary above the VNC
MethodChannel session owner. It accepts only synthetic, already-decoded RGBA
frames. It does not add an RFB decoder, native texture, JNI library, DNS lookup,
socket, or real VNC connection. The production native backend therefore remains
unavailable.

## Frame ownership and backpressure

The frame envelope has one exact schema, a monotonically increasing sequence,
dimensions from 1 to 8192, an exact `width * 4` stride, RGBA8888 pixels, and a
16 MiB maximum. Unknown fields, length or stride mismatches, unsupported pixel
formats, gaps, and duplicates fail closed. The renderer copies channel bytes,
zeroizes its owned copy after decode, bounds decode to five seconds, and keeps
only the displayed image. Replacing or retiring the frame disposes the previous
Flutter image.

Only one decode or unacknowledged frame can exist. A second frame returns
`busy`; the next sequence is accepted only after the current image has reached
a Flutter frame and its exact sequence is acknowledged. The controller never
queues, retries, or replays a frame or an acknowledgement.

The viewport preserves aspect ratio and centers the image with black letterbox
areas. Pointer positions outside the visible remote image are discarded;
positions inside it are normalized to the closed 0–1 range before crossing the
session boundary.

## Explicit input and cleanup

Physical keyboard and pointer input remain single-flight. Each input kind must
be both advertised by the native capability snapshot and selected in the exact
session request. Clipboard forwarding starts disabled, requires the explicit
48 dp toggle, and is limited to 65,536 UTF-8 bytes with NUL rejected. Flutter
and Android validate the clipboard envelope independently and zeroize their
temporary encoded byte arrays. No clipboard value is logged or placed in a
receipt.

Route or account ownership loss, backgrounding, replacement by another
controller, disposal, malformed input, frame drift, timeout, or an ambiguous
native result retires the session. Retirement clears the frame and clipboard
permission and sends at most one cancel. Returning to the route does not
restart the session or replay input.

## Focused evidence and open acceptance

Flutter tests cover strict decode and zeroization, scale and letterbox mapping,
frame ACK backpressure, keyboard/pointer/clipboard gating, 600 and 1280 logical
pixel surfaces at 2× text, accessibility semantics, and route/background
cleanup. Android JVM tests cover the corresponding clipboard request gate and
closed schema. All frames and sessions are local in-process fixtures.

Feature progress remains **0/63**. A later slice must connect an audited native
RFB decoder or texture to this surface and prove frame delivery, TLS/SPKI and
authentication against an owned isolated fixture. Real-server behavior and
Huawei tablet/Samsung DeX external-display, keyboard, pointer, clipboard,
reconnect, focus, and long-session checks remain physical acceptance work.
