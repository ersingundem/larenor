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
- The Client follows catalog → detail → managed playback through Core only.
  Exact parsers reject unknown and secret-shaped fields. Account generation,
  route visibility and application lifecycle retire delayed prepare/command
  results; a one-use intent cannot be replayed locally.
- The tablet requires a visible player choice and confirmation. Members can
  play without calling administrator diagnostics, while administrators retain
  the existing read-only central flow evidence. English and Turkish layouts at
  600/1200 logical pixels and 2x text retain semantic 48-pixel controls.

## TDD evidence

- Server RED `f435c262fc86b4d43cd4ab2a06378b0e6e0c6faf` failed because the
  playback contract did not exist. GREEN
  `cc4b9fcefb0813aaa2c383d01b17baeddb8fd8aa` added the schema, durable
  intent/receipt service, member/admin API policy and authority boundaries.
- Client RED `3e4bc3471d5489cc631402e63322746b5f47cbf1` failed because the
  strict Core adapter and controller did not exist. GREEN
  `e1cae401bc14dda14a7662a2120e61b5885442ad` added the exact model/API and
  lifecycle-bound controller with no direct provider fallback.
- Tablet RED `0eaad8e74054e471d867ee03320d05a3cc4cdd2b` failed on the absent
  managed-playback controls and late-result behavior. The following GREEN
  implementation adds the confirmation journey, real loopback HTTP replay,
  member policy, route retirement and EN/TR accessibility matrix.

Focused Server playback/catalog/flow tests pass **42/42** and targeted Ruff is
clean for every new Server module and test. The grouped Flutter playback,
catalog, flow, loopback and tablet package passes **33/33** tests with targeted
analysis clean.

## Remaining S08.8 acceptance

The production playback backend still needs a configured provider adapter and
real-device verification; this slice only defines and tests its fail-closed
Core seam. Accessible migration of retained Jellyfin preferences, integration
of the completed cache primitives into user-facing media flows, broader
same-URL replacement/logout E2E, independent review and exact-head CI remain
open. Neither progress counter advances.
