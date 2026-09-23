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

The current focused Server playback suite passes **9/9**; the grouped playback,
catalog-read and flow package passes **40/40**. The current Flutter playback,
catalog tablet and real-loopback package passes **20/20**. Earlier accepted
broader groups remain recorded by their exact commits above.

## Remaining S08.8 acceptance

The production playback backend still needs a configured provider adapter and
real-device verification; this slice only defines and tests its fail-closed
Core seam. Accessible migration of retained Jellyfin preferences, integration
of the completed cache primitives into user-facing media flows, broader
same-URL replacement/logout E2E, independent review and exact-head CI remain
open. Neither progress counter advances.
