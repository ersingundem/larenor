# F60 owned stream failure diagnostics — 1 October 2026

[Run 36804692946](https://github.com/ersingundem/larenor/actions/runs/36804692946)
at exact revision `a703289d617380c768f5b50761609c0b2913ce24` completed the
owned-host preflight, receipted Moonlight engine build, emulator installation
and entered `connectedDebugAndroidTest`. The retained public output proves only
the fixed outer failure `owned Sunshine Android stream failed`. It contains no
owned JUnit frame or count, so it does not identify the failing assertion and
does not establish stream acceptance. Re-running that unchanged revision would
not add evidence.

The runner now reads the disposable connected-test JUnit before cleanup and may
write one source- and Moonlight-package-bound failure JSON. The public document
contains only a fixed failure code, exact bounded counts, the expected class and
method only when the report actually contains that identity, one of five
allowlisted exception types (or `unclassified`), at most eight allowlisted
Larenor Moonlight source filenames with positive line numbers, and a fixed
stage derived from the exact named test's owned source frame only when the
checked-in test source SHA-256 matches the reviewed line map. Source drift
leaves the stage unknown. It never copies
exception messages, raw stack text, XML, provider output, addresses, PINs,
credentials, certificates, paths, pixels, native identifiers or environment
values. Missing, ambiguous, malformed and pre-method/synthetic reports cannot
claim that the named test ran and cannot publish an acceptance stage.

The raw XML is opened with `O_NOFOLLOW` and read from that descriptor only.
Before and after the read, the runner requires the same current-user regular
inode with one link, and it rejects an empty file, a file larger than 1 MiB, or
a file that grows, shrinks, is replaced or is unlinked during the bounded read.
The private JSON writer handles short writes and removes an incomplete output
only when the destination still names the exact mode-0600 inode it created; a
replacement path is never deleted. Focused regressions exercise an actual path
swap, a symlink target, growth during the descriptor read, short writes, write
failure cleanup and replacement-inode preservation.

Diagnostic generation is secondary to the real gate. A parse, provenance,
write or cleanup failure cannot replace the original nonzero connected-test
result. Raw `TEST-*.xml` files are deleted after the bounded parse attempt. The
workflow uploads the JSON only when the exact stream step failed and an actual
non-symlink mode-0600 file exists; preboot and pre-instrumentation failures do
not create a phantom artifact. The existing success path still requires the
single exact test, zero skips/failures/errors, two stream lifetimes, output and
input witnesses, disconnect, no replay and local retirement.

This change is diagnostic only. It does not identify or fix the failure in run
36804692946 and does not make F60 accepted. A changed-source hosted run is
required to obtain a bounded source frame and then repair the actual defect.

Root independently passed **42/42** focused runner/workflow tests and
`actionlint` for the changed workflow. These are diagnostic contract checks,
not a successful hosted stream result.
