# S08.8 Core-managed media playback

This slice adds a provider-neutral, revision-pinned playback contract from the
existing Core catalog to an explicitly confirmed tablet action. It does not
repeat the Music Assistant command queue and does not close `S08.8`: queue
progress remains **26/125** and selected-feature progress remains **0/63**.

## Accepted behavior

- Core issues a short-lived intent only after checking the signed-in member or
  administrator, the exact catalog installation/snapshot/Jellyfin revisions,
  item identity and current player targets. A command consumes that intent
  before its external effect, pins the player and playback revisions, and
  persists one receipt for idempotent replay.
- An authority change before the effect stops the command. An authority change
  after the effect publishes no success and records an uncertain receipt for
  explicit recovery. The public intent/receipt schema contains no provider
  address, token or direct-service credential.
- Intent and receipt journals are bounded at 256 rows. Capacity recovery runs
  in the same transaction as the next insert: it removes expired, unconsumed
  intents and then the oldest succeeded receipt/intent pairs only. Pending or
  uncertain effect evidence is never pruned; when only that evidence remains,
  Core rejects the new command before consuming its intent.
- The Client follows catalog → detail → managed playback through Core only.
  Exact parsers reject unknown and secret-shaped fields. Account generation,
  route visibility and application lifecycle retire delayed prepare/command
  results; a one-use intent cannot be replayed locally.
- The tablet requires a visible player choice and confirmation. Members can
  play without calling administrator diagnostics, while administrators retain
  the existing read-only central flow evidence. English and Turkish layouts at
  600/1200 logical pixels and 2x text retain semantic 48-pixel controls.

## TDD evidence

- Server RED `8a2f849ec88da3172b3d1c5d75ab3f1004f824b5` failed because the
  playback contract did not exist. GREEN
  `4c507e1b99274d5ff7a991646ecd59d54afc7ace` added the schema, durable
  intent/receipt service, member/admin API policy and authority boundaries.
- Client RED `36661ef0f7bd89a4c09412c162ffe1577a4c617f` failed because the
  strict Core adapter and controller did not exist. GREEN
  `0287fff99d0bea955ba3e9ca28e5594a6aead189` added the exact model/API and
  lifecycle-bound controller with no direct provider fallback.
- Tablet RED `ec7e89887c84d10132e2e198377a5ebcb0c29af9` failed on the absent
  managed-playback controls and late-result behavior. GREEN
  `072777581eacd8d75a5a9faee04ebd0b605c7e1a` adds the confirmation journey,
  real loopback HTTP replay, member policy, route retirement and EN/TR
  accessibility matrix.
- Storage-bound RED `e144e71ca1af53608bdc6e4c49abd0aa33c697be` showed that
  the 257th intent and receipt could grow the durable journal. GREEN
  `23410ac240e63486375a306194c310ceb0666a19` enforced atomic capacity
  checks and startup bounds. Retention RED
  `142ef925f965f7ad0244c3cf258ee02cc75f4c55` then proved that a hard cap
  could permanently exhaust normal playback. GREEN
  `b8c1d1ae016dbdb9569d615ca43869e345bf1931` added safe expiry and terminal
  receipt recycling while preserving pending effect evidence.
- Receipt-binding RED `93c37e22007d77751d335396a56e720d15fcff0e`
  reproduced a constraint-valid pending receipt whose stored intent differed
  from its canonical request, yielding a false uncertain replay. GREEN
  `40d053e040feaabf31404ba9c9c7c92961190700` now validates canonical request
  and receipt payloads plus actor, intent, consumed-by, target and revision
  relationships both at startup and at replay time.
- Post-effect RED `38b208318c93fa7784f52be17e342d3978a847e4`
  showed that a changed pending binding could still publish success. Pruning
  RED `7434f62ad0b5df7242315a29da0f692658dde91d` showed that capacity recovery
  could erase a malformed succeeded candidate. GREEN
  `01f97601821287b9bd84260265bd75d5bf9116da` revalidates every prune
  candidate before deletion and performs exact transactional revalidation and
  compare-and-set finalization after the external effect.
- Production-worker RED `ce613152` specified the exact authenticated Jellyfin
  session read, one `PlayNow` POST and post-effect readback. GREEN
  `095c5fd3` added bounded HTTP parsing, process-generation revisions and
  ambiguous-effect rejection. Container-authority GREEN `ad45db1a` binds every
  stream to the exact journaled container and private control-network endpoint.
- Credential/IPC GREEN `699be352` and `2816091f` resolve the verified API key
  only from AES-GCM bootstrap storage, transport it over the same UID-checked
  worker socket and connect Core to the packaged Linux runtime. Capability
  discovery compatibility was retained by `d2d2ad24`; a worker implementation
  that does not advertise both playback methods remains unavailable.
- Authority-retention `107f3928` re-resolves the encrypted bootstrap binding
  before and after worker dispatch. API-key, plan or bootstrap-revision drift
  therefore suppresses success even when an external effect already occurred.
- Pre-effect RED `48ef1e9d` reproduced retained-authority loss and monotonic
  deadline expiry after the authenticated before-read but before the playback
  POST. GREEN `34a7bd5b` revalidates both at the effect boundary, writes no
  request after either failure, closes all opened streams and reports the
  authority change without marking an unstarted effect uncertain.
- No-effect RED `c01dc51c` proves that a mismatched opened endpoint leaked its
  stream, that a definitive pre-POST authority rejection lost its certainty at
  the worker IPC boundary, and that Core retained a false `needs_attention`
  replay. Post-effect RED `04155074` proves final endpoint drift was incorrectly
  classified as definite after the POST. GREEN `fa2aeea3` closes a mismatched
  stream, transports a strict typed failure envelope over the UID-authenticated
  socket, atomically retires the exact no-effect intent/receipt, prevents worker
  replay, and preserves uncertainty for every post-effect failure.
- Cross-stream RED `5aba624e` proved that a second stream whose fresh endpoint
  proof differed from the first could escape cleanup because comparison ran
  before ownership was recorded. GREEN `15523599` tracks each opened stream
  before comparing proofs, so the mismatch closes every connection.

The production-worker package adds **20/20** protocol/container tests and the
private IPC/credential/provider groups bring the focused Server batch to
**57/57**.
The earlier Core playback suite passes **14/14**; the grouped playback,
catalog-read and flow package passes **45/45**. The Flutter playback, catalog
tablet and real-loopback package passes **20/20**.
The final runtime/executor/IPC/provider regression batch passes **29/29**,
including both pre-effect authority/deadline boundaries.
The grouped runtime, executor, Core playback, IPC, provider and encrypted
bootstrap batch passes **64/64** after the connection cleanup fix.

## Remaining S08.8 acceptance

Physical TV/receiver verification remains separate from the now packaged
production worker. Accessible migration of retained Jellyfin preferences,
integration of the completed cache primitives into user-facing media flows,
broader same-URL replacement/logout E2E, independent review and exact-head CI
remain open. Neither progress counter advances.
