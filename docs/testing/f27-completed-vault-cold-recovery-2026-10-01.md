# F27 completed vault cold recovery — 2026-10-01

## Scope

This slice makes a completed F27 download recoverable by a new controller in the same authenticated Core account without downloading the provider bytes again. It does not yet add token-free cold-start account projection or an offline downloads screen; those remain a separate phase because cached credentials must not be treated as authenticated Core authority.

The recovered record retains the exact grant, Core, home, account, account revision, session family, installation, snapshot, Jellyfin service, item and media-key authority returned by Core. The local scope comparison uses the current authenticated Core/home/account/session-family tuple. The installation and revision facts are retained as grant evidence and remain available to the existing catalog binding comparison.

## Encrypted durable record

The vault writes `completed.manifest.v1` only after Core has returned a complete progress manifest. The strict manifest JSON is AES-256-GCM encrypted with the existing per-grant secure-storage key and grant-specific associated data. Title, media key, provider details and content bytes are never written into a plaintext index.

Recovery is existing-only:

- the vault scans at most 256 exact 32-hex grant directories without following links;
- a missing directory or secure key fails closed and is never created by a read;
- the manifest and every chunk must be regular files with the exact bounded names;
- the chunk sequence, offsets, sizes, total byte count and whole-file SHA-256 must match the completed manifest before playback is exposed;
- unexpected files, symlinks, duplicate matching manifests, expired records, AEAD failure and digest mismatch cannot produce a playback lease.

The random loopback playback URL remains process-local, range-bounded and `no-store`. Playback verifies the completed record again before binding the loopback server, and individual chunk decryption still authenticates its grant and offset.

## Lifecycle

`ServerOfflineMediaController.loadCompletedItem` restores only under its original current authenticated account generation and exact session identity. Late reads after account, route or session retirement are discarded. An absent record can proceed to the normal Core download path; an integrity failure is surfaced as `offline_media_integrity_failed` and must not trigger a redownload fallback.

Account retirement keeps the old exact local scope long enough to purge its completed encrypted records. The currently retained incomplete grant is purged separately because it has no completed manifest to index. Explicit remove continues to revoke Core when reachable and always deletes the local grant key and directory.

## Evidence

The focused vault loopback test covers encrypted manifest and chunk bytes, process-object reconstruction, exact account revision retention, full-hash recovery, range playback, scope purge, missing-key and missing-directory non-creation, manifest tamper and a symlinked grant. The controller loopback test performs an authenticated Core catalog resolution and completed download, stops the Core fixture, reconstructs the controller and vault, opens the recovered bytes, verifies that no Core request or redownload occurred, then signs out and observes deletion of the exact grant directory and secure key. The separately owned player-source integration test rejects corrupted recovery without falling back to a redownload.

Focused evidence:

- `flutter test test/features/server/server_offline_media_vault_loopback_test.dart test/features/server/server_offline_media_core_loopback_test.dart`: the three vault cases passed; after adding the missing `/context` fixture response, the two Core/controller cases passed. No screen or catalog UI WIP test was used as evidence.
- scoped `flutter analyze` across the three production files and two focused tests: no issues.
- `git diff --check` across this slice: clean.

Root independently repeated the two focused files: **5 passed**, and analyzed
the exact five production/test files with **no issues**. The private run log is
`/private/tmp/larenor-offline-cold-vault-root-20261001.log`. This confirms the
scope described above; it does not claim the later offline screen is complete.

Current authenticated-account recovery is software-complete for this slice. A secure token-free active-profile projection, cold application startup while Core is unreachable, and the user-facing offline downloads route remain open and must not be inferred from this evidence.
