# S08.8 scoped media recovery cache TDD evidence

23 September 2026. This slice keeps the unified media recovery readback useful
during a bounded transient Core outage without turning stored evidence into
live authority. It does not close `S08.8`: queue progress remains **26/125**
and selected-feature progress remains **0/63**.

## Three accepted behaviors

1. The recovery contract requires exact integer schema `2`; the persistent
   envelope requires exact integer schema `1` and a matching recovery contract
   version. Float spellings and malformed service revisions fail closed.
2. One 64 KiB, five-minute record is bound to the exact Core, home and account.
   Its ordered resource vector repeats each service identity, source kind,
   source identity and revision, and must match the decoded status. A corrupt,
   expired or oversized exact record is compare-and-cleared without deleting a
   replacement owner's value.
3. The controller reads and writes only while its account generation and route
   authority remain current. A stored status is exposed only after
   `connection_failed`, `timeout`, `server_error` or `rate_limited`; malformed
   responses and authorization failures never fall back to old evidence. A
   route retired during cache I/O sends no recovery request, and a write retired
   after persistence removes only its exact value.

No URL, header, access token, refresh token, password or provider credential is
serialized. The existing recovery screen already labels observations as
historical rather than live; this slice adds no direct Jellyfin or Music
Assistant connection path.

## RED and GREEN

Reachable RED commit `fe1040c9bdfc87d1bf20f33284b317da626dd0c4`
introduced the strict schema, scope/resource/TTL/quota, replacement-owner and
controller lifecycle tests before the cache implementation existed.

GREEN commit `e01601a370d8937d103c6cdc6268635a37456660`
added canonical recovery serialization, the compare-and-write cache backend,
and the transient-only controller fallback.

## Verification

The combined recovery, media preparation and inspection batch passed
**127/127** tests. It includes EN/TR recovery screens at 600 and 1200 logical
pixels with 2x text, keyboard and semantics coverage, route/background
retirement, strict response parsing, durable preparation history and inspection
authority regressions.

Focused `flutter analyze` passed with no findings for the five changed Dart
files. `tool/check_security_policy.py` passed. The execution queue validates at
125 jobs and 63 selected features; its status remains **26/125** and **0/63**.
`git diff --check origin/main...HEAD` passed.

`S08.8` still needs the remaining catalog/search/player/queue migration,
approved legacy mapping, authorization-loss E2E, independent review and
current-head CI before its acceptance evidence or counters can change.
