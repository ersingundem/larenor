# F55 Zigbee/Thread network and update Core acceptance

This package establishes a fail-closed Core foundation for read-only Zigbee
and Thread diagnostics plus explicitly supported Zigbee OTA. Queue progress
remains at 21/125 and selected-feature progress remains at 0/63. Durable command
storage, authenticated HTTP APIs, coordinator backup/restore, production radio
workers, Android tablet UI, and physical device validation remain open delivery
gates; Thread health does not claim Matter ownership or universal Thread OTA.

Exactly three user acceptance criteria are in scope:

1. A user can inspect coordinator, border-router, device, and interference
   health only when the exact Core, home, account, session, topology, provider,
   node, device, route, and interference revisions still match. Channel advice
   is read-only and never applies a radio change.
2. A supported Zigbee firmware preview requires an unexpired Ed25519-signed
   catalog, exact catalog and provider revisions, SHA-256 digest, newer semantic
   version, matching manufacturer/model/hardware/source version, a safe route,
   and sufficient mains or battery power. Thread OTA and incompatible targets
   fail closed.
3. An administrator must preview and explicitly confirm an OTA command. Success
   requires exact device, provider, route, version, and digest readback; a lost
   acknowledgement becomes uncertain and is never replayed in-process, while a
   broken HMAC audit chain blocks every later effect.

## TDD evidence

The RED commit `e5f52322` failed collection because the
`larenor_server.mesh_center` package did not exist. The GREEN matrix contains
exactly three focused tests covering nested topology drift and channel advice,
signed catalog/compatibility/power/route boundaries, and confirmed or uncertain
OTA outcomes with idempotency, exception redaction, and audit tamper rejection.
