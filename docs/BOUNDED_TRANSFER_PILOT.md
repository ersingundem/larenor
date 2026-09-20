# S08.10 bounded binary transfer pilot

This pilot adds one explicit, read-only binary download request to Larenor Core.
It is a narrow transport foundation, not completion of S08.10.

## Authority and provider boundary

`POST /api/v1/home-resources/{coreId}/{homeId}/{resourceId}/blob` is separate
from the JSON metadata and command routes. The caller supplies the exact user,
resource, ACL, and packaged-service revisions observed before the request.
Core checks the current login session and Home resource `read` authority before
opening the response and again before every frame.
The explicit open consumes the registry read rate limit; per-frame revalidation
does not consume another request allowance.

Production now includes one encrypted product provider. A caller with current
`write` authority can attach or replace at most 256 KiB of document/media bytes
for a resource through the separate bounded upload route. Download resolution
still accepts only the registry resource ID; HTTP callers cannot supply a
filesystem path, URL, provider name, or command. Packaged test providers remain
composable without disabling the production store.

`PUT .../blob/uploads/{requestId}` requires canonical content length, SHA-256,
media type and exact user/resource/ACL/provider revisions. Core checks write
authority before reading bytes and repeats it in the same SQLite transaction as
the encrypted object and immutable upload receipt. The first write expects
provider revision `0`; replacements require the exact current revision and
advance it once. Exact request replay returns the saved result, while a changed
envelope returns an idempotency conflict. Object and receipt tampering prevents
startup, resource deletion cascades to its bytes, and a wall-clock rollback
cannot move retained timestamps backwards. `GET .../blob/descriptor` exposes
only authorized digest/type/length/revision metadata.

## Wire and lifecycle contract

The response media type is `application/vnd.larenor.blob-stream.v1`. Headers carry
a random 32-character trace ID and the exact source byte length, SHA-256 digest,
media type, service revision, and framed HTTP content length. Every frame carries
the same trace ID, a monotonically increasing sequence, a final flag, and an exact
payload length. A zero-length final frame is the only success marker.

Core rejects `Range` and `If-Range`; this pilot does not support resume. It also
does not retry, replay, or restart a request. Client disconnect, cancellation,
deadline expiry, changed provider bytes or revision, lost session, and changed
user/resource/ACL authority abort the stream before the final success frame.
The declared framed content length makes such an abort incomplete to an HTTP
client. Results and errors contain fixed metadata and codes, never tokens or blob
content.

The default limits are 256 KiB per blob, 64 data chunks, one active transfer per
actor, eight active transfers per Core, 1 MiB reserved per actor per 60-second
window, and at most a 15-second caller-selected deadline. A successful open
reserves the blob's full byte count; disconnecting does not refund the quota.

## Android Client pilot

The tablet resource list now carries the current account revision that Core
already binds into its visible-view snapshot. A read-authorized member can
explicitly start the same download as an administrator; room rows and stale or
unverified sessions cannot issue it. The Client sends the exact account,
resource, ACL, and pilot service revisions once and performs no retry, range, or
resume request.

The Client buffers at most the server's 256 KiB bound in memory. It validates
the HTTP length and metadata, every trace ID and sequence, the zero-length final
success frame, source byte length, SHA-256, media type, and service revision.
Only then does it pass an independent byte copy to `FilePicker.saveFile`, whose
Android implementation opens the Storage Access Framework create-document
picker. Network partials, malformed streams, late frames, and error bodies never
reach the SAF seam or receive an app-chosen filesystem path.

The controller closes its independent transport when the tablet panel loses
foreground/window focus, the account or session changes, or the resource list
loses the exact account/resource/ACL revision. Late callbacks cannot publish.
The UI distinguishes lost login, forbidden access, changed authority, late
frames, cancellation, and other verification failures with fixed localized
English and Turkish messages. Buttons retain a 48 logical-pixel target and
keyboard/TalkBack semantics at 2x text scale on compact tablets and DeX widths.

The v1 Client pilot still requests provider revision `1`. It can consume a first
uploaded product object through the existing verified download/SAF path. Reading
the descriptor, selecting a local source, uploading, and following replacement
revisions in the tablet UI remain the next Client slice.

## Deliberately open work

S08.10 still requires the Android upload/settings flow, media-specific transfer
protocols, Client receipt/history integration on main, and physical SAF
acceptance. Range and resume remain unsupported until they receive a separate
authority, integrity, quota, and recovery design. This pilot makes no physical
device or live-LAN acceptance claim.
