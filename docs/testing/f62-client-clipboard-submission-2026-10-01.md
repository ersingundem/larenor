# F62 explicit clipboard submission — 2026-10-01

The selected `clientToRemote` mode now has a complete Client submission path:
the foreground user taps **Send clipboard text**, Flutter reads plain text once,
and the current RDP channel sends typed UTF-8 bytes through the strict native
clipboard handler to the packaged FreeRDP API. No clipboard subscription,
automatic read, persistence, logging, retry or remote-to-client mode is added.

The admission bound is 65,536 UTF-8 bytes, non-empty, without NUL or unpaired
surrogates. Clipboard input shares pointer/key sequence ordering. The original
Dart payload and native byte arrays are wiped after success or rejection.
Generation, exact channel and foreground authority are checked before reading,
after reading and after submission. A delayed read cannot enter a successor
connection. Reads and submissions have five-second deadlines; an unconfirmed
submission closes the captured channel, never a successor, and requires an
explicit reconnect. The UI describes accepted submission, never remote
clipboard readback or application paste success.

Root validation:

- 45 Flutter model, method-channel, controller and panel tests passed.
- New cases cover byte limits, Unicode/NUL/surrogates, mode opt-out, typed wire
  shape, shared sequence, original buffer erasure, retired authority, successor
  connection, missing native reply, timeout recovery, no replay and native
  refusal. English/light and Turkish/dark panels passed at 2x text scale with
  an accessible action target and status region.
- `flutter analyze --no-pub`: no issues found.
- Root verified native XML totals: bridge 3 plus engine 12, zero failures,
  errors or skips; the agent verified receipted packaged production compilation.

The [native bridge proof](f62-native-clipboard-bridge-2026-10-01.md) records the
actual FreeRDP API boundary and upstream references. The existing owned shadow
fixture has no `cliprdr` implementation. An NLA-capable owned host with actual
remote clipboard effect remains necessary before full F62 acceptance. The
failed baseline run at exact `7fccce520ff8e1abcf45a16d6ffb4d16c8a72bb2`
[36797967344](https://github.com/ersingundem/larenor/actions/runs/36797967344)
ran the original one test with one failure and zero errors/skips. The actual
keyboard witness proves initial frame/ACK and input reached the owned host;
the runner also completed its host-side resolution change. Failure is bounded
to the post-resize frame/ACK/close/credential assertions. Current sanitized
evidence cannot select the exact failing assertion, so changed-source fixed
stage diagnostics are being prepared. No same-SHA rerun or feature acceptance
is inferred.

This slice completes the Client/native software connection and focused checks.
F62 stays **reworking**, and accepted counters remain **37/127** and **3/63**.
