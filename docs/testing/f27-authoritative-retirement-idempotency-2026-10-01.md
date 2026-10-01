# F27 authoritative retirement idempotency evidence

The completed-download restart path keeps its encrypted manifest and chunks in
the local vault and can open them without contacting Core or downloading the
item again. An authoritative account retirement must then remove that exact
scope once.

`ServerAccountController.signOut()` emits when it retires the in-memory session
and again after persistence and remote logout finish. The online offline-media
controller previously started an unawaited scope purge for both emissions. Two
purges could enumerate and delete the same authenticated grant concurrently;
the vault correctly rejected the resulting disappearing directory as an
invalid record. The vault's fail-closed record, symlink, and tamper checks remain
unchanged.

The controller now coalesces overlapping authoritative retirement emissions
into one cleanup operation for its captured account generation. It marks that
authority cleanup complete only after the exact captured grant and scope have
been purged. A filesystem, integrity, or secure-storage failure is caught as the
bounded `offline_media_cleanup_failed` status; the original grant and scope stay
available for a later authoritative account emission to retry. Transient
account work still retires playback without purging and does not suppress that
later cleanup. The local-media controller uses the same completion rule.

The focused loopback regression blocks the first root lookup, lets both real
sign-out emissions occur, and synchronously reenters retirement from a
controller listener. It proves that the single-flight reservation is published
before either callback can start another purge. The test then forces that owned
cleanup to fail, observes the bounded failure without an unhandled asynchronous
error, disposes the route-owned controller, and sends a later real account
event. A pending cleanup keeps only its account listener and captured scope
until success, so it survives route disposal without retaining playback or UI
state. The retry removes the directory and secure key exactly once while
retaining the existing zero-Core-request and zero-redownload assertions. A
permanent I/O failure remains pending and is never reported as successful.
Vault integrity checks remain unchanged.

This software gate covers controller restart, local encrypted playback, and
idempotent logout cleanup in an owned loopback fixture. Provider availability,
native decoder behavior, and physical offline playback remain separate gates.

## Root verification

Root ran the new deterministic overlap regression against the old controller:
RED, expected one retirement-root lookup but observed two. After restoring the
fixed source, the composed Core loopback, vault loopback and offline-downloads
screen gate passed **21 tests, 0 failures, 0 skips**. This preserves restart
without Core/redownload, secure-key removal and the unchanged vault integrity
checks. Agent focused Core loopback gate passed2 tests and scoped analysis was
clean. Broad changed-source branch CI remains required.

Root final composed source gate passed **49 tests, 0 failures, 0 skips** across
the two game-stream controller/screen modules and the three offline Core/vault/
download-screen modules. This includes the final retry, route-disposal,
reentrant cleanup and cold-recovered session fixes; earlier named counts remain
source-specific evidence. Required broad branch-source CI remains separate.
