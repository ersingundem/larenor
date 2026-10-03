# F62 private Gateway enrollment UI

This is a private FINAL.FUNCTION integration overlay based on the frozen
schema-6 transfer/Gateway client. It has not been copied into the shared
workspace and does not change the public capability result: `rdGateway` and
`files` remain false until owned-host effect acceptance passes.

## Normal flow and authority

The existing Core-managed RDP profile editor now owns the two-stage enrollment
flow. The first stage calls `inspectGateway` with only the target and Gateway
identities. It receives a closed public Gateway SPKI fingerprint and requires
an explicit user acceptance. The second stage resolves a one-use, device-only
Gateway password buffer and calls `inspectTargetThroughGateway` with the
accepted Gateway pin. It receives the target SPKI fingerprint and requires a
second explicit acceptance.

Every stage is bound to the current Core account generation, session family,
home, profile id and profile revision. Route/account/profile retirement closes
the exact native inspection, rejects a late result and wipes the owned password
buffer. Changing target or Gateway fields after an observation prevents the
pins from being committed.

The accepted Core projection contains only the target domain and pin plus the
Gateway host, port, username, domain and pin. It contains no password, secret
reference, URI or native request identity. The Core PATCH and its authenticated
collection readback complete first. The Gateway password is then published to
the device vault under the resulting profile revision. If that device write
fails, the UI remains in an explicit failure state and never presents the
profile as ready. The user may re-enter the password; no stored enrollment
operation is replayed.

The password text controller is cleared immediately before the target
inspection. Temporary and current vault records are scoped by the Core-managed
namespace digest, canonical profile reference and exact profile revision.
Temporary records are deleted after the target inspection and every owned byte
buffer is wiped on success, failure, retirement and disposal. Dart strings
cannot provide a physical memory-erasure guarantee; this slice claims bounded
owned byte-buffer wiping and device-only encrypted storage only.

Temporary publication also returns a process-private deletion-only capability
for the exact created record. The capability carries no resolve or publish
operation, so the inspection's authority can retire without turning cleanup
into reusable credential access. Cleanup is idempotent and verifies deletion;
an unavailable secure store leaves an explicit retry action rather than
reporting success.

After a changed public projection and its new device secret are both published
and read back, the editor retires the exact old revision's current pointer and
secret. Cleanup compares the captured reference before deleting a current
pointer, so it cannot erase a newer publication in the same scope. A cleanup
failure leaves the new profile visible only with an explicit cleanup error and
retries local deletion without repeating the Core PATCH. Deleting an RDP
profile captures the same deletion-only capability before the Core mutation,
then removes the old schema-6 pointer and secret through the existing typed
local-cleanup retry path.

## Frozen wire

The Kotlin enrollment contract is unchanged:

- `inspectGateway` receives exact schema 6
  `{schemaVersion,requestId,target:{host,port,username},gateway:{host,port,username,domain}}`
  and returns `{schemaVersion,requestId,kind:'gateway',certificateFingerprint}`.
- `inspectTargetThroughGateway` receives exact schema 6
  `{schemaVersion,requestId,target:{host,port,username,domain},gateway:{host,port,username,domain,certificateFingerprint},gatewayPassword:Uint8List}`
  and returns the same closed receipt with `kind:'target'`.
- Ordinary sessions remain schema 4, SAF grants remain schema 5, and only owned
  transfer/Gateway operations use schema 6.

The normal Core RDP panel selects the owned schema-6 open path when the public
Core projection contains an accepted Gateway, even when no SAF grant exists.
That request carries a positive session revision, `files:false`,
`fileTransfer:null`, and the accepted Gateway identity/pin. The current
device-only Gateway secret is resolved into an owned byte buffer; if the target
password still needs user input, the buffer remains bound to that exact pending
password decision and is wiped on submission, cancellation, error, retirement,
or disposal. A Gateway-only open performs no SAF prepare, observe, drain, or
save operation. Sessions with neither Gateway nor transfer stay on the ordinary
schema-4 path.

The Core profile decoder remains backward compatible with the exact legacy
seven-key shape. It also accepts the closed eight-key RDP projection for both
direct RDP (`gateway:null`) and an enrolled Gateway; other protocols cannot
carry a non-null RDP security projection.

## Private verification

The isolated Flutter project exercises the real production editor, Core API,
controller, schema-6 enrollment coordinator, secure-vault adapter and normal
Riverpod composition. Focused regressions cover the closed Core PATCH/readback,
two explicit certificate acceptances, separate secret storage, late result
after account retirement, completed-observation invalidation, password-buffer
wiping, device-secret publication failure after a successful Core mutation,
old-revision cleanup without Core replay, cleanup retry, and profile deletion.
The same focused gate exercises the normal panel/controller and MethodChannel
request for Gateway-only schema 6 and proves `fileTransfer:null` with zero SAF
lifecycle calls. A closed negative case also proves that schema 6 with neither
an accepted Gateway nor a file transfer is rejected before any native call.

This is client composition evidence. It does not prove live Gateway TLS/NLA,
RDPDR bytes, native drain, DocumentsProvider effects, or physical-device secret
storage. Those acceptance gates remain open and the related capabilities remain
false.

The follow-up candidate was verified in
`/private/tmp/larenor-f62-schema6-gateway-enrollment-followup-gate-20261003`.
Ten focused production test files completed 139 tests with zero failures or
skips; the private log SHA-256 is
`4cdf0c7756b0829bfd88318c061796265933049e25135eb8f2334f615424d245`.
Scoped analysis of 26 Dart production/test paths reported no issues; its log
SHA-256 is
`7029f37f98f2ed66feca31797344d6b6458d1bbc07985a89fe69a8b0734f18a5`.

## Follow-up 2: durable secret publication

The secure-vault rotation now holds the process-wide configuration-write
ownership from its first current-pointer read through its final cleanup. A
newly generated secret is treated as owned before its storage write starts, so
a write that persists and then throws is erased through an exact deletion-only
path even if the profile authority retires.

Current-pointer publication is committed only after exact readback. Failure or
authority retirement conditionally rolls back only when the pointer still
names that operation's new reference; a concurrent successor pointer is never
deleted. A closed durable cleanup record binds the exact previous and next
references while rotation is in progress. Recovery keeps the reference named
by the current pointer, erases the other exact reference, and then removes the
cleanup record. It grants no resolve, publish, or secret-read capability.

This also covers a confirmed current-pointer publication followed by an old
secret deletion or rollback readback failure. The operation reports failure,
retains its closed cleanup record, and the next authorized current-secret
operation reconciles it once. A failed rotation either restores the previous
pointer and secret or leaves a coherent new pointer plus the durable cleanup
record; it never reports successful cleanup from an uncertain outcome.

Six additional regressions cover write-then-throw cleanup, retirement after
pointer write, retirement during pointer readback, rollback and explicit retry,
and durable reconciliation for both possible uncertain rollback positions.
The same ten focused production test files completed 145 tests with zero
failures or skips; the private log SHA-256 is
`1725ad04d8934a813a433bcdf5a8f4ec8c590a8a4f2f4d7ee7716154a40e1784`.
Scoped analysis of the same 26 Dart production/test paths reported no issues;
its log SHA-256 is
`5874fe9c04e4a52d11fa58982f50ecc829e1529b35e34e2b796b79be33dd1e87`.

## Follow-up 3: durable candidate-to-owner handoff

A generated secret is now preceded by a durable, closed cleanup intent for its
exact scope, kind and candidate reference. The intent is confirmed before the
candidate secret write begins. After exact secret readback, the record changes
to one of three closed purposes: direct saved reference, temporary enrollment,
or pending current-pointer adoption. This transition occurs while the same
serialized configuration write still owns the operation.

The intent is not removed merely because the secret write completed. A direct
saved reference adopts it when that exact reference is resolved or deleted. A
temporary enrollment keeps it until its deletion-only cleanup object removes
the exact secret. A pending current secret is adopted only when exact current-
pointer readback names the same reference; otherwise restart reconciliation
deletes the candidate. Consequently, authority retirement or process death at
any await boundary leaves either a durable owner or a discoverable cleanup
intent.

If secure storage persists a secret and then reports a write failure, or if
current-pointer publication commits and then throws, a failed immediate secret
deletion leaves the intent in place. The next serialized vault operation
reconciles it before live authority checks. This deletion-only recovery grants
no resolve, reuse, publication or current-pointer capability. Invalid or
unreadable intent records fail closed.

Four new regressions cover temporary and first-current write-then-throw with
deletion failure, retirement during the candidate-to-temporary handoff, and a
first current-pointer commit failure followed by successful pointer rollback
and failed secret deletion. Each restart removes the exact unadopted candidate
and intent and returns no current secret. The complete focused vault file
passed 17 tests with no failures or skips. Scoped analysis of the changed vault
and its focused test reported no issues. This is private lifecycle evidence;
live Android secure-storage and Gateway effects remain separate acceptance
gates.

## Follow-up 4: cross-revision and profile-deletion retirement

Capturing an existing current Gateway secret for replacement or profile
deletion now writes and reads back a bounded deletion-only retirement index
before the Core PATCH or DELETE may begin. The index is keyed by the exact
Core-managed namespace and secret kind, and each of its at most 32 records
contains only the canonical profile reference, old profile revision and opaque
device-secret reference. It contains no secret bytes and grants no resolve,
publish or reuse operation.

The exact in-process cleanup removes the captured old-revision current pointer
when it still names that reference, removes the exact secret, confirms both
deletions and only then removes the retirement record. A deletion failure keeps
the record. A later process or route instance reads it using a fresh,
authenticated and complete Core profile inventory. An equal profile revision
proves the Core mutation did not commit, so reconciliation confirms the old
pointer and secret still agree, preserves them and cancels the intent. A higher
revision or an absent profile proves the old authority is retired, so
reconciliation repeats only the exact local deletions. A lower revision,
malformed record, duplicate profile reference, oversized inventory or unknown
pointer fails closed.

The Core-managed profiles screen schedules this readback-only reconciliation
only while its controller has a fresh verified snapshot and no Core mutation or
local cleanup in progress. It derives the namespace and profile references from
that exact authenticated account, home and token family. This avoids treating
the pre-mutation snapshot as deletion authority and preserves the existing
visible retry path for same-process cleanup failures. Reconciliation never
replays a Core PATCH/DELETE, Gateway inspection or provider operation.

Five focused vault regressions cover process death after revision `R` is
published as `R+1`, an uncommitted mutation that remains at `R`, process death
after profile deletion, exact deletion failure followed by restart, and the
32-record bound. A widget regression exercises the real Core DELETE, an exact
secure-storage deletion failure, route disposal and a new controller instance;
the fresh empty Core inventory removes the retained pointer, secret and index
without a second Core DELETE. These are private software lifecycle proofs. They
do not prove Android keystore durability or live Gateway connectivity.

The complete focused vault file passed 21 tests with no failures or skips; its
private log SHA-256 is
`2029c533d185358a573389de63e0da0ce62cff16d3bff4797170f0ff902050f2`.
The Core-managed tablet file passed 24 widget tests with no failures or skips;
its private log SHA-256 is
`3b6aedd2ad4264059d179c6e7030c6df2f5e269495b6c0e22fa2ed0668cd6476`.
Scoped analysis of the four changed Dart source/test files reported no issues;
its private log SHA-256 is
`68314a8a741c515c58013bcd49922c643c79bc0b6954c6979a4572d53dba5da1`.
