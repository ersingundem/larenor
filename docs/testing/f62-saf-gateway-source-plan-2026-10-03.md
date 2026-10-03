# F62 SAF file redirection, RD Gateway, and open-boundary plan (2026-10-03)

## Scope and current boundary

This document records source research and a bounded implementation plan. It is
not acceptance evidence. F62 remains open for Android Storage Access Framework
(SAF) file redirection and Remote Desktop Gateway (RD Gateway).

The current microphone-v4 package truthfully reports `channels.files=false` and
`security.rdGateway=false` in `RdpFreeRdpPackage.capabilities()`. The native
negotiator rejects requested file redirection with `channelUnavailable` and a
configured gateway with `gatewayUnavailable`. The packaged runtime also returns
`false` when `request.gateway != null`, its `OnGatewayAuthenticate` callback
always returns `false`, and its URI contains neither `/drive` nor `/gateway`.
These are real fail-closed boundaries; they are not implementations of the two
features.

Larenor already has real one-document SAF integrations. For example, Core
backup import uses `ACTION_OPEN_DOCUMENT`, while Core backup and WebPanel
exports use `ACTION_CREATE_DOCUMENT`. They validate `content:` URIs and keep
their operation ownership bounded. They do not select a directory tree, retain
a directory permission, expose a POSIX directory to FreeRDP, or reconcile a
remote drive. The schema-5 grant slice now implements owned `ACTION_OPEN_DOCUMENT_TREE`
and `takePersistableUriPermission` with encrypted restart/revocation readback.
It keeps file redirection disabled. `DocumentsContract` transfer, private mirror,
real native drain, explicit save/readback and Gateway remain open. See
[grant evidence](f62-saf-grants-native-2026-10-03.md) and
[client lifecycle evidence](f62-saf-client-2026-10-03.md).

## Primary source findings

The plan is based on these pinned or platform-owned sources:

- Android's [Storage Access Framework guide](https://developer.android.com/guide/topics/providers/document-provider)
  defines `ACTION_OPEN_DOCUMENT`, `ACTION_CREATE_DOCUMENT`, and
  `ACTION_OPEN_DOCUMENT_TREE`. It also explains that providers expose documents
  through `content:` URIs and that tree roots may be transient.
- Android's
  [`ContentResolver.takePersistableUriPermission`](https://developer.android.com/reference/android/content/ContentResolver#takePersistableUriPermission(android.net.Uri,%20int))
  is the platform mechanism for retaining a picker-granted URI permission. A
  persisted grant is still subject to provider availability and user revocation.
- Android's [`DocumentsContract`](https://developer.android.com/reference/android/provider/DocumentsContract)
  is the API for creating, finding, renaming, deleting, and inspecting documents
  in a selected tree. A document ID is not a filesystem path.
- Pinned FreeRDP 3.31.1 command-line source at commit
  `63b948ca5cb94307fd5444ee6e73927a41ccdab4` defines `/drive` as a required
  `<name>,<path>` option in
  [`client/common/cmdline.h`](https://raw.githubusercontent.com/FreeRDP/FreeRDP/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/common/cmdline.h)
  and parses the option in
  [`client/common/cmdline.c`](https://raw.githubusercontent.com/FreeRDP/FreeRDP/63b948ca5cb94307fd5444ee6e73927a41ccdab4/client/common/cmdline.c).
- The pinned drive client operates on a local path with `CreateFileW`,
  `ReadFile`, `WriteFile`, directory, rename, seek, and delete APIs in
  [`channels/drive/client/drive_file.c`](https://raw.githubusercontent.com/FreeRDP/FreeRDP/63b948ca5cb94307fd5444ee6e73927a41ccdab4/channels/drive/client/drive_file.c).
  It has no Android `ContentResolver` or `content:` URI adapter.
- FreeRDP's pinned gateway command-line parser accepts gateway host, username,
  domain, and password settings in the same pinned `cmdline.c`. The certificate
  callback flags define `VERIFY_CERT_FLAG_GATEWAY` in
  [`include/freerdp/freerdp.h`](https://raw.githubusercontent.com/FreeRDP/FreeRDP/63b948ca5cb94307fd5444ee6e73927a41ccdab4/include/freerdp/freerdp.h),
  and pinned TLS code sets the flag for gateway transport in
  [`libfreerdp/crypto/tls.c`](https://raw.githubusercontent.com/FreeRDP/FreeRDP/63b948ca5cb94307fd5444ee6e73927a41ccdab4/libfreerdp/crypto/tls.c).
- Microsoft's [MS-TSGU overview](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tsgu/0a6e29eb-c949-4544-88a0-5306f3eed4e9)
  describes the gateway tunnel and channel to the target server. Its
  [connection setup and authentication section](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tsgu/f4de010f-ee2b-4f6f-bf26-7792ac1b38e4)
  requires a secure HTTP connection and gateway server certificate
  authentication before user authentication.

## SAF file-redirection composition

### Consent and durable authority

The user must explicitly choose a transfer directory with
`ACTION_OPEN_DOCUMENT_TREE`. Larenor may retain only the granted read/write
flags returned by that picker and must call `takePersistableUriPermission` with
no broader flags. The private record should contain the tree URI, granted flag
set, owning profile/account authority, a monotonic record revision, and a
non-secret provider/document identity digest. It must not contain a guessed
filesystem path.

Every session open, recovery, transfer, and commit must revalidate all of the
following before and after I/O:

- the exact current profile, account, route, foreground, and RDP request;
- the persisted URI permission and current provider availability;
- the selected document's relationship to the granted tree;
- the private transfer-journal revision and the exact session generation.

Revocation, sign-out, profile replacement, foreground loss, cancellation, or a
provider disappearing retires the operation. A late picker or provider result
cannot revive it.

### Session-private filesystem mirror

FreeRDP requires a real directory path. The safe bridge is therefore a
session-private, mode-0700 mirror owned by the app, not the SAF URI itself. A
per-session root contains fixed `ToRemote` and `FromRemote` directories. Only
that root is passed to `/drive:<fixed-name>,<private-path>`; the path is never
returned to Dart or written to a public receipt.

Before connect, user-selected upload documents are copied from
`ContentResolver` into `ToRemote` with bounded size, regular-file semantics,
digest, fsync, atomic rename, and an exact journal entry. The remote can read
those staged bytes. Remote writes land only in `FromRemote`. On explicit user
commit or terminal drain, Larenor validates each mirror entry, resolves a child
document under the still-authorized SAF tree with `DocumentsContract`, writes
through a `ParcelFileDescriptor`, fsyncs when supported, reads back size and
digest, and only then records a committed receipt.

Remote mutation of the mirror is not equivalent to SAF publication. A native
IRP success, presence in `FromRemote`, or a byte-count match alone cannot be
reported as a saved document.

### Cancellation, retirement, and recovery

The private journal must distinguish staged uploads, remote-open/in-flight
files, downloaded-but-uncommitted files, SAF-commit-in-progress, committed
files, and unknown effects. Cancellation stops new RDPDR I/O, closes the RDP
session, waits for the exact native drive context to drain, then reconciles the
mirror. If shutdown interrupts a SAF write, recovery reopens only the exact
journaled document and verifies its state; it never silently retries a picker,
remote write, rename, or delete.

Process restart may recover private mirror and journal state, but it cannot
recreate the old RDP session or assume a provider is still mounted. Unknown
remote or SAF effects remain unknown until readback. Private staging is deleted
only after a verified commit, verified cancellation with no effect, or an
explicit user discard.

### Prohibited shortcuts

The implementation must not:

- convert a `content:` URI to a `_data` path;
- pass `content:` or `/proc/self/fd/*` to `/drive`;
- redirect app home, shared storage, or `*`/`home` convenience drives;
- request `MANAGE_EXTERNAL_STORAGE` or infer consent from an unrelated picker;
- call a staging copy a remote transfer or call an RDPDR response a SAF commit;
- persist provider secrets, raw document names, paths, or transferred bytes in
  logs, diagnostics, public receipts, or Core-facing state.

### Actual acceptance

The software gate needs a real packaged Android client and an owned RDP server
with the drive channel enabled. It must prove, through one exact session:

1. a user-granted source document is staged and read by the remote endpoint;
2. a distinct remote-created file reaches `FromRemote`, is explicitly committed
   into the selected SAF tree, and is read back byte-for-byte;
3. cancellation during upload and download performs no automatic replay;
4. grant revocation, provider loss, account/profile drift, stale callbacks, path
   traversal, symlinks, size overflow, and digest mismatch fail closed;
5. restart reconciles a prepared or unknown journal without reusing the old RDP
   session; and
6. a second session cannot observe or mutate the first session's private mirror.

The public receipt may expose only fixed stages, bounded counts, and booleans.
It must not expose URI, provider, path, filename, bytes, credentials, or a drive
handle.

## RD Gateway composition

RD Gateway needs a second authenticated security boundary. The profile and
request contract must include a gateway host, port, username/domain reference,
and a separate gateway SPKI pin. Gateway and target credentials remain separate
private secrets. The packaged URI may then use FreeRDP's `/gateway` option and
the runtime may satisfy `OnGatewayAuthenticate` from the exact current gateway
secret.

Certificate verification must inspect `VERIFY_CERT_FLAG_GATEWAY`: a gateway TLS
callback is matched only against the gateway identity and gateway pin, while a
target TLS callback is matched only against the target identity and target pin.
One pin cannot authorize both peers. The target session must still require NLA,
the existing TLS policy, and the target SPKI after the tunnel is established.
Gateway credential or certificate failure must not fall back to a direct target
connection.

The current security-store key is profile scoped and the current public gateway
shape has no gateway pin. Those contracts must be revised atomically before
`rdGateway=true` can be advertised. Rotation, deletion, route/account drift,
backgrounding, and session retirement must clear both secret buffers and retire
the exact tunnel generation without touching a successor.

Actual acceptance requires an owned Windows RD Gateway with the direct route to
the target blocked. The gate must prove the correct gateway pin plus credentials
and authorization policy permit a target NLA session, then prove wrong gateway
pin, wrong target pin, wrong gateway credentials, and denied gateway policy all
fail without direct fallback. A successful TCP connection, certificate callback,
or gateway credential prompt is not an accepted target session.

## Failure-only packaged open-boundary design

The 5122 hosted failure reached `firstSessionOpen` and threw the closed public
`RdpNativeFailure` code `connectionFailed`. The exact underlying cause is not
recoverable from that code. The schema-2 and current schema-3 implementations
collapse URI setup, native connect rejection, connection failure/disconnect,
authentication completion, DISP readiness, initial layout submission, security
publication, and timeout into one `FreeRdpOperation.start()` Boolean. The
certificate probe deliberately stops before credentials, NLA, DISP, and a live
session, so its success does not narrow the open failure.

A next diagnostic should be process-private and bound to the exact operation
instance, request ID, package identity, source hash, and named hosted test nonce.
It should contain only these finite facts:

- `connectionInfoParsed`: pinned `setConnectionInfo` accepted the exact URI;
- `connectAccepted`: JNI accepted the connect invocation. This does not mean a
  network connection or authentication succeeded;
- `certificateAccepted`: the target certificate callback matched the expected
  SPKI. This is not NLA success;
- `authenticatedConnectionSucceeded`: the exact operation received
  `OnConnectionSuccess`, the existing authority after NLA;
- `displayCapsObserved`: the exact instance received
  `OnDisplayControlReady`;
- `initialLayoutAccepted`: `sendMonitorLayout` returned true for the initial
  exact display request;
- `securityPublished`: the authenticated security callback was delivered to the
  exact live `RdpFreeRdpSession`;
- `terminal`: one of `none`, `connectionFailureCallback`,
  `disconnectedCallback`, `localSetupRejected`, or `retired`; and
- `timeout`: true only when the bounded start deadline expires before another
  terminal outcome wins.

The facts are observations, not inferred causes. For example, absence of a
certificate callback does not mean TLS failed, and `connectAccepted=true` does
not mean the peer was reached. Callbacks must verify the registry still maps the
native instance to the exact operation. The first terminal outcome wins;
retirement, timeout, and cleanup cannot overwrite it. A late callback from a
retired operation cannot modify a successor. One terminal snapshot may be kept
in a bounded process-private slot long enough for the exact failing test to read
it, then must be consumed or replaced only by its matching request.

Publication remains failure-only. The runner may include these closed booleans
and enum values only when package receipt, source hash, test class/method, nonce,
one-test/one-failure/zero-skip counts, lifecycle stage, and request identity all
match. A diagnostic can neither turn a failed JUnit result into success nor
authorize a frame, input, channel, or retry. Unknown fields, invalid ordering,
conflicting active and terminal snapshots, replay, or a stale request leave the
run unclassified.

Focused tests should cover every local transition, callback order in both
certificate-before-DISP and DISP-before-authentication cases, URI/connect
rejection, timeout versus late callback, retirement, terminal snapshot
consumption, and successor isolation. The hosted test must still enforce the
existing TLS/NLA/SPKI, frame, ACK, input, resize, clipboard, audio, two-lifetime,
and clean-close gates; the new record only explains a failure before those gates.
