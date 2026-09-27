# F52 dual-display Android integration

This integration package starts the native Android bridge over the merged F52
Client authority contract. Queue and selected-feature counters remain inherited;
physical Samsung DeX, dock, touch, keyboard, protected media, and OEM display
behavior remain MANUAL gates.

Exactly three acceptance criteria are in scope:

1. Android returns one bounded, secret-free topology containing exactly one
   primary display and at most four external displays. Hotplug, reconnect,
   focus, configuration and lifecycle changes advance exact topology/display
   generations and retire the previous presentation.
2. Settings exposes a route-owned tablet task manager that separates the
   primary and external screens, selects Dashboard or Now Playing, refreshes
   topology and explicitly disconnects. Its EN/TR controls stay at least 48dp,
   keyboard/TalkBack operable, and usable at 600/1280 logical pixels with 2x
   text.
3. The Flutter port and coordinator bind every operation to the exact account,
   home, session, lifecycle, route, topology and display generation. Unknown
   routes, wrong/reconnected displays, malformed receipts, late hidden-route
   callbacks fail closed; duplicate native intents remain idempotent.
4. The Android presentation now owns a separate, plugin-free Flutter engine.
   That engine exposes only the allow-listed public Dashboard or Now Playing
   role and never constructs the primary ConfigurationScope/HomeSessionScope.
   Account, home, URL, token, credential and media metadata therefore cannot be
   inherited by the external renderer. Native topology events automatically
   retire or refresh the Dart lease across hot-plug, rotation and resize.

RED commits `e550cf05` and `c897927e` preceded the Android bridge and tablet
manager. The earlier package recorded twenty-three focused Flutter
contract/widget tests and three Android unit tests. The isolated secondary
renderer, event-driven topology refresh and ownership corrections were added on
the project completion branch; their final tests, independent review and exact
CI are intentionally deferred to the shared verification phase. Physical
Samsung DeX, dock, touch, keyboard and protected-media verification remain
MANUAL gates.
