# F55 Zigbee/Thread tablet management acceptance

This package adds an Android tablet and DeX management surface over the F55
Core boundary. Queue progress remains 21/125 and selected-feature progress
remains 0/63. An authenticated HTTP adapter, durable command storage,
production coordinator workers, signed vendor catalogs, and physical Zigbee or
Thread device acceptance remain open delivery gates.

Exactly three user acceptance criteria are in scope:

1. The screen separates topology health, coordinator reachability, device
   reachability, and signed update metadata. Channel and interference guidance
   stays explicitly read-only; every trusted response is bound to the exact
   Core, home, account, session-family, route, topology, provider, coordinator,
   device, catalog, and interference revisions.
2. A supported Zigbee update obtains a bounded preview and requires explicit
   confirmation. Success appears only after exact receipt and authenticated
   readback of the device, provider, route, version, and digest; Thread OTA,
   stale revisions, unsafe power or route state, lost responses, and malformed
   readback fail closed without automatic replay.
3. English and Turkish layouts work at 600 and 1280 logical pixels with 200%
   text, 48 dp actions, one- and two-column tablet layouts, keyboard Enter or
   Space activation, TalkBack button/header/read-only semantics, and live status
   announcements. Background, route, account, or session changes retire late
   callbacks and clear trusted state.

## TDD evidence

The RED commit `825b1691` failed because the F55 Client models, API boundary,
controller, and management screen did not exist. The GREEN matrix contains one
authority/topology/stale-callback test, one preview-confirm-exact-readback test,
and one parameterized EN/TR tablet accessibility test across both target widths
at 200% text.
