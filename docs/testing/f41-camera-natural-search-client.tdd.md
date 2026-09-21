# F41 camera recording search tablet Client — TDD evidence

## Acceptance boundary

This stacked Client slice consumes the F41 Core metadata-search contract. It is
read-only: the public UI contains no clip URL, raw frame, provider credential,
mutation or sharing action. Search results are useful only while the exact
authenticated Core, home, account session, route and index revision remain
current.

The three software acceptance criteria are:

1. Strict response parsing accepts only the authorized Core/home evidence
   projection and rejects foreign scope, unexpected fields and secret-bearing
   results. The UI displays only summary, matched terms, authorized camera name
   and capture time; internal clip/event identifiers are not rendered.
2. Every search binds query, index revision, bounded 31-day window and at most
   16 selected camera identifiers to the authenticated Server session. A late
   response after route/session authority changes is discarded, and an index or
   camera mismatch fails closed without retaining earlier results.
3. The EN/TR tablet surface supports 600 and 1280 logical-pixel windows at 2x
   text scale, switches from one to two columns, provides a 48dp search action,
   and supports labelled TalkBack semantics and hardware-keyboard submission.

## RED

- `f45ab18e` introduced the scoped API, controller and responsive UI contracts
  before the Client implementation existed; the focused target could not
  compile on the missing camera-search modules.

## GREEN

Validation on 2026-09-21:

- Focused API/controller/tablet suite: 9 passed.
- EN/TR responsive matrix: 600 and 1280 logical pixels at 2x text scale passed.
- Hardware Enter submission and labelled TalkBack action passed.
- Focused Flutter analyze reports no issues.

## Remaining integration and physical acceptance

The F41 Core foundation does not yet register its authenticated HTTP route, so
the tested Client path remains a strict transport contract rather than an
end-to-end Core journey. App-shell route wiring, live camera inventory labels,
clip playback, correction feedback and dependency acceptance for F43/F08 remain
open. No physical camera, NVR, Huawei tablet or Samsung DeX result is claimed.
Queue and selected-feature progress therefore remain unchanged.
