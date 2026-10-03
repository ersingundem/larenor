# F62 SAF grant stage 1 — native evidence (2026-10-03)

## Scope

This slice establishes an Android Storage Access Framework grant lifecycle for a future RDPDR file-transfer mirror. It does **not** enable the RDP `files` capability, enumerate documents, mirror bytes, or claim a remote file-transfer effect. RDP session and microphone methods remain schema 4; the five SAF grant methods alone use schema 5.

The user chooses a tree through the platform `ACTION_OPEN_DOCUMENT_TREE` surface. The app asks for read, write, and persistable access, then independently reads Android's persisted-permission registry before returning a prepared receipt. No URI, display name, filesystem path, namespace digest, or profile reference crosses the response wire or appears in a diagnostic.

## Authority and wire

Every select, activate, observe, and retire request carries this closed authority value:

```text
{schemaVersion:5, namespaceDigest:<64 lowercase hex>,
 profileRef:<64 lowercase hex>, profileRevision:<1..2^53-1>}
```

Native code derives the public authority identifier as:

```text
sha256(UTF8("larenor-rdp-saf-authority-v1\0" + namespaceDigest +
            "\0" + profileRef + "\0" + decimal(profileRevision)))
```

The caller cannot supply `authorityId`. Responses contain the derived digest, a random 32-hex grant ID, a positive JS-safe revision, and one closed state (`prepared`, `active`, `retired`, or `unknown`). The only native errors are `busy`, `cancelled`, `permission_denied`, `authority_changed`, `unavailable`, and `invalid_request`.

## Durable side-effect ordering

The encrypted ledger is an `AtomicFile` under `noBackupFilesDir`; its directory is mode `0700`, its file is mode `0600`, and its payload is AES-256-GCM sealed by a non-exportable Android Keystore key. Test-only constructors accept an in-memory AES key and isolated directory. The decoder is exact-key, size-bounded, duplicate rejecting, and fail closed. Tamper or key loss preserves the evidence and returns `unavailable`.

The encrypted envelope is capped at 2 MiB. A maximum-shape regression writes
and reloads all 256 permitted records with 4096-character provider URIs; the
sealed/base64 envelope remains within that bound. Larger or hostile input is
rejected before an unbounded read.

The picker lifecycle records a durable `select_pending` entry before DocumentsUI launches. A successful picker result is held without any permission or storage side effect while the owner Activity is stopped, paused, or unfocused; it resumes only when the same broker is resumed and focused. This exception is limited to the exact picker request because DocumentsUI legitimately stops the owner Activity. Explicit cancel, controller authority retirement, or bridge disposal still cancels it. An unrelated/stale activity result has zero effect.

Before `takePersistableUriPermission`, the broker records the URI only inside the encrypted ledger together with the permission flags observed before the call. It returns `prepared` only after the required read/write permission appears in `ContentResolver.persistedUriPermissions`. A crash after dispatch remains observable as `unknown`; restart reconciliation may promote it to `prepared` only when readback proves the exact permission exists. It never replays an uncertain take call.

Retirement writes `retire_intent`, then `release_dispatched`, before calling `releasePersistableUriPermission`. The grant becomes `retired` only when readback proves the flags acquired by this grant are absent, or when they are deliberately retained because they pre-existed or another live ledger record still references them. Throw, lost acknowledgement, or ambiguous readback remains `unknown`. Observation can finish a previously dispatched release from readback, but never redispatches it.

Prepared grants expire after the bounded picker/grant deadline. Active grants require explicit retirement. Recent tombstones retain exact request replay evidence; compaction removes only old retired history while preserving the newest revision for each authority. Limits are 32 records per authority and 256 globally.

## Verification

Focused tests cover:

- strict schema parsing, canonical authority digest, and response redaction;
- encrypted restart readback, exact filesystem modes, symlink/tamper/wrong-key rejection, duplicate and capacity rollback;
- real picker stop/focus deferral followed by one permission take;
- missing result flags, explicit cancellation, stale callback isolation, and prepared expiry;
- exact activation replay, changed-body/stale-authority rejection, and permission revalidation;
- full external permission revocation retiring without a release call, and partial
  revocation retaining only the still-live app-owned bit as durable `unknown`;
- durable release ordering, lost-release acknowledgement, restart readback, and zero redispatch;
- preservation of pre-existing/shared URI grants;
- MethodChannel routing and the exact MainActivity result-code boundary.

The composed product gate at `/private/tmp/larenor-ri5-native-passed-6gzp_8ez`
ran 146 JVM tests with zero failures, errors, or skips: 55 Moonlight tests,
78 existing RDP tests, and 13 SAF grant tests. It also compiled the production
Kotlin and AndroidTest Kotlin source graph (315 tasks). This is local software
evidence; it does not prove DocumentsUI behavior on a physical device or an
RDPDR byte effect.

A later stage must still implement the private SAF mirror/drain, RDPDR drive
callbacks, bounded transfer cancellation, and an owned-host byte-effect
acceptance before `channels.files` can become true. The v4 capability remains
`channels.files=false`, and this schema-5 grant surface does not change it.

Root subsequently verified 94/94 RDP JVM tests with zero failures, errors,
or skips (78 existing RDP + 16 SAF), plus actual AndroidTest compilation.
The 227-source manifest remained unchanged; SHA-256:
`0a7f1daa38f71d22f99d6c35bc9045c9150dd1ca9e2ab6eaced8162a9264e7c1`.
After fixing same-request activation replay, root ran the final 18 SAF tests:
18/18 passed, zero skips/errors/failures, unchanged source manifest
`031c0297fa465ca06dfa79e48d5c43c91c8691118a349446ae2db20d10a0a6fe`.
Its private log SHA-256 is
`380830e7372a43e2ee97a0660eedd80f750edf22425c13dfaec718147a8200f8`.
