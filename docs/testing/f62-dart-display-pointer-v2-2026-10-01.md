# F62 Dart display and displayed-frame input contract v2 — 2026-10-01

The Client model, MethodChannel engine and session controller now use the
strict schema-2 display/pointer contract in `contracts/rdp-client.v2.json`.
This is a source and focused-test checkpoint. Native package installation,
combined panel/runtime acceptance and hosted provider effects are separate.

## Implemented behavior

The display request uses actual RDP desktop and device percentage scales,
without an echoed DPI field. Width is even; dimensions, supported scale values
and the 64 MiB decoded-frame area bound are enforced before dispatch.
Viewport changes compare the complete request, so same-size density changes
also invalidate old input geometry. Requested protocol scales do not prove a
remote OS scale change. The bounds follow Microsoft's
[monitor-layout contract](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedisp/ea2de591-9203-42cd-9908-be7a55237d1c).

An initial frame arriving before the UI subscriber is retained in the bounded
one-frame slot and replayed once to the sole active consumer. A second consumer
is rejected. A newly emitted, unacknowledged bitmap does not replace the last
acknowledged displayed-frame tuple. The tuple includes sequence, actual width
and height, and local display-layout revision. Resize clears input authority;
an acknowledged transitional frame can render but cannot authorize input for
the new layout.

Absolute pointer, signed-16-bit relative movement and bounded vertical-wheel
steps carry that exact acknowledged tuple. Relative movement additionally
requires the authenticated session's negotiated support. Invalid or stale
events perform no native I/O. Input, resize, clipboard and acknowledgement
operations have bounded deadlines and retire invalid or uncertain replies.
Retirement removes frame and input ownership and wipes retained pixel bytes.

Capabilities are a closed schema including Gateway support and the exact
supported scale/mode lists. Schema-1 and contradictory capabilities are rejected;
capability absence does not count as completed implementation.

## Root evidence and limits

Root's three focused model/MethodChannel/controller suites passed **39 tests**.
The six production/test files passed scoped `flutter analyze` with no issues;
formatting and `git diff --check` were clean. These gates exercise cold-frame
delivery, one-consumer/ACK ownership, old/new geometry, same-size density fences,
negotiation rejection and model/native argument bounds. They are not a real
provider render, mouse, wheel or OS-scale receipt.

On 2026-10-03, root also ran all seven RDP Flutter test files together: **81
passed**. `flutter analyze` over both complete RDP production/test directories
reported **No issues found**. This includes the shared fullscreen/geometry
panel integration; it remains local Dart evidence and does not replace native
package, Android runtime or hosted provider acceptance.

The separately recorded [exact-42be direct native failure](f62-42be-provider-failure-2026-10-01.md)
does not traverse the Dart stream. This cold-frame fix therefore is not claimed
as that failure's root cause. F62 stays `reworking` until the remaining software
and named actual-runtime gates close.
