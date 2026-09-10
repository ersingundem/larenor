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

Production starts with an empty provider. Trusted packaged Core code may inject a
provider that resolves only a registry resource ID to immutable bytes, a media
type, and a service revision. HTTP callers cannot supply a filesystem path, URL,
provider name, or command. The synthetic provider exists only in tests.

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

## Deliberately open work

S08.10 still requires product resource providers, Android Client download UX and
receipt persistence, upload/media transfer protocols, and device acceptance.
Range and resume remain unsupported until they receive a separate authority,
integrity, quota, and recovery design. This pilot makes no live-network or
production-resource acceptance claim.
