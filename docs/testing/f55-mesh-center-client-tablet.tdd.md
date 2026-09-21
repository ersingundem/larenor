# F55 Zigbee/Thread tablet management acceptance

This package connects the Android tablet management surface to the F55 Core
boundary. Queue progress remains 22/125 and selected-feature progress remains
0/63. Durable command storage, production coordinator workers, provider
discovery and physical Zigbee or Thread device acceptance remain open delivery
gates; this package therefore does not mark F55 complete.

Exactly three user acceptance criteria are in scope:

1. Admin-authenticated Core HTTP returns topology, interference, signed catalog
   and health only for the exact Core, home, account and session family. The
   server verifies the current vendor catalog signature before display; stale,
   foreign, duplicate-auth and query-bearing requests fail closed.
2. A route-owned Client session obtains one bounded Zigbee preview and requires
   explicit confirmation. Success appears only after the exact authenticated
   readback of device, provider, route, version and digest. Thread OTA, unsafe
   power/route state, account replacement, logout, lost responses and malformed
   readback do not dispatch or replay a command.
3. The shared Settings shell exposes the mesh center in English and Turkish.
   The existing 600/1280 logical pixel, 200% text matrix verifies 48 dp actions,
   keyboard use, TalkBack semantics and read-only channel guidance. Background,
   route, PIN, account or session changes retire late callbacks and clear trusted
   state.

## TDD evidence

The RED commit `825b1691` failed because the F55 Client models, API boundary,
controller and management screen did not exist. The GREEN matrix now contains
six Core service/API tests, two authenticated HTTP Client tests, two controller
tests and four parameterized EN/TR tablet accessibility tests. The broader
Settings matrix adds ten PIN, keyboard and 600/1200 @2x checks. Targeted Flutter
analysis is clean; the exact source also passes queue, security, progress and
secret policy checks.
