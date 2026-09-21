# F57 room-presence tablet management acceptance

This package adds an Android tablet and DeX management surface over the F57
privacy-bounded Core foundation. Queue progress remains 20/125 and selected
feature progress remains 0/63. Provider adapters, encrypted durable storage,
real sensor calibration, and physical BLE/UWB/Home Assistant room acceptance
remain explicit delivery gates.

Exactly three user acceptance criteria are in scope:

1. The user sees configured room, provider reachability, consent, confidence,
   and advisory presence state as separate text-and-icon evidence. Public
   models cannot carry raw BLE/UWB identifiers or location history, and state
   explicitly remains advisory and unable to grant access.
2. Calibration first obtains an exact-revision Core preview and requires an
   explicit confirmation. Core, home, account, session-family, route, device,
   room, policy, consent, and calibration revisions must remain current; only
   an exact receipt followed by matching readback is successful. Lost, late,
   foreign, expired, or uncertain results fail closed without automatic replay.
3. English and Turkish layouts work at 600 and 1280 logical pixels with 200%
   text, 48 dp actions, keyboard Enter or Space, TalkBack state/button/header
   semantics, live announcements, and one- or two-column tablet adaptation.

## TDD evidence

The RED commit `a8de2579` failed because the F57 Client public models, Core API
boundary, controller, and tablet screen did not exist. The GREEN test matrix
contains one privacy/authority test, one calibration confirmation/readback
test, and one parameterized EN/TR accessibility test across both widths at
200% text.
