# F62 initial-frame wait diagnostics — 2026-10-01

## Observed boundary

The x86_64 lane of exact source
`70ab1058495957844edc79740abe46df4a50296a` in
[run 36814807367](https://github.com/ersingundem/larenor/actions/runs/36814807367)
reached the original packaged Android test and failed with **1 test, 1 failure,
0 errors and 0 skips**. Its source-bound frames identify the initial 1280×800
frame wait. They establish that the expected frame was not returned before the
existing 30-second deadline. They do not establish that no frame callback ran:
the original loop acknowledged intermediate frames of another size before
waiting again.

The original wait used one blocking poll for the whole remaining deadline. A
terminal session, zero callbacks, a stream of wrong-size frames and a stall
after an earlier callback therefore produced the same generic assertion. No
production or host change is justified by that evidence alone.

## Bounded diagnostic repair

The original test method, success assertions and absolute 30-second deadline
remain unchanged. The initial wait now checks the existing queue in bounded
250 ms slices and emits one of four fixed throwable classes:

- terminal session;
- no callback before the deadline;
- last observed callback carried a different bounded width and height; or
- callback activity was observed but no current frame remained available.

The XML throwable class is the primary diagnosis. Publication still requires
the exact original class and method, one failed test with no skips or errors,
and an owned `RdpPackagedHostAcceptanceTest.kt` frame. An arbitrary message or
unowned frame cannot select a diagnosis.

The app-private, nonce-bound lifecycle marker may additionally retain callback
count (capped at 4096), whether the cap was reached, the last dimensions (each
1–8192), and the exact session phase. Only `connectionFailed`,
`frameBackpressure`, `framebufferUnavailable` and `staleSession` are accepted
for a failed terminal session. `cancelled` has no failure code. The marker is
secondary: absence or malformed content is omitted, and it cannot replace the
canonical JUnit failure. Pixels, messages, host/provider identity, session IDs,
credentials and raw stack text are never published.

TLS 1.2/NLA/SPKI validation, rendered-pixel checks, exact frame ACKs, the real
key effect, client DISP resize, Unicode clipboard effect, disabled-channel
zero transfer, two authenticated lifetimes, clean close and credential wiping
remain required for a successful receipt.

## Local verification

- `PYTHONPATH=. python3 -m unittest tool.tests.f62_packaged_acceptance_test`:
  **43 passed**.
- `python3 -m py_compile tool/f62_packaged_acceptance.py
  tool/tests/f62_packaged_acceptance_test.py`: passed.
- `git diff --check --` on the scoped Android test, runner, parser tests and
  this document: passed.

The negative cases cover all four fixed throwable classes, exact source and
test binding, injected class text, observation bounds, phase/failure-code
pairing, marker injection, and omission when the marker does not match the XML
throwable. The required AndroidTest Kotlin compilation and a changed-source
hosted run remain pending. This slice improves failure attribution; it is not a
passing F62 runtime receipt and does not establish the cause of the 70ab run.

Root independently passed the 43 runner tests and the actual required-product `:app:compileDebugAndroidTestKotlin` compilation together with the frozen normal-Core player and reviewed F60 ACK fixture. The combined runner set passed 99 tests. This establishes compilation and parser gates, not a successful RDP runtime receipt.
