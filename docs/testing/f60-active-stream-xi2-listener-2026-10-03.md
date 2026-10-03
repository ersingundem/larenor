# F60 active-stream XI2 listener repair — 2026-10-03

## Observed boundary

Exact source `54954a768a5c97e7844e94bdeb46c445f54958c0`, run
`37131893719`, retained the canonical original named-test result
`1 test / 1 failure / 0 errors / 0 skipped`. The source-bound phase receipt is
`touchListener / failed / contract`. It proves that the host failed while
starting its pointer listener before `touch_armed`; it does not prove which
listener branch failed and does not prove an Android input-ordering defect.
The earlier clean-Xvfb XI2 probe used a different, inactive-host condition.

## Source defect and bounded repair

Pinned xinput 1.6.4 calls `list()` before it calls `XISelectEvents()` and
`XSync()`. Consequently, `xinput test-xi2 --root` first emits the complete
current input-device inventory. An active Sunshine stream can add virtual input
devices, so this startup prefix is not bounded by the clean-Xvfb probe's output
size. The old pointer reader applied the generic 64 KiB command-output cap to
the entire long-lived event stream, including this pre-subscription listing.
It could therefore fail before its owned readiness warp reached the reader.
This is a source-proven active-stream defect and is consistent with the retained
boundary, but the old public receipt is too coarse to establish it as the
exclusive historical cause.

The integrated repair:

- removes only the cumulative byte cap from the long-lived pointer stream;
- retains the 4 KiB per-line bound, strict event grammar, exact owned readiness
  warp, two distinct positions, and primary-button press/release requirements;
- retains at most two positions, so the live stream cannot grow a coordinate
  trace in memory;
- publishes only closed XI2 failure enums for start, readiness timeout, probe,
  line format, line size, child exit, read I/O, and effect timeout. It never
  publishes a device name, coordinate, provider output, process identity, or
  exception message.

Primary pinned sources:

- xinput 1.6.4 `test_xi2.c`:
  <https://gitlab.freedesktop.org/xorg/app/xinput/-/blob/xinput-1.6.4/src/test_xi2.c>
- Sunshine `v2026.914.233613` input allocation and mouse forwarding:
  <https://github.com/LizardByte/Sunshine/blob/v2026.914.233613/src/input.cpp>

## Focused evidence

The new active-stream-prefix regression feeds more than 64 KiB of valid,
irrelevant startup lines followed by the unchanged required motion/button
sequence. It fails against the exact original reader and passes against the
candidate. Eight focused XI2/receipt tests pass. The complete exact-source
runner suite passes 67 tests when evaluated with the exact Android test source
from `54954a768a5c97e7844e94bdeb46c445f54958c0`; no hosted provider or Android
effect is claimed.

Root independently verified the frozen three-file candidate against the
unchanged source on completion-branch base
`7736683371a6b955a0d4f04a0ba4f9460a9246f0`, then ran the integrated source:
**80 tests / 72 subtests passed**, with zero failures, errors, or skips. This
includes all 67 runner tests, 10 workflow tests, and three pointer-probe ownership
tests. Scoped Ruff 0.14.1 is clean. The old long-prefix reader fails the new
regression; the strict Android motion/button acceptance was not weakened.
This local result does not establish the old run's exclusive cause or a
successful Android stream. F60 remains `reworking` until the changed source
passes its actual two-session stream and input acceptance.

A cheap changed-source Linux probe should run inside the existing owned-host
job after Sunshine has created the active stream input devices. It should start
the real pinned `xinput test-xi2 --root`, require the same exact warp-readiness
handshake, deliberately generate more than 64 KiB of valid owned XI2 traffic,
and then require the unchanged owned XTest movement plus primary-button effect.
It must remain source/nonce/session bound and report only the closed failure
enum. Passing that probe establishes listener behavior under the real active
host condition; only the existing named Android test can establish the remote
touch effect.

Integrated root local gate log SHA-256: `d9cc904ede73945f4fb80ace3686a5bab9755b25f1315303b543df51c9b03eee`.
