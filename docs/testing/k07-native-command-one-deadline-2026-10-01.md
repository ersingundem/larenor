# K07 native command deadline — 1 October 2026

Flutter shard 0 of exact
`5325c083970096fc84da2daa63b6b2a2f208aed2`,
[run 36816909489](https://github.com/ersingundem/larenor/actions/runs/36816909489),
failed `native command timeout retires its platform session`: expected
`failed`, actual `denied`, at the deadline test's line 172.

The native command and its executor each started the same timeout. When the
inner timer won, it retired the lease, completed its cleanup and returned
`failed`; the outer executor then saw an already retired lease and rewrote the
result to `denied`. When the outer timer won, it returned the expected failure.
The test now advances Flutter's controlled clock to reproduce the inner-first
order deterministically. Root observed the same expected/actual failure before
the production change.

The command executor now owns its one total deadline and timeout retirement.
The native operation still races its exact lease's external retirement, which
unblocks it immediately and denies stale results. Bind and telemetry deadlines,
late-action guards and successor ownership remain in place.

Root passed all 17 native-source/deadline tests and static analysis of the
changed source and regression. The deterministic regression is green after
the fix. This is local software evidence; the changed-source Flutter CI gate
still needs to pass. K07 returns to `awaiting_ci`; its dependent K08 also awaits the renewed
K07 acceptance. Their previous exact proofs remain historical.
