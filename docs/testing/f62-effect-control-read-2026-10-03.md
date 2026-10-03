# F62 — bounded effect-control reader repair, 3 October 2026

This slice is frozen on base `a3f01b5fa888e4ef665cbfe842ae8a79a65e1696`.
It repairs the host observer without claiming RDP audio, microphone, SAF or
Gateway acceptance.

The previous [exact f201 run](https://github.com/ersingundem/larenor/actions/runs/37128695877)
failed with the static reason `owned effect control order was invalid`. The
canonical failure receipt establishes an invalid observation before audio was
accepted. It does not establish that Android wrote microphone before audio.
There are no original named test counts in that receipt.

The old reader interpreted an unavailable ADB/run-as observation as an absent
control, and used separate existence/read commands. Each phase now has one
bounded device-side read. Only exit 44 with empty stdout means absent; ADB,
run-as and deadline failures mean unavailable and fail the fixture gate. The
read remains capped at 209 bytes for the exact 208-byte source/test/nonce-bound
record. Invalid, early, replayed or simultaneous records never arm effects.
The phase advances only after successful consumption of the exact record.

Root reran 73 packaged-acceptance and 11 workflow tests: **84/84 passed**.
Scoped Ruff 0.14.1 passed. Regression coverage includes executing the actual
POSIX shell body against temporary files, exit-1 versus exit-44 classification,
unavailable audio versus early microphone, invalid order without mutation and
failed removal without phase advancement. The local shell regression is not
Android execution or a provider effect test.

The strict hosted effect gate remains open. No unchanged-SHA rerun was made;
the next hosted run must use the composed, verified native package and changed
consumer sources. F62 remains `reworking` and accepted counters do not change.
