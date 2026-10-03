# F60 — ordered XI2 observer handoff, 3 October 2026

[Strict run37134249192](https://github.com/ersingundem/larenor/actions/runs/37134249192)
failed on exact `847b1f576ebab39ab92c9cd008c036a817672188`. Root verified the
actual stream job111235402782 and original named **1 test / 1 failure /
0 errors / 0 skips**. Failure remained `ownedInputEffects`; the closed phase
was `touchListener/failed/xi2ChildExit`, with `pairedClientObserved` already
recorded. This supersedes the prior in-progress label, not the earlier failures.

The exact source/named/classes/package-source canonical failure receipt is
1154 bytes; SHA-256 `33acd7b895c22d5bd9b2a6ebc3fda29cf6053b51271e362188ea6077cd947044`.
Its strict validator and byte identity were checked before recording this result.
No credentials, endpoint, raw log or provider identity is published.

The production harness had kept its key `xinput test-xi2 --root` process alive
while creating another identical pointer observer. Upstream [xinput source](https://github.com/openbsd/xenocara/blob/master/app/xinput/src/test_xi2.c)
selects key, pointer and touch events on the root window. The [X server selection implementation](https://github.com/mirror/xserver/blob/master/Xi/xiselectev.c)
rejects another client's overlapping touch selection with `BadAccess`. This is
source-backed evidence for a conflicting harness topology; the exact Linux
reproduction and changed-source Android stream remain required.

The harness now waits for the real press/release proof, synchronously reaps that
owned key observer, then constructs the pointer observer. A failed/missing key
proof or failed reap cannot start the successor. The real Android key, pointer,
button, two-lifetime stream, audio and disconnect gates are unchanged.

The short disposable Linux probe now measures the old overlapping topology and
the ordered handoff using real XTest key, pointer and button events. Its closed
receipt includes key observation, process reaping and the finite overlap error;
it always declares `featureAccepted=false`. It is a diagnostic observer probe,
not Sunshine or Android product acceptance. Existing displays are refused and
owned processes are cleaned up.

Root local regression: **82 tests passed**, scoped Ruff passed. Green log
SHA-256 `d9d531f179646945d72b0e94543deceda58e1bab8c5f0c86b08518812439c7a9`.
Linux probe and changed-source full stream are still pending. F60 remains
`reworking`; accepted counters, FINAL.FUNCTION and merge remain unchanged.


The short [run37135929910](https://github.com/ersingundem/larenor/actions/runs/37135929910)
on exact `5a71559a14d7e3d9e4fbb65e50fe86edcc36698c` failed at `keyListener`
before any key/pointer acceptance. The closed receipt did not distinguish a
missing executable from an invalid keymap; no narrower cause is claimed. Its
private log SHA-256 is `5b406c95254eee267dff53e9b209b2c41b5799586bd3e52a999755553f8153e4`.
The new probe requires xmodmap while its original dependency list installed only
pointer utilities. The changed workflow now installs exact-resolved
`x11-xserver-utils`, the [Ubuntu xmodmap package](https://packages.ubuntu.com/noble/riscv64/x11-xserver-utils/filelist),
and the probe exports a finite keymap/spawn/effect failure code. Root **83 tests**
and Ruff passed; green log SHA-256 `fbcde7af4aeec83aea8782963f32fb3ae2c5f0cc7694e63a7b1731e7163e8a11`.
A changed-source probe, not a same-SHA retry, is required. Full Android stream
acceptance remains open.
