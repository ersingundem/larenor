# F60 normal Start launch-to-stream evidence (2026-10-01)

## Behavior under test

The production Flutter `Start` action now opens and binds one Core session,
captures one exact client authority and generation, and keeps the controller in
the busy `dispatching` phase while it performs two distinct one-use commands:

1. `launch`, accepted only with `native_observed`, `appRunning`, and
   `currentGameMatched`;
2. `stream`, authorized only after the exact launch observation, accepted only
   with `native_observed`, `streaming`, and `connectionStarted`.

The launch command's consumed grant is replaced by the existing exact-session
cleanup record before stream authorization. A process/controller restart,
logout, authority drift, invalid receipt, or lost acknowledgement between the
two commands therefore permits local session retirement but never dispatches a
stream command or replays the launch command. A fresh Start cannot enter while
the two-stage operation is busy.

## Named verification

- `flutter test --no-pub test/features/game_streaming/game_stream_client_controller_test.dart`
  passed 11 tests. The session lifecycle test covers one-session ordered
  launch/stream dispatch, a second Start rejected while launch is pending,
  invalid and lost-callback launch receipts with zero stream dispatch,
  authority drift after an observed launch with zero stream dispatch, and
  restart between launch and stream authorization with cleanup-only recovery.
- `server/.venv/bin/python server/tests/support/f60_flutter_acceptance.py`
  passed its one named Flutter test through an owned normal Core TCP process.
  The test observes the exact native command order `launch`, `stream`, `stop`
  and a strictly increasing revocation readback in the same client lifecycle.

Private command output is retained under
`/private/tmp/larenor-f60-normal-start-20261001` with directory mode `0700` and
log mode `0600`.

## Independent root verification

The root reran the 11 controller tests and the one owned normal-Core TCP test
after restoring the remote Stop guard for `outcomeUnknown`. The invalid-launch
receipt regression now also proves that remote Stop is rejected with
`outcome_unknown_requires_reentry`; exact local cleanup remains the recovery
path. Scoped analysis of the three edited Dart files reported no issues.
Private root output is in `/private/tmp/larenor-root-verify-20261001`
(`f60-controller.log`, `f60-core.log`, `f60-analyze.log`).

## Limits

The normal Core TCP gate uses a strict MethodChannel fixture for native command
receipts. It proves production Flutter/Core routing, one-use grant ordering,
durable recovery, and command fencing; it does not replace the separate owned
Sunshine/packaged Android frame, audio, input, and disconnect acceptance gate.
No provider address, PIN, credential, certificate, dispatch grant, or raw
native payload is written to this evidence document.
