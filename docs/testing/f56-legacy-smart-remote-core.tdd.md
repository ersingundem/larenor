# F56 legacy smart-remote Core acceptance

This package establishes a fail-closed Core boundary that can reuse an existing
Home Assistant remote provider or an isolated bridge without copying either
provider's state owner. Queue progress remains at 20/125 and selected-feature
progress remains at 0/63. Durable command storage, authenticated HTTP and
Client wiring, provider adapters, learning administration, and physical IR/RF
hardware acceptance remain open gates.

Exactly three user acceptance criteria are in scope:

1. A command preview binds the exact Core, home, account, session family,
   device, bridge, provider, profile, code-set, and opaque binding revisions.
   Stored, reachable, and provider-verified states are separate, and any drift
   fails closed before a worker can run.
2. A command requires a short-lived preview and explicit confirmation. Exact
   delivery readback is idempotent; a missing or mismatched acknowledgement is
   uncertain and the same request is never replayed in-process. An emitted IR
   or RF receipt never claims that the appliance changed state.
3. Only profile-listed keys, repeat counts up to three, and hold durations up
   to two seconds can cross the worker boundary. Learning and raw IR/RF inputs
   are rejected, while provider signal bytes, credentials, and secrets are
   absent from every public profile, command, receipt, and result model.

## TDD evidence

The RED commit `e7d2af3a` failed collection because the
`larenor_server.legacy_remote` package did not exist. The GREEN matrix contains
exactly three focused tests covering nested revision drift, deadline and
delivery idempotency, lost acknowledgement without replay, permission and
command bounds, public-model field inspection, secret redaction, and HMAC audit
tamper rejection.
