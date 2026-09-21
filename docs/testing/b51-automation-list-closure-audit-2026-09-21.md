# B5.1 automation-list closure audit

The earlier integration inventory is superseded by the accepted B5.1 software
closure on main `ee25ae45`. Its uncovered automation-list route and the later
Core settings, Direct connection, Home Assistant/player, Today, media and
Keenetic tablet slices are now merged.

The final integration preview regenerated generated sources and passed
**240/240** focused Flutter tests. PR #259 exact source `0d43b7f8` passed API 35
emulator journeys, debug APK/native contracts, static analysis, Flutter and
Server shards, security and managed-stack checks. The durable evidence is in
[`docs/b51-shared-tablet-software-closure-2026-09-21.md`](../b51-shared-tablet-software-closure-2026-09-21.md).

Huawei MatePad, Samsung DeX, keyboard, TalkBack and live Home Assistant, media
receiver and Keenetic checks remain in the manual release matrix; this audit
does not claim those physical results.
