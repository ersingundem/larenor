# F56 legacy smart-remote tablet acceptance

This package adds an Android tablet and DeX management surface over the merged
F56 Core boundary. Queue progress remains inherited from current main and
selected-feature progress remains 0/63. Authenticated HTTP wiring, durable
command history, provider adapters, learning administration, and physical
IR/RF hardware acceptance remain explicit delivery gates.

Exactly three user acceptance criteria are in scope:

1. The user sees stored registration, current reachability, and provider
   verification as separate text-and-icon evidence. Only profile-allowlisted,
   bounded commands appear; raw IR/RF signals, learning payloads, credentials,
   and provider secrets cannot enter the Client device/profile model.
2. A command first obtains an exact Core preview and requires explicit user
   confirmation. Core, home, account, membership, session-family, route,
   device, bridge, provider, profile, code-set, binding, command, repeat, and
   hold values stay bound. Success requires an exact receipt and authenticated
   readback; lost, late, expired, foreign, or uncertain results fail closed
   without replay. Verified delivery never claims verified appliance state.
3. English and Turkish layouts work at 600 and 1280 logical pixels with 200%
   text, 48 dp actions, keyboard Enter or Space, TalkBack state/button/header
   semantics, live announcements, and one- or two-column tablet adaptation.

## TDD evidence

The RED commit `90f138c4` failed because the F56 Client public models, Core API
boundary, controller, and tablet screen did not exist. The GREEN matrix contains
one safe-profile/authority test, one preview-confirm-readback test, and one
parameterized EN/TR accessibility test across both widths at 200% text.
