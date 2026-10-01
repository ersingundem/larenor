# F21/F24 Core player session controls — 2026-10-01

## Scope

The normal verified-Core catalog player now exposes the audio and subtitle
tracks emitted by its actual `media_kit` player. A selection is serialized with
the existing play, pause, seek, skip, and watch-party directive mutations and
is bound to the exact player generation and playback lease.

Language persistence occurs only after the native track mutation succeeds and
the same lease, account, session family, and emitted track snapshot remain
current. A language-tagged audio or subtitle track saves through the existing
Core-owned preference store. Subtitle off saves `off`. Automatic or unlabeled
tracks remain honest per-video choices and do not create a durable language
claim. A failed preference write leaves the actual per-video selection in
place and reports that only persistence failed.

The same route now exposes explicit watch-party actions for copying the current
invitation, transferring leadership to a connected participant, and leaving
the room. Clipboard access occurs only from the copy button. Every server
mutation captures the exact room snapshot, playback lease, route generation,
account, and session family; late or retired operations cannot update the
successor player.

Native source opening also uses the same serialized mutation queue and a
five-second bound. A hung or throwing open retires the exact source and player
instead of leaving an indefinite spinner. The current player's error stream is
subscribed per lease; its raw payload is discarded, the route shows only the
generic localized media failure, and an event queued by a replaced source
cannot retire its successor. A native effect that completes after timeout or
route retirement receives a final bounded stop after that late completion;
route disposal drains the bounded mutation queue before its final stop and
player disposal.

## Evidence

- `dart analyze` on the production screen and focused route test: no issues.
- `flutter test --no-pub test/features/server/server_core_catalog_player_test.dart`:
  13 tests passed, 0 failed, 0 skipped.

The test uses an owned `PlatformPlayer` implementation and the real production
screen/controller/API parsing path. It proves actual emitted-track selection,
successful language persistence, automatic/off behavior, native failure and
logout fences, explicit-only clipboard use, transfer/leave routing, and the
existing follower no-echo behavior. It also distinguishes bounded open failure,
current player error, and a stale queued error without publishing native error
payloads. It is not physical decoder, subtitle renderer, speaker, or
multi-device provider evidence.
