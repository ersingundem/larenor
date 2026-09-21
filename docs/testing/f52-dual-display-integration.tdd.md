# F52 dual-display Android integration

This integration package starts the native Android bridge over the merged F52
Client authority contract. Queue and selected-feature counters remain inherited;
physical Samsung DeX, dock, touch, keyboard, protected media, and OEM display
behavior remain MANUAL gates.

Exactly three acceptance criteria are in scope:

1. Android returns one bounded, secret-free topology containing exactly one
   primary display and at most four external displays with exact topology and
   display generations.
2. A public allowlisted secondary route uses an exact session, topology,
   display-generation, present receipt, and explicit dismissal. Background,
   focus loss, detach, malformed, private, duplicate, or stale requests fail
   before the native host and never replay.
3. The Flutter platform port validates the closed native map before exposing a
   topology or receipt to `DualDisplayCoordinator`; unknown keys, private data,
   malformed values, and foreign callbacks fail closed.

The RED tests intentionally precede the Android bridge and Flutter platform
adapter. A later slice will connect the verified bridge to a route-owned tablet
management surface and isolated secondary Flutter renderer.
