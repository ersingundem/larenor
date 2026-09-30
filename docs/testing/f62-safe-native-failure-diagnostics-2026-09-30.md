# F62 safe native failure diagnostics — 30 September 2026

[Workflow run 36772277001](https://github.com/ersingundem/larenor/actions/runs/36772277001)
at exact revision `f5b382cec7e3d4ced65535e8e538e696fbb3fec6` passed the
arm64 package/APK lane. Its x86_64 lane passed the immutable source, native
package, APK, KVM, emulator and owned NLA shadow-host steps. Android reported
that it was running tests on the API 35 emulator, then
`:app:connectedDebugAndroidTest` failed about six seconds later.

The retained public log contains only Gradle's generic “failing tests” result.
The raw JUnit and HTML reports were left inside the disposable runner and were
not artifacts, so the failed assertion cannot be inferred from this run. The
production source has several deliberate assertions covering package identity,
capabilities, TLS/NLA inspection, the security callback, first rendered frame,
input, clipboard zeroization, resize and clean close. Picking one without the
JUnit frame would be speculation; no runtime or security assertion is relaxed.

The owned runner now keeps Gradle output private and turns one bounded raw
JUnit report into a canonical `failure.json`. That public document contains
only:

- exact Git source revision and packaged FreeRDP receipt SHA-256;
- the already-public owned fixture package versions and exact test identity;
- one static failure code;
- an allowlisted exception type, or `unclassified`;
- at most eight frames represented only by an existing owned RDP Kotlin/Java
  filename and a bounded positive line number; and
- exact one-test skip/failure/error counts when the report is structurally
  consistent.

Messages, raw stack text, absolute paths, credentials, Gradle output, JUnit XML
and HTML are never copied into the artifact. Unknown exception classes,
unowned frames and message text are discarded. Missing, ambiguous, malformed,
wrong-test, launch and timeout outcomes use static codes. The runner removes
the raw `TEST-*.xml` files after creating the diagnostic and exits nonzero with
one static line rather than a Python traceback. Success still requires exactly
the existing class and method, one test, zero skips/failures/errors, the exact
source revision and the immutable package receipt.

The workflow has a separate `failure()` artifact step that uploads only
`${{ runner.temp }}/freerdp-public-acceptance/failure.json`. The existing
success receipt step and all native acceptance assertions are unchanged. A new
exact hosted run is required to identify the owned source frame and then repair
the actual native failure; this diagnostics slice is not a passing F62 receipt.

## Local evidence

`python3 -m unittest -v tool.tests.f62_packaged_acceptance_test tool.tests.freerdp_android_workflow_test`
passed 20 tests. The negative cases cover secret-bearing messages, absolute and
unowned frames, unknown exception types, missing/malformed/ambiguous reports,
extra public fields, the eight-frame bound, duplicate frames, symlinked and
oversized reports, XML entity declarations, canonical private output,
raw-report removal, suppressed
Gradle output, failed-process publication and the failure-only workflow upload.
`python3 -m py_compile tool/f62_packaged_acceptance.py tool/tests/f62_packaged_acceptance_test.py`
also passed. Adding the unchanged F62 Android dependency and immutable package
policy suites produced 27/27 passing focused tests.

Root independent verification: 28 focused runner/workflow/package/dependency tests passed after adding the packaged production runtime source directory to the public frame allowlist. A packaged runtime frame is retained while its private exception message is discarded. This diagnostic change does not establish successful native acceptance.
