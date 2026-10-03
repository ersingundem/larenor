# F62 native display and pointer v2 evidence

## Production boundary

The Android FreeRDP bridge now requires schema version 2 for open, frame ACK,
input, and resize operations. The package identity is pinned to
`freerdp-3.31.1-63b948ca-clipboard-utf8-display-pointer-v2` with JNI schema 2.
The package loader checks the exact relative-pointer query/send and four-field
monitor-layout APIs before allowing a connection.

Primary protocol/source references:

- [MS-RDPEDISP display-control capabilities](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/8989a211-984e-4ecc-80f3-60694fc4b476)
  defines the peer-supplied monitor count and area factors that constrain every
  client monitor-layout request;
- [MS-RDPEDISP monitor layout PDU](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/ea2de591-9203-42cd-9908-be7a55237d1c)
  requires an even monitor width and defines the desktop/device scale fields.
- pinned FreeRDP commit `63b948ca5cb94307fd5444ee6e73927a41ccdab4`
  implements pointer flags in `include/freerdp/input.h` and
  `libfreerdp/core/input.c`; the receipted Android patch exposes the matching
  `android_event.c` and `android_disp.c` operations without changing the
  public Larenor trust policy.

Display requests carry the requested width and height plus the RDP desktop
scale factor and one of the implemented device scale factors (100, 140, or
180). Width is even as required by MS-RDPEDISP, and width times height may not
exceed 16,777,216 pixels, the 64 MiB RGBA frame budget. No DPI value is echoed
as a server observation. A successful resize advances a local, JS-safe layout
revision and immediately clears the pointer authority from the prior layout,
including a same-size scale-only resize. The session reserves exactly one
input or resize effect under its lifecycle lock, clears displayed geometry
before resize JNI, and commits the sequence/layout revision only after the
effect succeeds. A concurrent call retires the session without a second JNI
effect.

The initial URI supplies `/size`, `/scale-desktop`, and `/scale-device`. The
pinned Android URI converter turns these query parameters into the matching
FreeRDP command-line arguments, whose settings are serialized in the initial
GCC client core data before PostConnect. Connection success stages the
authenticated TLS/NLA observation. Publication waits until the pinned DISP
client parses the peer's `DISPLAYCONTROL_CAPS_PDU`, retains its monitor-count
and area constraints, and emits the source-locked `OnDisplayControlReady`
callback. Authentication and peer capabilities may arrive in either order;
their one-shot join performs one successful five-argument monitor-layout send
without holding a Kotlin monitor across JNI. A missing, duplicate, stale,
retired, or rejected callback never causes a retry. Every later layout also
remains bounded by the retained peer area constraints. This proves that the
requested layout was accepted by the source-locked DISP send path after peer
capabilities were observed; it does not prove peer receipt or that the remote
operating system applied a visual scale.

Each frame contains the local layout revision under which it arrived. Pointer
and wheel input requires the exact last ACKed frame sequence, width, height,
and layout revision. A newer unACKed frame does not invalidate the frame still
shown by Flutter; absolute coordinates are mapped using that ACKed frame's
dimensions rather than the newest native bitmap. ACKing a newer current frame
retires the prior tuple. A transitional frame with the wrong size may be
displayed and ACKed but cannot authorize input for the requested layout.

Absolute pointer, negotiated relative pointer, and one-detent vertical wheel
events use the pinned FreeRDP input APIs. Relative input remains unavailable
until the authenticated connection reports `FreeRDP_HasRelativeMouseEvent`.
Wheel deltas are exactly +120 or -120. Stale tuples, stale sequence numbers,
background ownership, unsupported relative input, provider rejection, and
failed display changes retire the session without retrying the native effect.

## Focused evidence

The focused native tests cover:

- strict v2 capability/request shapes, scale factors, even display width, and
  the exact frame-budget area bound;
- exact package/JNI identity and fail-closed older schema rejection;
- ACKed geometry retention across an unACKed update and retirement after a
  newer ACK or display change;
- one in-flight input/resize effect, pre-JNI geometry retirement, and no
  duplicate sequence dispatch during a concurrent call;
- same-size scale changes, transitional wrong-size frames, and stale tuple
  rejection before JNI input;
- relative-pointer negotiation, signed delta bounds, exact wheel detents, and
  no replay after pointer or resize rejection;
- bridge ownership/schema validation and propagation of the exact ACKed tuple;
- packaged initial size/scale URI arguments, absolute/relative button flag
  plans, wheel protocol flags, either-order authentication/capability joining,
  and no publication or replay for stale, duplicate, retired, or failed
  initial-layout callbacks.

Root installed and verified the dual-ABI product package without restoring the
older schema-1 package. The merged AAR SHA-256 was
`29812970c261502c22217a7c7cb667a3d90ad615f473748a7453b77a629bbed4`;
the arm64 and x86_64 receipt SHA-256 values were respectively
`72951a985656ad9b7c3fefb79b5c042c1611bca4db796db0edc3cbc512bccddc`
and `f6a2a25f84cc11acde930f29135c0b76406d09412b9df2363f5d85f189913c85`.
`product_android_native.py verify-installed` accepted the mounted product.

With Java 17, one sequential Gradle gate covered the four main RDP classes,
the packaged display/pointer contract, the frozen Moonlight runtime class, and
AndroidTest Kotlin compilation. The final XML totals were:

- `RdpNativeContractTest`: 7 tests;
- `RdpNativeBridgeTest`: 5 tests;
- `RdpFreeRdpEngineTest`: 22 tests;
- `RdpFreeRdpPackageTest`: 2 tests;
- `RdpPackagedPointerDisplayContractTest`: 8 tests;
- `MoonlightEmbeddedRuntimeTest`: 46 tests.

All 90 tests passed with zero skips, failures, or errors. The exact AndroidTest
Kotlin task compiled successfully. The final private log is
`/private/tmp/larenor-f62-native-v2-gate.RtdIrx/gradle.log` (mode 0600 in a
mode-0700 directory). These software gates do not prove a Windows desktop
applied the scale change or received a pointer event.

## Remaining acceptance boundary

The layout revision proves local request/frame geometry continuity. It is not
proof that a peer honored desktop scaling. Actual Windows display scaling,
relative mouse behavior, wheel delivery, DeX display movement, and visible
remote cursor effects remain provider/device acceptance gates. The Client must
retire and recreate a session when the external/default display identity
changes; the native resize path does not migrate an active session between
display identities.
